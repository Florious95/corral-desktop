import AppKit
import CorralContracts
import CorralMetalTerminal
import CorralProtocol
import CorralUI
import Foundation

@MainActor
public final class CorralMVPCoordinator {
    public let window: NSWindow
    public let workspaceView: CorralMVPWorkspaceView
    let stageView: MetalStageView

    public private(set) var selectedAgentID: UUID?
    public private(set) var connected = false
    public private(set) var lastConnectionError: String?
    public private(set) var sessionRows: [CorralMVPSessionRow] = []

    private struct RuntimeSession {
        var descriptor: SessionDescriptor
        let id: UUID
        let paneID: UUID
        let engine: SwiftTermEngineAdapter
        var subscribed = false
        var subscriptionPending = false
        var receivedFrame = false
        var snapshot: TerminalGridSnapshot?
        var lastResizeGrid: GridSize?
        var resizePendingGrid: GridSize?
    }

    private struct ResizeRequest {
        let sessionID: UUID
        let grid: GridSize
        let generation: UInt64
    }

    private let sessionLink: any SessionLinkProtocol
    private let endpoint: ApprovedEndpoint?
    private let credential: CredentialHandle?
    private let deviceID = DeviceID("corral-native-mvp")
    private let inputRouter: SessionLinkInputRouter
    private let effectSink = LocalTerminalEffectPolicySink()
    private var connection: AuthenticatedConnection?
    private var eventTask: Task<Void, Never>?
    private var sessions: [UUID: RuntimeSession] = [:]
    private var idByReference: [SessionReference: UUID] = [:]
    private var sessionOrder: [UUID] = []
    private var listingSequence: UInt64 = 0
    private var nextRequestID: UInt32 = 0
    private var listingRequestedEpoch: ConnectionEpoch?
    private(set) var desiredStageGrid: GridSize?
    private var resizeRequestGeneration: UInt64 = 0
    private var pendingResize: ResizeRequest?
    private var resizeTask: Task<Void, Never>?
    public private(set) var selectionGeneration: UInt64 = 0

