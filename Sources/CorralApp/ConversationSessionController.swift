import AppKit
import CorralContracts
import CorralServices
import CorralUI
import Foundation

/// One windowed conversation view for one pane on one authenticated connection (Core contract 11).
/// Ready → initial HTTP page at H → buffered then contiguous live commits, each acknowledged only after adoption.
/// HTTP failures stay local to this pane; they never touch the terminal link, other panes or native state.
@MainActor
final class ConversationSessionController {
    enum Phase: Equatable {
        case subscribing
        case loadingHistory
        case ready
        case historyFailed(String)
        case recovering(String)
        /// Core refused or ended the stream; `lost` recovers automatically, the rest fall back to the terminal.
        case closed(ConversationClosedReason)
    }

    struct NativeState: Equatable {
        var sessionName: String?
        var model: String?
        var thinkingLevel: String?
    }

    let key: SessionKey
    private(set) var connectionEpoch: ConnectionEpoch
    let pane = CorralConversationPaneView()
    private(set) var phase: Phase = .subscribing
    private(set) var ready: ConversationReady?
    private(set) var transcript: ConversationTranscript?
    private(set) var liveState: ConversationLiveState?
    private(set) var nativeState = NativeState()
    var title = ""
    var provider: String?

    /// Wire and HTTP are injected; the controller owns ordering and ownership checks only.
    var send: (ClientCommand) async throws -> Void = { _ in }
    var fetch: (ConversationHistoryRequest) async throws -> ConversationHistoryPage = { _ in throw ConversationHistoryFailure("network") }
    var onPresentationChange: () -> Void = {}

    private var buffered: [ConversationUpdate] = []
    private var olderState: CorralConversationPaneState.Older = .complete
    private var olderInFlight = false
    private var bodyQueue: [String] = []
    private var bodyInFlight: String?
    private var bodyFailures: [String: (revision: UInt64, code: String)] = [:]
    private var requestSerial = 0
    private var stateCommandID: String?
    private var recoveries: [Date] = []
    private var publishScheduled = false
    private var pendingApplied: (viewID: String, sourceEpoch: String, commitSeq: UInt64)?
    /// Rows of a retired view stay visible while its replacement loads, so recovery never blanks the reader.
    private var staleRows: [CorralConversationRow] = []
    private static let bufferedLimit = 128
    private static let maximumBodyChunks = 256

    init(key: SessionKey, connectionEpoch: ConnectionEpoch) {
        self.key = key
        self.connectionEpoch = connectionEpoch
        pane.onLoadOlder = { [weak self] in self?.loadOlder() }
        pane.onNeedBodies = { [weak self] ids in self?.requestBodies(ids) }
        pane.onRetry = { [weak self] in self?.retry() }
    }

    /// Whether this pane should currently show the structured view instead of the terminal.
    var presentsConversation: Bool {
        switch phase {
        case .closed(.unavailable), .closed(.exited): false
        default: (ready?.mode ?? "rpc") == "rpc"
        }
    }

