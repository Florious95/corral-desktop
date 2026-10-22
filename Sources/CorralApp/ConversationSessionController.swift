import AppKit
import CorralContracts
import CorralServices
import CorralUI
import Foundation

/// One managed agent pane on one authenticated connection.
/// - Windowed lane (Core contract 11): ready → initial HTTP page at H → buffered then contiguous live commits,
///   each acknowledged only after adoption. HTTP failures stay local to this pane.
/// - Control lane: a non-windowed stream whose replay is ignored; it proves a TUI-mode pane's native mode and
///   carries `switch_mode` back to RPC, because a Pi TUI has no windowed source.
/// The presented mode follows the native mode Core confirms, never the local switch intent.
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

    enum Lane: Equatable { case windowed, control }
    enum NativeMode: Equatable { case unknown, rpc, tui }

    /// One serial native mode change: requested, possibly awaiting the user's busy consent, then confirmed.
    struct ModeSwitch: Equatable {
        let target: CorralViewportHeaderState.Mode
        var force: Bool
        var awaitingConsent = false
        var commandID: String?
        let automatic: Bool
        var started = Date()
    }

    struct NativeState: Equatable {
        var sessionName: String?
        var model: String?
        var thinkingLevel: String?
    }

    let key: SessionKey
    private(set) var connectionEpoch: ConnectionEpoch
    let pane = CorralConversationPaneView()
    let header = CorralViewportHeaderView()
    private(set) var lane: Lane = .windowed
    private(set) var nativeMode: NativeMode = .unknown
    /// Core proved this pane is a managed structured agent (a windowed or control ready arrived).
    private(set) var managed = false
    /// Neither lane can attach: the pane is not (or no longer) a managed agent; plain terminal.
    private(set) var unavailable = false
    private(set) var modeSwitch: ModeSwitch?
    private var controlProbeAttempted = false
    private var controlRecoveries: [Date] = []
    private var notice: (text: String, tone: CorralViewportHeaderState.Tone, until: Date)?
    /// The user's default open mode, applied once after an explicit open when the pane is idle.
    private var preferredOnOpen: CorralViewportHeaderState.Mode?
    private var switchTimeout: Task<Void, Never>?
    private static let switchTimeoutSeconds: Double = 45
    private(set) var phase: Phase = .subscribing
    private(set) var ready: ConversationReady?
    private(set) var transcript: ConversationTranscript?
    private(set) var liveState: ConversationLiveState?
    private(set) var nativeState = NativeState()
    var title = "" { didSet { if oldValue != title { publish() } } }
    var provider: String?

    /// Wire and HTTP are injected; the controller owns ordering and ownership checks only.
    var send: (ClientCommand) async throws -> Void = { _ in }
    var fetch: (ConversationHistoryRequest) async throws -> ConversationHistoryPage = { _ in throw ConversationHistoryFailure("network") }
    var onPresentationChange: () -> Void = {}
    /// Busy native work needs explicit consent before a forced switch; nil answer means cancelled.
    var onConsentNeeded: (CorralViewportHeaderState.Mode) -> Void = { _ in }

    private var buffered: [ConversationUpdate] = []
    private var olderState: CorralConversationPaneState.Older = .complete
    private var olderInFlight = false
    private var bodyQueue: [String] = []
    private var bodyInFlight: String?
    private var bodyFailures: [String: (revision: UInt64, code: String)] = [:]
    private var requestSerial = 0
    private var stateCommandID: String?
    private var usageCommandID: String?
    private var usageTimeout: Task<Void, Never>?
    private(set) var usageDashboard: CorralUsageDashboardController?
    private let actions: [any CorralAtomicAction] = [CorralUsageAction(scopes: [.session]), CorralModeSwitchAction()]
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
        header.onSelectMode = { [weak self] mode in self?.requestSwitch(to: mode) }
        header.makeActionMenu = { [weak self] in self?.actionMenu() }
    }

    /// Whether this pane should currently show the structured view instead of the terminal.
    var presentsConversation: Bool { !unavailable && nativeMode != .tui }
    /// Managed panes (and panes still being identified) carry the viewport header in either presentation.
    var presentsHeader: Bool { !unavailable }

    func start() {
        phase = .subscribing
        lane = .windowed
        publish()
        subscribe(.windowed)
    }

    private func subscribe(_ target: Lane) {
        lane = target
        let reference = key.reference
        let command: ClientCommand = target == .windowed ? .conversationSubscribe(reference: reference) : .conversationSubscribeControl(reference: reference)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.send(command) }
            catch { self.phase = .recovering("network"); self.publish() }
        }
    }

    /// A reconnect invalidates every view; the pane keeps its rows while the new view's history loads.
    func rebind(to epoch: ConnectionEpoch) {
        guard epoch != connectionEpoch else { return }
        invalidateUsage("连接已改变，请关闭后重新打开用量面板")
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
        controlRecoveries.removeAll()
        controlProbeAttempted = false
        unavailable = false
        // A switch written on the old connection has an unknown outcome; the new lane's ready reports the truth.
        if modeSwitch != nil { finishSwitch(notice: "切换结果未确认，已按主机当前模式显示", tone: .warning) }
        start()
    }

    func stop() {
        closeUsage()
        let reference = key.reference
        let send = self.send
        Task { @MainActor in try? await send(.conversationUnsubscribe(reference: reference)) }
    }

    // MARK: Wire events

    func handleReady(_ value: ConversationReady) {
        invalidateUsage("会话视图已改变，请关闭后重新打开用量面板")
        if let current = transcript, current.viewID == value.viewID { return }
        if transcript?.initialAdopted == true { staleRows = rows() }
        lane = .windowed
        managed = true
        unavailable = false
        controlProbeAttempted = false
        nativeMode = value.mode == "tui" ? .tui : .rpc
        if modeSwitch?.target == .gui { finishSwitch(notice: nil) }
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
        applyPreferredModeIfIdle()
    }

    /// A control lane's ready is the worker's own statement of the pane's mode.
    func handleControlReady(mode: String, running: Bool) {
        lane = .control
        managed = true
        unavailable = false
        let confirmed: NativeMode = mode == "tui" ? .tui : .rpc
        nativeMode = confirmed
        phase = .ready
        if confirmed == .rpc {
            if var pending = modeSwitch, pending.target == .tui, pending.commandID != nil {
                // Core refuses an unforced switch while Pi works, and that refusal went to the retired view.
                if running, !pending.force {
                    if pending.automatic {
                        finishSwitch(notice: "Pi 正在运行任务，已保持 GUI", tone: .warning)
                        subscribe(.windowed)
                        return
                    }
                    pending.awaitingConsent = true
                    pending.commandID = nil
                    modeSwitch = pending
                    switchTimeout?.cancel()
                    publish()
                    onConsentNeeded(.tui)
                    return
                }
                // Mid-switch the worker still reports rpc: it publishes worker_mode only once the replacement Pi
                // is confirmed (its response id belongs to the retired view), so wait here for that event.
                publish()
                return
            }
            // Not a TUI after all: the structured view belongs on the windowed lane.
            onPresentationChange()
            subscribe(.windowed)
            return
        }
        if let pending = modeSwitch {
            if pending.target == .tui { finishSwitch(notice: nil) }
            else if pending.commandID == nil { sendSwitch() }
        }
        publish()
        onPresentationChange()
        applyPreferredModeIfIdle()
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
        guard event.reference == key.reference else { return }
        // A control lane replays retained native records; only our response and mode changes matter.
        if lane == .control, !Self.mentions(event.event, ["worker_mode", modeSwitch?.commandID].compactMap { $0 }) { return }
        guard event.viewID == nil || event.viewID == transcript?.viewID,
              let object = try? JSONSerialization.jsonObject(with: event.event) as? [String: Any] else { return }
        if object["type"] as? String == "worker_mode", let mode = object["mode"] as? String {
            handleWorkerMode(mode)
            return
        }
        guard object["type"] as? String == "response", let id = object["id"] as? String else { return }
        if id == modeSwitch?.commandID {
            handleSwitchResponse(success: object["success"] as? Bool == true, data: object["data"] as? [String: Any], error: object["error"] as? String)
            return
        }
        if id == usageCommandID {
            guard event.sourceEpoch == nil || event.sourceEpoch == transcript?.sourceEpoch else { return }
            handleUsageResponse(object)
            return
        }
        guard id == stateCommandID else { return }
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
        // A requested switch to the TUI retires the windowed source; the control lane confirms the new mode.
        if modeSwitch?.target == .tui, modeSwitch?.commandID != nil {
            subscribe(.control)
            return
        }
        recover(reason)
    }

    func handleMalformed() { recover("malformed") }

    func handleClosed(_ reason: ConversationClosedReason) {
        invalidateUsage("会话连接已结束，暂时无法读取用量")
        switch lane {
        case .windowed:
            if reason == .lost { phase = .closed(reason); recover("lost"); return }
            // A managed Pi in its TUI has no windowed source; ask the worker itself before falling back.
            if modeSwitch?.target == .tui || !controlProbeAttempted {
                controlProbeAttempted = true
                subscribe(.control)
                return
            }
        case .control:
            if reason == .lost, recoverControl() { return }
        }
        phase = .closed(reason)
        managed = false
        unavailable = true
        nativeMode = .unknown
        if modeSwitch != nil { finishSwitch(notice: nil) }
        publish()
        onPresentationChange()
    }

    private func recoverControl() -> Bool {
        let now = Date()
        controlRecoveries = controlRecoveries.filter { now.timeIntervalSince($0) < 60 }
        guard controlRecoveries.count < 3 else { return false }
        controlRecoveries.append(now)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, self.lane == .control, !self.unavailable else { return }
            self.subscribe(.control)
        }
        return true
    }

    // MARK: Mode switching

    /// The viewport switcher and the default-mode preference share this one serial native operation.
    func requestSwitch(to target: CorralViewportHeaderState.Mode, automatic: Bool = false) {
        guard modeSwitch == nil, managed, !unavailable else { return }
        let current: CorralViewportHeaderState.Mode = nativeMode == .tui ? .tui : .gui
        guard target != current else { return }
        // Each direction needs its own attached lane; otherwise nothing is written.
        let attached = target == .tui ? (lane == .windowed && transcript != nil) : (lane == .control && phase == .ready)
        guard attached else {
            if !automatic { showNotice("会话尚未就绪，请稍后再切换", tone: .warning) }
            return
        }
        closeUsage()
        notice = nil
        modeSwitch = ModeSwitch(target: target, force: false, automatic: automatic)
        sendSwitch()
    }

    /// Busy consent: the user explicitly agreed to stop the running native task for this switch.
    func confirmSwitch() {
        guard var pending = modeSwitch, pending.awaitingConsent else { return }
        pending.awaitingConsent = false
        pending.force = true
        pending.commandID = nil
        modeSwitch = pending
        sendSwitch()
    }

    /// Cancelling consent writes nothing; the pane keeps its confirmed mode.
    func cancelSwitch() {
        guard modeSwitch?.awaitingConsent == true else { return }
        finishSwitch(notice: nil)
        // The refusal left only the control lane attached to a still-running RPC Pi; resume the live view.
        if lane == .control, nativeMode == .rpc { subscribe(.windowed) }
    }

    private func sendSwitch() {
        guard var pending = modeSwitch else { return }
        let id = nextRequestID("sw")
        pending.commandID = id
        pending.started = Date()
        modeSwitch = pending
        publish()
        let body = (try? JSONSerialization.data(withJSONObject: ["type": "switch_mode", "mode": pending.target == .tui ? "tui" : "rpc", "force": pending.force])) ?? Data()
        let reference = key.reference
        Task { @MainActor [weak self] in
            do { try await self?.send(.conversationCommand(reference: reference, id: id, command: body)) }
            catch { if self?.modeSwitch?.commandID == id { self?.finishSwitch(notice: "切换请求未能发送", tone: .error) } }
        }
        switchTimeout?.cancel()
        switchTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.switchTimeoutSeconds))
            guard let self, self.modeSwitch?.commandID == id else { return }
            // Never resend a switch whose outcome is unknown: re-read the worker's mode instead.
            self.finishSwitch(notice: "切换结果未确认，正在核实当前模式…", tone: .warning)
            self.subscribe(.control)
        }
    }

    private func handleSwitchResponse(success: Bool, data: [String: Any]?, error: String?) {
        guard let pending = modeSwitch else { return }
        if success {
            let mode = data?["mode"] as? String
            if pending.target == .tui || mode == "tui" {
                // The windowed source is gone with the RPC process; the control lane confirms and observes.
                subscribe(.control)
            } else {
                nativeMode = .rpc
                // worker_mode usually arrives first and already moved to the windowed lane.
                if lane == .control { subscribe(.windowed) }
            }
            return
        }
        if data?["busy"] as? Bool == true, !pending.force {
            if pending.automatic {
                finishSwitch(notice: pending.target == .tui ? "Pi 正在运行任务，已保持 GUI" : "Pi 正在运行任务，已保持终端", tone: .warning)
                return
            }
            var waiting = pending
            waiting.awaitingConsent = true
            waiting.commandID = nil
            modeSwitch = waiting
            switchTimeout?.cancel()
            publish()
            onConsentNeeded(pending.target)
            return
        }
        finishSwitch(notice: "切换失败：\(error ?? "主机拒绝")", tone: .error)
    }

    private func handleWorkerMode(_ mode: String) {
        let confirmed: NativeMode = mode == "tui" ? .tui : .rpc
        guard confirmed != nativeMode || modeSwitch != nil else { return }
        if confirmed != nativeMode { closeUsage() }
        nativeMode = confirmed
        if confirmed == .rpc, lane == .control {
            // Another client (or our own control-lane switch) brought the pane back to RPC.
            subscribe(.windowed)
        } else if confirmed == .tui, modeSwitch?.target == .tui {
            finishSwitch(notice: nil)
        }
        publish()
        onPresentationChange()
    }

    private func finishSwitch(notice text: String?, tone: CorralViewportHeaderState.Tone = .info) {
        switchTimeout?.cancel()
        switchTimeout = nil
        modeSwitch = nil
        if let text { showNotice(text, tone: tone) }
        publish()
    }

    func showSwitchNotice(_ text: String, tone: CorralViewportHeaderState.Tone) { showNotice(text, tone: tone) }

    private func showNotice(_ text: String, tone: CorralViewportHeaderState.Tone) {
        let until = Date().addingTimeInterval(6)
        notice = (text, tone, until)
        publish()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6.2))
            guard let self, let current = self.notice, current.until <= Date() else { return }
            self.notice = nil
            self.publish()
        }
    }

    /// Records the default open mode for one explicit open; applied as soon as the pane's mode is known.
    func noteExplicitOpen(preferred: CorralViewportHeaderState.Mode) {
        preferredOnOpen = preferred
        applyPreferredModeIfIdle()
    }

    private func applyPreferredModeIfIdle() {
        guard let preferred = preferredOnOpen, managed, modeSwitch == nil, nativeMode != .unknown else { return }
        let current: CorralViewportHeaderState.Mode = nativeMode == .tui ? .tui : .gui
        if preferred == current { preferredOnOpen = nil; return }
        if preferred == .tui {
            // Only a confirmed idle RPC pane is switched; a busy one keeps its mode, visibly.
            guard transcript != nil, let running = liveState?.running else { return }
            preferredOnOpen = nil
            if running { showNotice("Pi 正在运行任务，已保持 GUI", tone: .warning); return }
        } else {
            guard lane == .control, phase == .ready else { return }
            preferredOnOpen = nil
        }
        requestSwitch(to: preferred, automatic: true)
    }

    private static func mentions(_ data: Data, _ needles: [String]) -> Bool {
        needles.contains { needle in data.range(of: Data(needle.utf8)) != nil }
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

    // MARK: Atomic actions and session usage

    private func actionContext() -> CorralActionContext {
        CorralActionContext(ready: managed && !unavailable && phase == .ready,
                            mode: nativeMode == .tui ? .tui : .gui, running: liveState?.running,
                            switching: modeSwitch != nil, implemented: [.metricsPanel, .modeSwitch])
    }

    func actionMenu() -> CorralActionMenu? {
        guard managed, !unavailable else { return nil }
        let context = actionContext()
        let entries = actions.map { action in
            CorralActionMenuEntry(spec: action.spec, availability: action.availability(in: context),
                                  title: action.spec.id == .terminal && context.mode == .tui ? "切换到原生 GUI" : nil)
        }
        return CorralActionMenu(entries: entries) { [weak self] id in self?.performAction(id) }
    }

    @discardableResult
    func performAction(_ id: CorralActionID) -> Bool {
        guard let action = actions.first(where: { $0.spec.id == id }) else { return false }
        return action.perform(in: actionContext()) { presentation in
            switch presentation {
            case .metricsPanel: openUsage()
            case .modeSwitch: requestSwitch(to: nativeMode == .tui ? .gui : .tui)
            default: break // Unimplemented presentations are excluded by the capability gate above.
            }
        }
    }

    private func openUsage() {
        guard usageDashboard == nil else { return }
        let dashboard = CorralUsageDashboardController(sessionTitle: nativeState.sessionName ?? title)
        dashboard.onRefresh = { [weak self] in self?.refreshUsage() }
        dashboard.onClose = { [weak self] in self?.closeUsage() }
        usageDashboard = dashboard
        // Never fall back to another pane/window, including when a late action targets a closed pane.
        if let window = header.window { dashboard.present(over: window) }
        refreshUsage()
    }

    func refreshUsage() {
        guard let dashboard = usageDashboard, usageCommandID == nil else { return }
        guard CorralUsageAction(scopes: [.session]).availability(in: actionContext()) == .enabled else {
            invalidateUsage("当前会话不可读取用量，请关闭后重试")
            return
        }
        let id = nextRequestID("usage")
        usageCommandID = id
        dashboard.apply(.loading)
        let command = ClientCommand.conversationCommand(reference: key.reference, id: id, command: Data(#"{"type":"get_session_stats"}"#.utf8))
        Task { @MainActor [weak self] in
            guard let self, self.usageCommandID == id else { return }
            do { try await self.send(command) }
            catch { if self.usageCommandID == id { self.finishUsage(.failed("用量读取失败，请重试")) } }
        }
        usageTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.usageCommandID == id else { return }
            self.finishUsage(.failed("用量读取超时，请重试"))
        }
    }

    private func handleUsageResponse(_ object: [String: Any]) {
        guard object["success"] as? Bool == true else {
            finishUsage(.failed("当前来源无法提供用量，请稍后重试"))
            return
        }
        guard let data = object["data"] as? [String: Any],
              let encoded = try? JSONSerialization.data(withJSONObject: data),
              let usage = try? JSONDecoder().decode(CorralSessionUsage.self, from: encoded), usage.isValid else {
            finishUsage(.failed("用量响应不完整，未显示估算数值"))
            return
        }
        finishUsage(.ready(usage, Date()))
    }

    private func finishUsage(_ state: CorralUsageDashboardController.State) {
        usageCommandID = nil
        usageTimeout?.cancel(); usageTimeout = nil
        usageDashboard?.apply(state)
    }

    private func invalidateUsage(_ reason: String) { finishUsage(.unavailable(reason)) }

    private func closeUsage() {
        usageCommandID = nil
        usageTimeout?.cancel(); usageTimeout = nil
        usageDashboard?.closeDialog()
        usageDashboard = nil
    }

    // MARK: Recovery

    /// One small-window resubscribe per loss episode, bounded to three a minute; never a WebSocket reconnect.
    private func recover(_ reason: String) {
        invalidateUsage("会话正在重新连接，请关闭后重新打开用量面板")
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
            self.header.apply(self.headerState())
        }
    }

    func publishNow() {
        publishScheduled = false
        pane.apply(paneState())
        header.apply(headerState())
    }

    func headerState() -> CorralViewportHeaderState {
        let pane = paneState()
        let ready = managed && (lane == .control ? phase == .ready : transcript != nil)
        return CorralViewportHeaderState(
            title: pane.title, provider: provider, modelLabel: pane.modelLabel, phase: pane.phase, running: pane.running, queued: pane.queued,
            mode: nativeMode == .tui ? .tui : .gui, pendingMode: modeSwitch.flatMap { $0.awaitingConsent ? nil : $0.target },
            canSwitch: managed ? ready && modeSwitch?.awaitingConsent != true : nil,
            switchHint: ready ? nil : "会话尚未就绪",
            notice: notice?.text, noticeTone: notice?.tone ?? .info, hasActions: managed && !unavailable)
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
