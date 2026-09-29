import AppKit
import CorralContracts
import CorralProtocol
import CorralServices
import CorralUI
import Foundation
import XCTest
@testable import CorralApp
@testable import SwiftTerm

@MainActor
final class Issue16MultiTabReflowSyncTests: XCTestCase {
    func testWindowResizeReflowsInactiveTabWhenItBecomesActive() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-issue16-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let support = root.appendingPathComponent("workspace", isDirectory: true)
        let store = try CorralWorkspaceStore(applicationSupportDirectory: support)
        let preferences = try UserPreferencesStore(applicationSupportDirectory: support)
        let deviceID = DeviceID("corral-native-development-endpoint")
        let references = try (0..<4).map { try SessionReference("issue16-session-\($0)") }
        let sessionIDs = references.map { SessionID("\(deviceID.rawValue.utf8.count):\(deviceID.rawValue)\($0.rawValue)") }

        let tabAState = try await store.smartOpenSession(sessionIDs[0], gesture: .doubleClick)
        let tabAID = tabAState.activeTabID
        _ = try await store.splitSession(sessionIDs[1], target: sessionIDs[0], edge: .right)
        let tabBID = try await store.createTab()
        _ = try await store.smartOpenSession(sessionIDs[2], gesture: .doubleClick)
        _ = try await store.splitSession(sessionIDs[3], target: sessionIDs[2], edge: .right)
        _ = try await store.switchTab(tabAID)