    func start() {
        phase = .subscribing
        publish()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.send(.conversationSubscribe(reference: self.key.reference)) }
            catch { self.phase = .recovering("network"); self.publish() }
        }
    }

    /// A reconnect invalidates every view; the pane keeps its rows while the new view's history loads.
    func rebind(to epoch: ConnectionEpoch) {
        guard epoch != connectionEpoch else { return }
        connectionEpoch = epoch
        if transcript?.initialAdopted == true { staleRows = rows() }
        transcript = nil
        ready = nil
        buffered.removeAll()
        pendingApplied = nil
        bodyInFlight = nil
        olderInFlight = false
        stateCommandID = nil
        recoveries.removeAll()
        start()
    }

    func stop() {
        let reference = key.reference
        let send = self.send
        Task { @MainActor in try? await send(.conversationUnsubscribe(reference: reference)) }
    }

    // MARK: Wire events

    func handleReady(_ value: ConversationReady) {
        if let current = transcript, current.viewID == value.viewID { return }
        if transcript?.initialAdopted == true { staleRows = rows() }
        ready = value
        transcript = ConversationTranscript(ready: value)
        buffered.removeAll()
        liveState = ConversationLiveState(running: value.running, queued: 0, mode: value.mode)
        olderState = .complete
        olderInFlight = false
        bodyQueue.removeAll()
        bodyInFlight = nil
        bodyFailures.removeAll()
        phase = .loadingHistory
        publish()
        onPresentationChange()
        loadInitial()
        requestNativeState()
    }

    func handleUpdate(_ update: ConversationUpdate) {
        guard var transcript, update.viewID == transcript.viewID, update.sourceEpoch == transcript.sourceEpoch else { return }
        guard transcript.initialAdopted else {
            buffered.append(update)
            if buffered.count > Self.bufferedLimit { recover("credit_exhausted") }
            return
        }
        switch transcript.apply(update) {
        case .applied:
            self.transcript = transcript
            if let state = update.state { adoptLiveState(state) }
            acknowledge(update)
            refreshStreamingBodies(update.upserts)
            publish()
        case .gap: recover("gap")
        case .notReady, .foreign: break
        }
    }

    func handleEvent(_ event: ConversationEvent) {
        guard event.viewID == nil || event.viewID == transcript?.viewID,
              let object = try? JSONSerialization.jsonObject(with: event.event) as? [String: Any],
              object["type"] as? String == "response", let id = object["id"] as? String, id == stateCommandID else { return }
        stateCommandID = nil
        guard object["success"] as? Bool == true, let data = object["data"] as? [String: Any] else { return }
        var state = NativeState()
        state.sessionName = (data["sessionName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let model = data["model"] as? [String: Any] {
            state.model = (model["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? model["id"] as? String
        }
        state.thinkingLevel = (data["thinkingLevel"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        nativeState = state
        publish()
    }

    func handleResync(viewID: String, reason: String) {
        guard viewID == transcript?.viewID else { return }
        recover(reason)
    }

    func handleMalformed() { recover("malformed") }

    func handleClosed(_ reason: ConversationClosedReason) {
        phase = .closed(reason)
        if reason == .lost { recover("lost") } else { publish(); onPresentationChange() }
    }

    // MARK: History

    private func nextRequestID(_ prefix: String) -> String {
        requestSerial += 1
        return "\(prefix)-\(requestSerial)"
    }

    private func loadInitial() {
        guard let ready, let viewID = transcript?.viewID else { return }
        let request = ConversationHistoryRequest(reference: key.reference, viewID: viewID, requestID: nextRequestID("h"),
                                                 operation: .initial, cursor: ready.windowToken)
        phase = .loadingHistory
        publish()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let page = try await self.fetch(request)
                guard var transcript = self.transcript, transcript.viewID == viewID, transcript.adoptInitial(page) else { return }
                for update in self.buffered {
                    switch transcript.apply(update) {
                    case .applied:
                        if let state = update.state { self.adoptLiveState(state) }
                        self.acknowledge(update)
                    case .gap:
                        self.transcript = transcript
                        self.buffered.removeAll()
                        self.recover("gap")
                        return
                    case .notReady, .foreign: continue
                    }
                }
                self.buffered.removeAll()
                self.transcript = transcript
                self.staleRows = []
                self.olderState = Self.olderState(for: transcript)
                self.phase = .ready
                self.publish()
            } catch {
                guard self.transcript?.viewID == viewID else { return }
                let failure = error as? ConversationHistoryFailure ?? ConversationHistoryFailure("network")
                if failure.retiresView { self.recover(failure.code) } else { self.phase = .historyFailed(failure.code); self.publish() }
            }
        }
    }

    private static func olderState(for transcript: ConversationTranscript) -> CorralConversationPaneState.Older {
        if transcript.reachedDisplayLimit { return .limit }
        if transcript.hasMoreBefore { return .available }
        return transcript.historySupport == "complete" && !transcript.sourceOmitted ? .complete : .partial
    }

    func loadOlder() {
        guard !olderInFlight, let transcript, transcript.initialAdopted, transcript.hasMoreBefore,
              let cursor = transcript.beforeCursor else { return }
        let viewID = transcript.viewID
        let request = ConversationHistoryRequest(reference: key.reference, viewID: viewID, requestID: nextRequestID("p"),
                                                 operation: .before, cursor: cursor)
        olderInFlight = true
        olderState = .loading
        publish()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.transcript?.viewID == viewID { self.olderInFlight = false } }
            do {
                let page = try await self.fetch(request)
                guard var transcript = self.transcript, transcript.viewID == viewID, transcript.adoptOlder(page, cursor: cursor) else { return }
                self.transcript = transcript
                self.olderState = Self.olderState(for: transcript)
            } catch {
                guard self.transcript?.viewID == viewID else { return }
                let failure = error as? ConversationHistoryFailure ?? ConversationHistoryFailure("network")
                if failure.retiresView { self.olderInFlight = false; self.recover(failure.code); return }
                self.olderState = .failed(failure.code)
            }
            self.olderInFlight = false
            self.publish()
        }
    }

    // MARK: Bodies

    private func requestBodies(_ ids: [String]) {
        for id in ids {
            bodyFailures.removeValue(forKey: id)
            if !bodyQueue.contains(id) { bodyQueue.append(id) }
        }
        pumpBodies()
    }

    private func needsBody(_ item: ConversationItem) -> Bool {
        guard item.isDeferred, let transcript else { return false }
        if let failure = bodyFailures[item.id], failure.revision == item.revision { return false }
        guard let body = transcript.body(for: item.id) else { return true }
        return body.revision < item.revision || !body.complete
    }

    /// A streaming deferred item gets a fresh body once its previous fetch completes.
    private func refreshStreamingBodies(_ items: [ConversationItem]) {
        guard let transcript else { return }
        for item in items where item.isDeferred && transcript.body(for: item.id) != nil && !bodyQueue.contains(item.id) {
            bodyQueue.append(item.id)
        }
        pumpBodies()
    }

    private func pumpBodies() {
        guard bodyInFlight == nil, let transcript, transcript.initialAdopted, let ready else { return }
        while let id = bodyQueue.first {
            bodyQueue.removeFirst()
            guard let item = transcript.item(id: id), needsBody(item), let bodyRef = item.bodyRef else { continue }
            bodyInFlight = id
            publish()
            let viewID = transcript.viewID
            Task { @MainActor [weak self] in
                guard let self else { return }
                var text = ""
                var cursor = ready.windowToken
                var complete = false
                var failure: ConversationHistoryFailure?
                for _ in 0..<Self.maximumBodyChunks {
                    let request = ConversationHistoryRequest(reference: self.key.reference, viewID: viewID, requestID: self.nextRequestID("b"),
                                                             operation: .body, cursor: cursor, bodyRef: bodyRef)
                    do {
                        let page = try await self.fetch(request)
                        guard self.transcript?.viewID == viewID, page.bodyRef == nil || page.bodyRef == bodyRef else { return }
                        text += page.body ?? ""
                        if page.bodyComplete { complete = true; break }
                        guard let next = page.bodyCursor, !next.isEmpty, text.utf8.count <= ConversationTranscript.maximumBodyBytes else {
                            failure = ConversationHistoryFailure("too_large")
                            break
                        }
                        cursor = next
                    } catch {
                        failure = error as? ConversationHistoryFailure ?? ConversationHistoryFailure("network")
                        break
                    }
                }
                guard var transcript = self.transcript, transcript.viewID == viewID else { return }
                self.bodyInFlight = nil
                if complete, transcript.storeBody(id: id, revision: item.revision, text: text, complete: true) {
                    self.transcript = transcript
                } else if let failure {
                    if failure.retiresView { self.recover(failure.code); return }
                    self.bodyFailures[id] = (item.revision, failure.code)
                }
                self.publish()
                self.pumpBodies()
            }
            return
        }
    }

    // MARK: Native state

    private func requestNativeState() {
        let id = nextRequestID("gs")
        stateCommandID = id
        let reference = key.reference
        Task { @MainActor [weak self] in
            do { try await self?.send(.conversationCommand(reference: reference, id: id, command: Data(#"{"type":"get_state"}"#.utf8))) }
            catch { if self?.stateCommandID == id { self?.stateCommandID = nil } }
        }
    }

    private func adoptLiveState(_ state: ConversationLiveState) {
        let modeChanged = state.mode != liveState?.mode
        liveState = state
        if modeChanged { onPresentationChange() }
    }

    /// Applied is cumulative: one acknowledgement per run-loop turn carries the newest adopted commit.
    private func acknowledge(_ update: ConversationUpdate) {
        let flushPending = pendingApplied == nil
        pendingApplied = (update.viewID, update.sourceEpoch, update.commitSeq)
        guard flushPending else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let applied = self.pendingApplied else { return }
            self.pendingApplied = nil
            guard applied.viewID == self.transcript?.viewID else { return }
            let command = ClientCommand.conversationApplied(reference: self.key.reference, viewID: applied.viewID,
                                                            sourceEpoch: applied.sourceEpoch, commitSeq: applied.commitSeq)
            let send = self.send
            Task { @MainActor in try? await send(command) }
        }
    }

    // MARK: Recovery

    /// One small-window resubscribe per loss episode, bounded to three a minute; never a WebSocket reconnect.
    private func recover(_ reason: String) {
        let now = Date()
        recoveries = recoveries.filter { now.timeIntervalSince($0) < 60 }
        buffered.removeAll()
        guard recoveries.count < 3 else {
            phase = .historyFailed(reason)
            publish()
            return
        }
        recoveries.append(now)
        phase = .recovering(reason)
        publish()
        let reference = key.reference
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(reason == "lost" ? 800 : 150))
            guard let self, case .recovering = self.phase else { return }
            do { try await self.send(.conversationSubscribe(reference: reference)) }
            catch { self.phase = .historyFailed("network"); self.publish() }
        }
    }

    func retry() {
        switch phase {
        case .historyFailed:
            if transcript?.initialAdopted == true || transcript == nil { recoveries.removeAll(); recover("retry") }
            else { loadInitial() }
        case .closed:
            recoveries.removeAll()
            recover("retry")
        default: break
        }
    }

    // MARK: Presentation

    /// Coalesces bursts of live commits into one AppKit update per run-loop turn.
    private func publish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publishScheduled = false
            self.pane.apply(self.paneState())
        }
    }

    func publishNow() {
        publishScheduled = false
        pane.apply(paneState())
    }

    func paneState() -> CorralConversationPaneState {
        let phase: CorralConversationPaneState.Phase = switch self.phase {
        case .subscribing: .connecting
        case .loadingHistory: .loadingHistory
        case .ready: .ready
        case let .historyFailed(code): .historyFailed(code)
        case let .recovering(reason): .reconnecting(reason)
        case let .closed(reason): reason == .lost ? .reconnecting("lost") : .unavailable(reason.rawValue)
        }
        let thinking = nativeState.thinkingLevel.map { $0 == "off" ? "思考关" : "思考 \($0)" }
        let modelLabel = [nativeState.model, thinking].compactMap { $0 }.joined(separator: " · ")
        return CorralConversationPaneState(
            title: nativeState.sessionName ?? title,
            provider: provider,
            modelLabel: modelLabel.isEmpty ? nil : modelLabel,
            phase: phase,
            running: liveState?.running,
            queued: liveState?.queued ?? 0,
            older: olderInFlight ? .loading : olderState,
            rows: rows()
        )
    }

    private func rows() -> [CorralConversationRow] {
        guard let transcript, transcript.initialAdopted else { return staleRows }
        return transcript.items.map { item in
            let body = transcript.body(for: item.id)
            var text = item.summary
            var state: CorralConversationRow.Body = .complete
            var arguments: String?
            var output: String?
            if item.isDeferred {
                if let body, body.complete, body.revision == item.revision {
                    text = body.text
                } else {
                    // A previous revision of a streaming body is still the most complete text available.
                    if let body, body.text.utf8.count > item.summary.utf8.count { text = body.text }
                    if bodyInFlight == item.id { state = .loading }
                    else if let failure = bodyFailures[item.id], failure.revision == item.revision { state = .failed(failure.code) }
                    else { state = .summary }
                }
                if item.kind == "tool", let body, body.complete, let parsed = Self.toolBody(body.text) {
                    arguments = parsed.arguments
                    output = parsed.output
                    if body.revision == item.revision { state = .complete }
                }
            }
            return CorralConversationRow(
                id: item.id, revision: item.revision, kind: Self.kind(item.kind), text: text, body: state,
                streaming: item.streaming, observedSuffix: item.contentState == "observed_suffix", imageCount: item.imageCount,
                redacted: item.redacted, toolName: item.toolName, toolPhase: item.toolPhase, toolArguments: arguments, toolOutput: output)
        }
    }

    private static func kind(_ wire: String) -> CorralConversationRow.Kind {
        switch wire {
        case "user": .user
        case "assistant": .assistant
        case "reasoning": .reasoning
        case "tool": .tool
        case "notice": .notice
        default: .other(wire)
        }
    }

    /// A complete tool body is `{"arguments":<JSON>,"output":"<text>"}`; partial chunks are never parsed.
    static func toolBody(_ text: String) -> (arguments: String?, output: String)? {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var arguments: String?
        if let raw = object["arguments"], !(raw is NSNull) {
            if let string = raw as? String { arguments = string }
            else if JSONSerialization.isValidJSONObject(raw), let encoded = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) {
                arguments = String(decoding: encoded, as: UTF8.self)
            }
        }
        return (arguments, object["output"] as? String ?? "")
    }
}
