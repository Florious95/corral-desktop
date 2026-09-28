import AppKit
import CorralContracts
import CorralMetalTerminal
import CorralProtocol
import CorralUI
import Foundation
@preconcurrency import SwiftTerm

@MainActor
public final class CorralMVPCoordinator: @preconcurrency TerminalViewDelegate {
    public let window: NSWindow
    public let workspaceView: CorralMVPWorkspaceView

    public private(set) var selectedAgentID: UUID?
    public private(set) var connected = false
    public private(set) var lastConnectionError: String?
    public private(set) var sessionRows: [CorralMVPSessionRow] = []
    private(set) var desiredStageGrid: GridSize?

    private struct RuntimeSession {
        var descriptor: SessionDescriptor
        var terminalView: CorralNativeTerminalView? = nil
        var subscribed = false
        var subscriptionPending = false
        var lastByteWasCarriageReturn = false
        var desiredGrid: GridSize?
        var lastResizeGrid: GridSize?
        var resizePendingGrid: GridSize?
    }

    private struct ResizeRequest {
        let sessionID: UUID
        let grid: GridSize
        let generation: UInt64
    }

    private struct PendingInput {
        let reference: SessionReference
        let bytes: Data
    }

    private let sessionLink: any SessionLinkProtocol
    private let endpoint: ApprovedEndpoint?
    private let credential: CredentialHandle?
    private let noResizeMode: Bool
    private let deviceID = DeviceID("corral-native-mvp")
    private var connection: AuthenticatedConnection?
    private var eventTask: Task<Void, Never>?
    private var sessions: [UUID: RuntimeSession] = [:]
    private var idByReference: [SessionReference: UUID] = [:]
    private var idByTerminalView: [ObjectIdentifier: UUID] = [:]
    private var sessionOrder: [UUID] = []
    private var listingSequence: UInt64 = 0
    private var nextRequestID: UInt32 = 0
    private var nextInputSequence: UInt32 = 0
    private var listingRequestedEpoch: ConnectionEpoch?
    private var resizeRequestGeneration: UInt64 = 0
    private var pendingResize: ResizeRequest?
    private var resizeTask: Task<Void, Never>?
    private var pendingInputs: [PendingInput] = []
    private var inputTask: Task<Void, Never>?

    public init(
        sessionLink: any SessionLinkProtocol,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workspaceView: CorralMVPWorkspaceView = CorralMVPWorkspaceView(frame: .zero)
    ) {
        self.sessionLink = sessionLink
        self.workspaceView = workspaceView
        self.endpoint = try? CorralMVPConfiguration.endpoint(environment: environment)
        self.credential = environment["CORRAL_NATIVE_TOKEN"].flatMap { $0.isEmpty ? nil : CredentialHandle($0) }
        self.noResizeMode = environment["CORRAL_NATIVE_NO_RESIZE"] == "1"

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Corral Native"
        window.contentView = workspaceView
        self.window = window
        workspaceView.onSelectAgent = { [weak self] id in self?.switchSession(id) }
    }

    public func start() async {
        guard let endpoint else {
            lastConnectionError = "Invalid CORRAL_NATIVE_ENDPOINT"
            return
        }
        guard let credential else {
            lastConnectionError = "CORRAL_NATIVE_TOKEN is required"
            return
        }

        do {
            let stream = try await sessionLink.eventStream()
            eventTask = Task { @MainActor [weak self] in await self?.consume(stream) }
            let authenticated = try await sessionLink.connect(to: endpoint, deviceID: deviceID, credential: credential)
            connection = authenticated
            connected = true
            await requestListing()
        } catch {
            connected = false
            lastConnectionError = String(describing: error)
        }
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        inputTask?.cancel()
        inputTask = nil
        pendingResize = nil
        pendingInputs.removeAll(keepingCapacity: false)
        for runtime in sessions.values { runtime.terminalView?.terminalDelegate = nil }
        await sessionLink.disconnect()
        connection = nil
        connected = false
    }

    /// Changes only the permanent Stage's presentation pointer; cached sessions stay subscribed and parsed.
    public func switchSession(_ id: UUID) {
        guard sessions[id] != nil, let terminalView = makeTerminalView(for: id) else { return }
        if let previousID = selectedAgentID, previousID != id {
            resizeRequestGeneration &+= 1
            pendingResize = nil
            if var previous = sessions[previousID] {
                previous.resizePendingGrid = nil
                sessions[previousID] = previous
            }
        }
        selectedAgentID = id
        workspaceView.stageContainer.subviews.filter { $0 !== terminalView }.forEach { $0.removeFromSuperview() }
        workspaceView.attachStageView(terminalView)
        _ = window.makeFirstResponder(terminalView)
        updateSessionRows()
        guard let runtime = sessions[id] else { return }
        if !runtime.subscribed && !runtime.subscriptionPending {
            Task { @MainActor [weak self] in await self?.subscribe(id) }
        } else if let grid = runtime.desiredGrid {
            scheduleResize(for: id, grid: grid)
        }
    }