        let link = Issue16RecordingSessionLink()
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: Issue16EmptyDeviceRepository(),
            credentialVault: Issue16EmptyCredentialVault(),
            sessionLink: link,
            deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: link),
            workspaceStore: store,
            userPreferencesStore: preferences,
            initialWorkspaceState: await store.snapshot(),
            initialUserPreferences: await preferences.snapshot(),
            environment: [
                "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
                "CORRAL_NATIVE_TOKEN": "issue16-test-only",
                "CORRAL_NATIVE_BACKGROUND": "1"
            ]
        )
        let window = try XCTUnwrap(coordinator.windowController.window)
        defer { window.close() }
        var initialWindowFrame = window.frame
        initialWindowFrame.size = NSSize(width: 1_000, height: 720)
        window.setFrame(initialWindowFrame, display: true, animate: false)
        window.orderBack(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        coordinator.workspaceView.layoutSubtreeIfNeeded()
        coordinator.workspaceView.stageContainer.layoutSubtreeIfNeeded()

        await coordinator.start()
        try await link.emit(.control(.listing(SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(
                workingDirectory: "/fixture/issue16",
                sessionCount: 4,
                aggregateState: .idle,
                sessions: references.enumerated().map { index, reference in
                    WireSessionRecord(
                        reference: reference,
                        name: "Tab \(index < 2 ? "A" : "B") pane \(index % 2 + 1)",
                        workingDirectory: "/fixture/issue16",
                        state: .idle,
                        rows: 24,
                        columns: 80
                    )
                }
            )
        ]))))

        let tabAReady = await waitUntil {
            coordinator.workspaceState.activeTabID == tabAID &&
                coordinator.workspaceState.visibleSessionID == sessionIDs[1] &&
                coordinator.subscribedSessionIDs.contains(references[0].rawValue) &&
                coordinator.subscribedSessionIDs.contains(references[1].rawValue) &&
                coordinator.terminalView(for: references[0])?.terminal.cols ?? 0 > 0 &&
                coordinator.terminalView(for: references[1])?.terminal.cols ?? 0 > 0
        }
        XCTAssertTrue(tabAReady, "Tab A must be active and sized at the initial window width")

        await coordinator.selectWorkspaceTab(id: tabBID)
        let tabBReady = await waitUntil {
            coordinator.workspaceState.activeTabID == tabBID &&
                coordinator.workspaceState.visibleSessionID == sessionIDs[3] &&
                coordinator.subscribedSessionIDs.contains(references[2].rawValue) &&
                coordinator.subscribedSessionIDs.contains(references[3].rawValue) &&
                coordinator.terminalView(for: references[2])?.terminal.cols ?? 0 > 0 &&
                coordinator.terminalView(for: references[3])?.terminal.cols ?? 0 > 0
        }
        XCTAssertTrue(tabBReady, "Tab B must be opened once at the initial window width")
        let viewA = try XCTUnwrap(coordinator.terminalView(for: references[0]))
        let viewA2 = try XCTUnwrap(coordinator.terminalView(for: references[1]))
        let viewB = try XCTUnwrap(coordinator.terminalView(for: references[2]))
        let viewB2 = try XCTUnwrap(coordinator.terminalView(for: references[3]))
        let initialAFrame = viewA.frame
        let initialA2Frame = viewA2.frame
        let initialBFrame = viewB.frame
        let initialB2Frame = viewB2.frame
        let initialAGrid = GridSize(rows: viewA.terminal.rows, columns: viewA.terminal.cols)
        let initialA2Grid = GridSize(rows: viewA2.terminal.rows, columns: viewA2.terminal.cols)
        let initialBGrid = GridSize(rows: viewB.terminal.rows, columns: viewB.terminal.cols)
        let initialB2Grid = GridSize(rows: viewB2.terminal.rows, columns: viewB2.terminal.cols)

        await coordinator.selectWorkspaceTab(id: tabAID)
        XCTAssertEqual(coordinator.workspaceState.visibleSessionID, sessionIDs[1])
        let stageWidthBeforeResize = coordinator.workspaceView.stageContainer.bounds.width
        var resizedWindowFrame = window.frame
        resizedWindowFrame.size.width = 1_200
        window.setFrame(resizedWindowFrame, display: true, animate: false)
        window.displayIfNeeded()
        let tabAResized = await waitUntil {
            coordinator.workspaceView.stageContainer.bounds.width > stageWidthBeforeResize + 100 &&
                viewA.frame.width > initialAFrame.width + 50 &&
                viewA2.frame.width > initialA2Frame.width + 50 &&
                viewA.terminal.cols > initialAGrid.columns &&
                viewA2.terminal.cols > initialA2Grid.columns
        }
        XCTAssertTrue(tabAResized, "Resizing the active window must reflow Tab A's viewport and terminal grid")

        let aGridAfterResize = GridSize(rows: viewA.terminal.rows, columns: viewA.terminal.cols)
        XCTAssertNotEqual(aGridAfterResize, initialAGrid)
        XCTAssertNotEqual(GridSize(rows: viewA2.terminal.rows, columns: viewA2.terminal.cols), initialA2Grid)
        XCTAssertEqual(viewA.frame.width, viewA2.frame.width, accuracy: 1)
        let commandsBeforeTabBSwitch = await link.commands()

        await coordinator.selectWorkspaceTab(id: tabBID)
        let tabBReflowed = await waitUntil {
            coordinator.workspaceState.activeTabID == tabBID &&
                coordinator.workspaceState.visibleSessionID == sessionIDs[3] &&
                abs(viewB.frame.width - viewA.frame.width) <= 1 &&
                abs(viewB.frame.height - viewA.frame.height) <= 1 &&
                abs(viewB2.frame.width - viewA2.frame.width) <= 1 &&
                abs(viewB2.frame.height - viewA2.frame.height) <= 1
        }
        XCTAssertTrue(tabBReflowed, "Tab B's viewport must reflow to the current window dimensions, not its historical frame")

        let currentBGrid = GridSize(rows: viewB.terminal.rows, columns: viewB.terminal.cols)
        let currentB2Grid = GridSize(rows: viewB2.terminal.rows, columns: viewB2.terminal.cols)
        XCTAssertNotEqual(viewB.frame.size, initialBFrame.size, "Tab B's viewport must not retain its historical size")
        XCTAssertNotEqual(viewB2.frame.size, initialB2Frame.size, "Tab B's other pane must not retain its historical size")
        XCTAssertNotEqual(currentBGrid, initialBGrid, "Tab B's PTY grid must change with the resized window")
        XCTAssertNotEqual(currentB2Grid, initialB2Grid)
        let tabBResizeSent = await waitUntil {
            let commands = await link.commands()
            let commandsAfterSwitch = commands.dropFirst(min(commandsBeforeTabBSwitch.count, commands.count))
            let b1 = commandsAfterSwitch.contains { command in
                if case .resize(reference: references[2], size: currentBGrid) = command { true } else { false }
            }
            let b2 = commandsAfterSwitch.contains { command in
                if case .resize(reference: references[3], size: currentB2Grid) = command { true } else { false }
            }
            return b1 && b2
        }
        XCTAssertTrue(tabBResizeSent, "Tab B activation must explicitly send new PTY resize control frames for both pane grids")
        await coordinator.stop()
    }

    private func waitUntil(timeout: Duration = .seconds(8), _ predicate: @MainActor () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await predicate()
    }
}