    public init(
        sessionLink: any SessionLinkProtocol,
        renderer: SharedMetalTerminalRenderer,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workspaceView: CorralMVPWorkspaceView = CorralMVPWorkspaceView(frame: .zero)
    ) {
        self.sessionLink = sessionLink
        self.workspaceView = workspaceView
        self.stageView = MetalStageView(renderer: renderer, stageID: UUID())
        self.inputRouter = SessionLinkInputRouter(sessionLink: sessionLink)

        self.endpoint = try? CorralMVPConfiguration.endpoint(environment: environment)
        self.credential = environment["CORRAL_NATIVE_TOKEN"].flatMap { $0.isEmpty ? nil : CredentialHandle($0) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Corral Native"
        window.contentView = workspaceView
        self.window = window
        workspaceView.attachStageView(stageView)
        workspaceView.onSelectAgent = { [weak self] id in self?.switchSession(id) }
        stageView.onGeometryChanged = { [weak self] size, _ in
            self?.stageGeometryChanged(size)
        }
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
        pendingResize = nil
        await sessionLink.disconnect()
        connection = nil
        connected = false
    }

    /// Changes only the permanent Stage's presentation pointer; cached sessions stay subscribed and parsed.
    public func switchSession(_ id: UUID) {
        guard let runtime = sessions[id] else { return }
        if let previousID = selectedAgentID, previousID != id {
            resizeRequestGeneration &+= 1
            pendingResize = nil
            if var previous = sessions[previousID] {
                previous.resizePendingGrid = nil
                sessions[previousID] = previous
            }
        }
        selectionGeneration &+= 1
        selectedAgentID = id
        updateSessionRows()
        stageView.activateInput(for: runtime.descriptor.key, using: inputRouter)
        if runtime.receivedFrame, let snapshot = runtime.snapshot {
            stageView.present(submission(for: runtime, snapshot: snapshot))
        } else {
            stageView.present(nil)
            if !runtime.subscribed && !runtime.subscriptionPending {
                Task { @MainActor [weak self] in await self?.subscribe(id) }
            }
        }
        scheduleResize(for: id)
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
        case let .frame(frame): await applyFrame(frame, origin: envelope.origin)
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

    private func stageGeometryChanged(_ size: NSSize) {
        desiredStageGrid = Self.proposedGrid(for: size, cellSize: stageView.terminalCellSize)
        if let selectedAgentID, let runtime = sessions[selectedAgentID],
           runtime.receivedFrame, let snapshot = runtime.snapshot {
            stageView.present(submission(for: runtime, snapshot: snapshot))
        }
        if let selectedAgentID { scheduleResize(for: selectedAgentID) }
    }

    static func proposedGrid(for viewport: NSSize, cellSize: NSSize) -> GridSize? {
        guard viewport.width.isFinite, viewport.height.isFinite,
              cellSize.width.isFinite, cellSize.height.isFinite,
              viewport.width > 12, viewport.height > 8,
              cellSize.width > 0, cellSize.height > 0 else { return nil }
        let rawColumns = Double(viewport.width - 12) / Double(cellSize.width)
        let rawRows = Double(viewport.height - 8) / Double(cellSize.height)
        guard rawColumns.isFinite, rawRows.isFinite else { return nil }
        let columns = min(Int(UInt16.max), max(1, Int(min(rawColumns, Double(UInt16.max)))))
        var rows = min(Int(UInt16.max), max(1, Int(min(rawRows, Double(UInt16.max)))))
        while rows > 1_000_000 / columns { rows -= 1 }
        return GridSize(rows: rows, columns: columns)
    }

    private func scheduleResize(for id: UUID) {
        guard selectedAgentID == id, let grid = desiredStageGrid,
              var runtime = sessions[id], runtime.subscribed else { return }
        guard runtime.descriptor.size != grid, runtime.lastResizeGrid != grid,
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
        let id = request.sessionID
        guard let runtime = sessions[id], runtime.subscribed else {
            clearPendingResize(request)
            return
        }
        let previousGrid = runtime.descriptor.size
        guard isCurrentResize(request) else {
            clearPendingResize(request)
            return
        }

        do {
            try await runtime.engine.resize(to: request.grid)
            let resizedSnapshot = await runtime.engine.snapshot()
            guard resizedSnapshot.isValid, var current = sessions[id] else { return }
            current.snapshot = resizedSnapshot
            sessions[id] = current
            if current.receivedFrame, selectedAgentID == id {
                stageView.present(submission(for: current, snapshot: resizedSnapshot))
            }
            guard isCurrentResize(request) else {
                let restoreTo = selectedAgentID == id ? (desiredStageGrid ?? previousGrid) : previousGrid
                await restoreGrid(id, restoreTo, pending: request.grid)
                return
            }

            let receipt = try await sessionLink.send(.resize(reference: runtime.descriptor.key.reference, size: request.grid))
            guard receipt.socketWritten else {
                await restoreGrid(id, previousGrid, pending: request.grid)
                lastConnectionError = "Terminal resize was not sent"
                return
            }
            guard var latest = sessions[id] else { return }
            latest.descriptor.size = request.grid
            latest.lastResizeGrid = request.grid
            if latest.resizePendingGrid == request.grid { latest.resizePendingGrid = nil }
            latest.snapshot = await latest.engine.snapshot()
            sessions[id] = latest
            if latest.receivedFrame, selectedAgentID == id, let snapshot = latest.snapshot {
                stageView.present(submission(for: latest, snapshot: snapshot))
            }
        } catch {
            await restoreGrid(id, previousGrid, pending: request.grid)
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

    private func restoreGrid(_ id: UUID, _ grid: GridSize, pending: GridSize) async {
        guard let runtime = sessions[id] else { return }
        try? await runtime.engine.resize(to: grid)
        let snapshot = await runtime.engine.snapshot()
        guard var current = sessions[id] else { return }
        current.snapshot = snapshot
        if current.resizePendingGrid == pending { current.resizePendingGrid = nil }
        sessions[id] = current
        if current.receivedFrame, selectedAgentID == id {
            stageView.present(submission(for: current, snapshot: snapshot))
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
            if let reference = sessions.removeValue(forKey: id)?.descriptor.key.reference {
                idByReference.removeValue(forKey: reference)
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
            stageView.activateInput(for: nil, using: inputRouter)
            stageView.present(nil)
        }
    }

    private func applyListDelta(_ delta: SessionListDelta) {
        guard delta.isValid, delta.sequence > listingSequence else { return }
        listingSequence = delta.sequence
        for reference in delta.removedReferences {
            guard let id = idByReference.removeValue(forKey: reference) else { continue }
            sessions.removeValue(forKey: id)
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
            if let runtime = sessions[selectedAgentID], let snapshot = runtime.snapshot {
                stageView.present(submission(for: runtime, snapshot: snapshot))
            }
        } else if let first = sessionOrder.first {
            switchSession(first)
        } else {
            selectedAgentID = nil
            stageView.activateInput(for: nil, using: inputRouter)
            stageView.present(nil)
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
            sessions[id] = RuntimeSession(
                descriptor: descriptor, id: id, paneID: UUID(), engine: SwiftTermEngineAdapter(size: size)
            )
        }
        return id
    }

    private func subscribe(_ id: UUID) async {
        guard var runtime = sessions[id], !runtime.subscribed, !runtime.subscriptionPending else { return }
        runtime.subscriptionPending = true
        sessions[id] = runtime
        do {
            let receipt = try await sessionLink.send(.subscribe(reference: runtime.descriptor.key.reference, size: runtime.descriptor.size))
            guard var current = sessions[id] else { return }
            current.subscriptionPending = false
            current.subscribed = receipt.socketWritten
            sessions[id] = current
            if receipt.socketWritten {
                scheduleResize(for: id)
            } else {
                lastConnectionError = "Subscription was not sent"
            }
        } catch {
            sessions[id]?.subscriptionPending = false
            lastConnectionError = String(describing: error)
        }
    }

    private func applyFrame(_ frame: BinaryFrame, origin: SessionEventOrigin) async {
        let selectionAtStart = selectionGeneration
        let reference = frame.reference
        guard let id = idByReference[reference], let runtime = sessions[id],
              runtime.subscribed || runtime.subscriptionPending else { return }
        let update: TerminalUpdate
        switch frame {
        case let .snapshot(reference, ansi): update = .snapshot(reference: reference, ansi: ansi, origin: origin)
        case let .delta(reference, ansi): update = .delta(reference: reference, ansi: ansi, origin: origin)
        case let .scrollback(reference, metadata, ansi): update = .scrollback(reference: reference, metadata: metadata, ansi: ansi, origin: origin)
        }
        do {
            let effects = try await runtime.engine.apply(update)
            await effectSink.consume(effects, for: runtime.descriptor.key)
            let snapshot = await runtime.engine.snapshot()
            guard snapshot.isValid, var current = sessions[id] else { return }
            current.receivedFrame = true
            current.snapshot = snapshot
            sessions[id] = current
            if let selectedAgentID, let selected = sessions[selectedAgentID],
               (selectedAgentID == id || selectionGeneration != selectionAtStart),
               let selectedSnapshot = selected.snapshot {
                stageView.present(submission(for: selected, snapshot: selectedSnapshot))
            }
        } catch {
            lastConnectionError = String(describing: error)
        }
    }

    private func submission(for runtime: RuntimeSession, snapshot: TerminalGridSnapshot) -> PaneRenderSubmission {
        let size = stageView.currentGeometry?.0 ?? stageView.bounds.size
        let viewport = StageViewportRect(x: 0, y: 0, width: Double(max(1, size.width)), height: Double(max(1, size.height)))
        return PaneRenderSubmission(paneID: runtime.paneID, session: runtime.descriptor.key, viewport: viewport, snapshot: snapshot)
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
}

public enum CorralMVPConfiguration {
    public static let defaultEndpoint = "ws://127.0.0.1:9900/ws"

    public static func endpoint(environment: [String: String]) throws -> ApprovedEndpoint {
        let value = environment["CORRAL_NATIVE_ENDPOINT"] ?? defaultEndpoint
        guard let url = URL(string: value) else { throw EndpointSafetyError.invalidEndpoint }
        return try ApprovedEndpoint(url: url)
    }
}