    private func makeTerminalView(for id: UUID) -> CorralNativeTerminalView? {
        guard var runtime = sessions[id] else { return nil }
        if let terminalView = runtime.terminalView { return terminalView }
        let terminalView = CorralNativeTerminalView(frame: .zero)
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        terminalView.terminalDelegate = self
        runtime.terminalView = terminalView
        sessions[id] = runtime
        idByTerminalView[ObjectIdentifier(terminalView)] = id
        return terminalView
    }

    private func consume(_ stream: any SessionEventStream) async {
        do {
            while !Task.isCancelled {
                guard let envelope = try await stream.next() else { return }
                await receive(envelope)
            }
        } catch is CancellationError {
            return
        } catch {
            connected = false
            lastConnectionError = String(describing: error)
        }
    }

    private func receive(_ envelope: SessionEventEnvelope) async {
        if case let .connectionChanged(state) = envelope.event {
            switch state {
            case .authenticatedReady:
                guard let authenticated = try? AuthenticatedConnection(
                    linkInstanceID: envelope.origin.linkInstanceID,
                    deviceID: envelope.origin.deviceID,
                    connectionEpoch: envelope.origin.connectionEpoch
                ) else { return }
                let changed = connection != authenticated
                connection = authenticated
                connected = true
                if changed {
                    listingSequence = 0
                    nextInputSequence = 0
                    await requestListing()
                }
            case .disconnected, .failed:
                if connection?.connectionEpoch == envelope.origin.connectionEpoch { connected = false }
            case .transportOpen, .authenticating:
                break
            }
            return
        }
        guard let connection, envelope.origin.belongs(to: connection) else { return }
        switch envelope.event {
        case let .control(control):
            switch control {
            case let .listing(listing): applyListing(listing)
            case let .listDelta(delta): applyListDelta(delta)
            case let .authAck(ok, reason, _):
                if !ok { lastConnectionError = reason ?? "Authentication failed" }
            case let .error(_, reason): lastConnectionError = reason
            default: break
            }
        case let .frame(frame): applyFrame(frame)
        case let .failed(error):
            connected = false
            lastConnectionError = String(describing: error)
        case .connectionChanged:
            break
        }
    }

    private func requestListing() async {
        guard let connection, listingRequestedEpoch != connection.connectionEpoch,
              nextRequestID < UInt32.max else { return }
        listingRequestedEpoch = connection.connectionEpoch
        nextRequestID += 1
        do {
            let receipt = try await sessionLink.send(.list(requestID: nextRequestID))
            if !receipt.socketWritten { lastConnectionError = "Session listing request was not sent" }
        } catch {
            lastConnectionError = String(describing: error)
        }
    }

    /// SwiftTerm's live parser receives only ordered snapshot/delta frames. Historical scrollback frames
    /// remain isolated from the live terminal state.
    private func applyFrame(_ frame: BinaryFrame) {
        let reference = frame.reference
        guard let id = idByReference[reference], let runtime = sessions[id],
              runtime.subscribed || runtime.subscriptionPending,
              let terminalView = runtime.terminalView else { return }
        let ansi: Data
        let isSnapshot: Bool
        switch frame {
        case let .snapshot(_, data):
            ansi = data
            isSnapshot = true
        case let .delta(_, data):
            ansi = data
            isSnapshot = false
        case .scrollback:
            return
        }
        guard !ansi.isEmpty else { return }
        let normalized = Self.withImplicitCarriageReturn(
            ansi,
            precedingCarriageReturn: isSnapshot ? false : runtime.lastByteWasCarriageReturn
        )
        terminalView.feed(byteArray: normalized.bytes[...])
        if var current = sessions[id] {
            current.lastByteWasCarriageReturn = normalized.trailingCarriageReturn
            sessions[id] = current
        }
    }