private actor Issue16EmptyDeviceRepository: DeviceRepositoryProtocol {
    func listDevices() async throws -> [DeviceRecord] { [] }
    func save(_ device: DeviceRecord) async throws {}
    func delete(id: DeviceID) async throws {}
}

private actor Issue16EmptyCredentialVault: DeviceCredentialVault {
    func store(_ secret: String, for handle: CredentialHandle) async throws {}
    func resolve(_ handle: CredentialHandle) async throws -> String? { nil }
    func delete(_ handle: CredentialHandle) async throws {}
}

private actor Issue16RecordingSessionLink: SessionLinkProtocol {
    private let stream = Issue16EventStream()
    private var authenticated: AuthenticatedConnection?
    private var ordinal: UInt64 = 0
    private var sentCommands: [ClientCommand] = []

    func connect(to endpoint: ApprovedEndpoint, deviceID: DeviceID, credential: CredentialHandle) async throws -> AuthenticatedConnection {
        let connection = try AuthenticatedConnection(linkInstanceID: LinkInstanceID(), deviceID: deviceID,
                                                     connectionEpoch: ConnectionEpoch(1))
        authenticated = connection
        return connection
    }

    func eventStream() async throws -> any SessionEventStream { stream }

    func send(_ command: ClientCommand) async throws -> CommandSendReceipt {
        sentCommands.append(command)
        if case let .subscribe(reference, _) = command {
            try await emit(.frame(.snapshot(reference: reference, ansi: Data())))
        }
        let requestID: UInt32? = switch command {
        case let .list(id): id
        case let .input(request): request.sequence
        case let .createAgent(request): request.requestID
        case let .closeSession(request): request.requestID
        default: nil
        }
        return CommandSendReceipt(requestID: requestID, socketWritten: true)
    }

    func disconnect() async {
        authenticated = nil
        await stream.finish()
    }

    func emit(_ event: SessionEvent) async throws {
        guard let authenticated else { throw SessionLinkFailure.disconnected }
        ordinal += 1
        let origin = SessionEventOrigin(linkInstanceID: authenticated.linkInstanceID, deviceID: authenticated.deviceID,
                                        connectionEpoch: authenticated.connectionEpoch, receiveOrdinal: ReceiveOrdinal(ordinal))
        try await stream.yield(SessionEventEnvelope(origin: origin, wireByteCount: 0, event: event))
    }

    func commands() -> [ClientCommand] { sentCommands }
}

private actor Issue16EventStream: SessionEventStream {
    private var queued: [SessionEventEnvelope] = []
    private var waiter: CheckedContinuation<SessionEventEnvelope?, Never>?
    private var finished = false

    var budget: SessionEventStreamBudget {
        SessionEventStreamBudget(maximumBufferedBytes: 1_000_000, maximumBufferedEvents: 128, maximumBufferedControls: 32)
    }

    func next() async throws -> SessionEventEnvelope? {
        if !queued.isEmpty { return queued.removeFirst() }
        if finished { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }

    func yield(_ envelope: SessionEventEnvelope) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: envelope)
        } else {
            queued.append(envelope)
        }
    }

    func finish() {
        finished = true
        waiter?.resume(returning: nil)
        waiter = nil
    }
}