    private static func withImplicitCarriageReturn(_ data: Data, precedingCarriageReturn: Bool) -> (bytes: [UInt8], trailingCarriageReturn: Bool) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count)
        var previousWasCarriageReturn = precedingCarriageReturn
        for byte in data {
            if byte == 0x0a, !previousWasCarriageReturn { bytes.append(0x0d) }
            bytes.append(byte)
            previousWasCarriageReturn = byte == 0x0d
        }
        return (bytes, previousWasCarriageReturn)
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard !noResizeMode,
              newCols > 0, newRows > 0,
              newCols <= Int(UInt16.max), newRows <= Int(UInt16.max),
              newRows <= 1_000_000 / newCols,
              let id = idByTerminalView[ObjectIdentifier(source)], var runtime = sessions[id] else { return }
        let grid = GridSize(rows: newRows, columns: newCols)
        runtime.desiredGrid = grid
        sessions[id] = runtime
        if selectedAgentID == id {
            desiredStageGrid = grid
            scheduleResize(for: id, grid: grid)
        }
    }

    private func scheduleResize(for id: UUID, grid: GridSize) {
        guard !noResizeMode,
              selectedAgentID == id, var runtime = sessions[id], runtime.subscribed,
              runtime.descriptor.size != grid, runtime.lastResizeGrid != grid,
              runtime.resizePendingGrid != grid else { return }
        resizeRequestGeneration &+= 1
        runtime.resizePendingGrid = grid
        sessions[id] = runtime
        pendingResize = ResizeRequest(sessionID: id, grid: grid, generation: resizeRequestGeneration)
        guard resizeTask == nil else { return }
        resizeTask = Task { @MainActor [weak self] in await self?.drainPendingResizes() }
    }

    private func drainPendingResizes() async {
        while !Task.isCancelled, let request = pendingResize {
            pendingResize = nil
            await applyResize(request)
        }
        resizeTask = nil
    }

    private func applyResize(_ request: ResizeRequest) async {
        guard !noResizeMode, isCurrentResize(request), let runtime = sessions[request.sessionID] else {
            clearPendingResize(request)
            return
        }
        do {
            let receipt = try await sessionLink.send(.resize(reference: runtime.descriptor.key.reference, size: request.grid))
            guard var latest = sessions[request.sessionID] else { return }
            guard receipt.socketWritten else {
                if latest.resizePendingGrid == request.grid { latest.resizePendingGrid = nil }
                sessions[request.sessionID] = latest
                lastConnectionError = "Terminal resize was not sent"
                return
            }
            latest.descriptor.size = request.grid
            latest.lastResizeGrid = request.grid
            if latest.resizePendingGrid == request.grid { latest.resizePendingGrid = nil }
            sessions[request.sessionID] = latest
        } catch {
            clearPendingResize(request)
            lastConnectionError = String(describing: error)
        }
    }

    private func isCurrentResize(_ request: ResizeRequest) -> Bool {
        selectedAgentID == request.sessionID && desiredStageGrid == request.grid &&
            resizeRequestGeneration == request.generation &&
            sessions[request.sessionID]?.resizePendingGrid == request.grid
    }

    private func clearPendingResize(_ request: ResizeRequest) {
        guard var runtime = sessions[request.sessionID], runtime.resizePendingGrid == request.grid else { return }
        runtime.resizePendingGrid = nil
        sessions[request.sessionID] = runtime
    }

    private func subscribe(_ id: UUID) async {
        guard var runtime = sessions[id], !runtime.subscribed, !runtime.subscriptionPending else { return }
        runtime.subscriptionPending = true
        sessions[id] = runtime
        do {
            // Use the server-advertised live grid; inspection mode never substitutes local view dimensions.
            let receipt = try await sessionLink.send(.subscribe(reference: runtime.descriptor.key.reference, size: runtime.descriptor.size))
            guard var current = sessions[id] else { return }
            current.subscriptionPending = false
            current.subscribed = receipt.socketWritten
            sessions[id] = current
            if !noResizeMode, receipt.socketWritten, let grid = current.desiredGrid {
                scheduleResize(for: id, grid: grid)
            } else if !receipt.socketWritten {
                lastConnectionError = "Subscription was not sent"
            }
        } catch {
            sessions[id]?.subscriptionPending = false
            lastConnectionError = String(describing: error)
        }
    }

    private func applyListing(_ listing: SessionListing) {
        guard listing.isValid, listing.sequence > listingSequence else { return }
        listingSequence = listing.sequence
        var ordered: [UUID] = []
        for record in listing.workspaces.flatMap(\.sessions) {
            let id = upsert(record)
            if !ordered.contains(id) { ordered.append(id) }
        }
        let removed = Set(sessionOrder).subtracting(ordered)
        for id in removed {
            if let runtime = sessions.removeValue(forKey: id) {
                idByReference.removeValue(forKey: runtime.descriptor.key.reference)
                if let view = runtime.terminalView {
                    idByTerminalView.removeValue(forKey: ObjectIdentifier(view))
                    view.terminalDelegate = nil
                }
            }
        }
        sessionOrder = ordered
        updateSessionRows()
        if let selectedAgentID, sessions[selectedAgentID] != nil {
            switchSession(selectedAgentID)
        } else if let first = ordered.first {
            switchSession(first)
        } else {
            selectedAgentID = nil
            desiredStageGrid = nil
            workspaceView.stageContainer.subviews.forEach { $0.removeFromSuperview() }
            updateSessionRows()
        }
    }

    private func applyListDelta(_ delta: SessionListDelta) {
        guard delta.isValid, delta.sequence > listingSequence else { return }
        listingSequence = delta.sequence
        for reference in delta.removedReferences {
            guard let id = idByReference.removeValue(forKey: reference) else { continue }
            if let runtime = sessions.removeValue(forKey: id), let view = runtime.terminalView {
                idByTerminalView.removeValue(forKey: ObjectIdentifier(view))
                view.terminalDelegate = nil
            }
            sessionOrder.removeAll { $0 == id }
        }
        for record in delta.addedSessions + delta.changedSessions {
            let id = upsert(record)
            if !sessionOrder.contains(id) { sessionOrder.append(id) }
        }
        for workspace in delta.changedWorkspaces {
            for record in workspace.sessions {
                let id = upsert(record)
                if !sessionOrder.contains(id) { sessionOrder.append(id) }
            }
        }
        updateSessionRows()
        if let selectedAgentID, sessions[selectedAgentID] != nil {
            switchSession(selectedAgentID)
        } else if let first = sessionOrder.first {
            switchSession(first)
        } else {
            selectedAgentID = nil
            desiredStageGrid = nil
            workspaceView.stageContainer.subviews.forEach { $0.removeFromSuperview() }
            updateSessionRows()
        }
    }

    private func upsert(_ record: WireSessionRecord) -> UUID {
        let id = idByReference[record.reference] ?? UUID()
        idByReference[record.reference] = id
        let key = SessionKey(deviceID: deviceID, reference: record.reference)
        let size = GridSize(rows: max(1, Int(record.rows)), columns: max(1, Int(record.columns)))
        let lifecycle: SessionLifecycleState = switch record.state {
        case .working, .idle, .blocked: .running
        case .done: .done
        case .unknown: .unknown
        }
        let descriptor = SessionDescriptor(
            id: SessionID(record.reference.rawValue), key: key, name: record.name,
            workingDirectory: record.workingDirectory, provider: record.provider, activity: record.activity,
            state: lifecycle, size: size
        )
        if var current = sessions[id] {
            current.descriptor = descriptor
            sessions[id] = current
        } else {
            sessions[id] = RuntimeSession(descriptor: descriptor)
        }
        return id
    }

    private func enqueueInput(reference: SessionReference, bytes: Data) {
        guard !bytes.isEmpty, bytes.count <= ProtocolV1.maximumInputBytes else { return }
        pendingInputs.append(PendingInput(reference: reference, bytes: bytes))
        guard inputTask == nil else { return }
        inputTask = Task { @MainActor [weak self] in await self?.drainPendingInputs() }
    }

    private func drainPendingInputs() async {
        while !Task.isCancelled, !pendingInputs.isEmpty {
            let input = pendingInputs.removeFirst()
            guard nextInputSequence < UInt32.max else {
                lastConnectionError = "Terminal input sequence exhausted"
                continue
            }
            nextInputSequence += 1
            do {
                let request = try ClientInputRequest(sequence: nextInputSequence, reference: input.reference, payload: .bytes(input.bytes))
                let receipt = try await sessionLink.send(.input(request))
                if !receipt.socketWritten { lastConnectionError = "Terminal input was not sent" }
            } catch {
                lastConnectionError = String(describing: error)
            }
        }
        inputTask = nil
    }

    private func updateSessionRows() {
        sessionRows = sessionOrder.compactMap { id in
            guard let runtime = sessions[id] else { return nil }
            return CorralMVPSessionRow(
                id: id,
                name: runtime.descriptor.name,
                status: runtime.descriptor.activity ?? runtime.descriptor.state.rawValue,
                provider: runtime.descriptor.provider,
                isSelected: id == selectedAgentID
            )
        }
        workspaceView.setSessions(sessionRows)
    }

    public func setTerminalTitle(source: TerminalView, title: String) {}
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public func scrolled(source: TerminalView, position: Double) {}
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    public func bell(source: TerminalView) {}
    public func clipboardCopy(source: TerminalView, content: Data) {}
    public func clipboardRead(source: TerminalView) -> Data? { nil }
    public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !noResizeMode,
              let id = idByTerminalView[ObjectIdentifier(source)],
              let runtime = sessions[id], runtime.subscribed else { return }
        enqueueInput(reference: runtime.descriptor.key.reference, bytes: Data(data))
    }
}

public enum CorralMVPConfiguration {
    public static let defaultEndpoint = "ws://127.0.0.1:9900/ws"

    public static func endpoint(environment: [String: String]) throws -> ApprovedEndpoint {
        let value = environment["CORRAL_NATIVE_ENDPOINT"] ?? defaultEndpoint
        guard let url = URL(string: value) else { throw EndpointSafetyError.invalidEndpoint }
        return try ApprovedEndpoint(url: url)
    }
}
