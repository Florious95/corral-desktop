import AppKit
import CorralContracts
import CorralProtocol
import CorralServices
import CorralUI
import XCTest
@testable import CorralApp

@MainActor
final class Issue20SidebarContextMenuTests: XCTestCase {
    func testRightClickSessionRowShowsOnlyFavoriteAndRemoteCloseActions() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }

        let target = try XCTUnwrap(fixture.coordinator.workspaceView.sidebar.agents.first {
            $0.sessionID == fixture.sessionIDs[1]
        })
        let menu = try rightClickMenu(for: target.id, in: fixture)
        XCTAssertEqual(menu.title, "Agent", "The row must resolve to the SessionContextMenuBuilder menu")
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["收藏", "关闭 agent-cli"],
                       "A real session-row right click must expose exactly the lifecycle actions")

        let favorite = try XCTUnwrap(menu.items.first { $0.title == "收藏" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(favorite.action), to: favorite.target, from: favorite))
        let pinned = await waitUntil {
            let agents = fixture.coordinator.workspaceView.sidebar.agents
            return agents.first?.id == target.id && agents.first?.isFavorite == true
        }
        XCTAssertTrue(pinned, "The favorite menu action must update state and pin the session at the top")

        let updatedMenu = try rightClickMenu(for: target.id, in: fixture)
        XCTAssertEqual(updatedMenu.items.filter { !$0.isSeparatorItem }.map(\.title), ["取消收藏", "关闭 agent-cli"])
    }

    func testRightClickCloseActionSendsCloseSessionForTheTargetReference() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }

        let target = try XCTUnwrap(fixture.coordinator.workspaceView.sidebar.agents.first {
            $0.sessionID == fixture.sessionIDs[1]
        })
        let menu = try rightClickMenu(for: target.id, in: fixture)
        let close = try XCTUnwrap(menu.items.first { $0.title == "关闭 agent-cli" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(close.action), to: close.target, from: close))

        let confirmationPresented = await waitUntil(timeout: .seconds(2)) {
            self.findSubviews(in: fixture.window.contentView ?? NSView()).compactMap { $0 as? NSButton }
                .contains { $0.title == "关闭 Agent" }
        }
        XCTAssertTrue(confirmationPresented, "The remote agent termination action must reach its confirmation flow")
        let confirm = findSubviews(in: fixture.window.contentView ?? NSView()).compactMap { $0 as? NSButton }
            .first { $0.title == "关闭 Agent" }
        try XCTUnwrap(confirm?.target as? CloseAgentDialogViewController).confirmAction()

        let closeSent = await waitUntil {
            await fixture.link.closedReferences().contains(fixture.references[1])
        }
        XCTAssertTrue(closeSent, "Confirming the row action must send close_session for that row's SessionReference")
    }

    private func rightClickMenu(for agentID: UUID, in fixture: Fixture) throws -> NSMenu {
        let sidebar = fixture.coordinator.workspaceView.sidebar
        let table = sidebar.agentsTable
        let row = try XCTUnwrap(sidebar.agents.firstIndex { $0.id == agentID })
        table.layoutSubtreeIfNeeded()
        XCTAssertNotNil(table.rowView(atRow: row, makeIfNecessary: true), "The target must be a rendered table row")

        let rowRect = table.rect(ofRow: row)
        let eventLocation = table.convert(NSPoint(x: rowRect.midX, y: rowRect.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: eventLocation,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            eventNumber: 20,
            clickCount: 1,
            pressure: 1
        ))
        XCTAssertEqual(table.row(at: table.convert(event.locationInWindow, from: nil)), row,
                       "The synthesized right-click must target the requested session row")
        let hit = fixture.window.contentView?.hitTest(event.locationInWindow)
        XCTAssertTrue(hit === table || hit?.isDescendant(of: table) == true,
                      "The actual window-coordinate event must hit the sidebar table row")
        return try XCTUnwrap(table.menu(for: event), "NSTableView must resolve the right-click to its session context menu")
    }

    private func makeFixture() async throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "corral-issue20-sidebar-menu-\(UUID().uuidString)", isDirectory: true
        )
        let workspaceStore = try CorralWorkspaceStore(applicationSupportDirectory: root)
        let preferencesStore = try UserPreferencesStore(applicationSupportDirectory: root)
        let deviceID = DeviceID("corral-native-development-endpoint")
        let references = [try SessionReference("issue20-left"), try SessionReference("issue20-target")]
        let sessionIDs = references.map { SessionID("\(deviceID.rawValue.utf8.count):\(deviceID.rawValue)\($0.rawValue)") }
        _ = try await workspaceStore.smartOpenSession(sessionIDs[0], gesture: .doubleClick)
        _ = try await workspaceStore.splitSession(sessionIDs[1], target: sessionIDs[0], edge: .right)
        let link = Issue20RecordingSessionLink()
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: Issue20EmptyDeviceRepository(),
            credentialVault: Issue20EmptyCredentialVault(),
            sessionLink: link,
            deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: link),
            workspaceStore: workspaceStore,
            userPreferencesStore: preferencesStore,
            initialWorkspaceState: await workspaceStore.snapshot(),
            initialUserPreferences: await preferencesStore.snapshot(),
            environment: [
                "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
                "CORRAL_NATIVE_TOKEN": "issue20-fixture-token",
                "CORRAL_NATIVE_BACKGROUND": "1",
                "CORRAL_NATIVE_TEST_MODE": "1"
            ]
        )
        let window = try XCTUnwrap(coordinator.windowController.window)
        window.orderBack(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        await coordinator.start()
        try await link.emit(.control(.listing(SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(workingDirectory: "/fixture/issue20", sessionCount: 2, aggregateState: .idle,
                            sessions: references.map {
                WireSessionRecord(reference: $0, name: $0.rawValue, workingDirectory: "/fixture/issue20",
                                  state: .idle, rows: 24, columns: 80)
            })
        ]))))
        let ready = await waitUntil(timeout: .seconds(3)) {
            coordinator.workspaceView.sidebar.agents.count == 2
                && coordinator.subscribedSessionIDs.count == 2
                && coordinator.workspaceView.stageContainer.splitView.projection.panes.count == 2
        }
        guard ready else {
            await coordinator.stop()
            window.close()
            try? FileManager.default.removeItem(at: root)
            throw FixtureError.sessionsDidNotLoad
        }
        return Fixture(coordinator: coordinator, link: link, references: references,
                       sessionIDs: sessionIDs, window: window, temporaryDirectory: root)
    }

    private func cleanup(_ fixture: Fixture) {
        fixture.coordinator.windowController.window?.close()
        Task { await fixture.coordinator.stop() }
        try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
    }

    private func findSubviews(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(findSubviews)
    }

    private func waitUntil(timeout: Duration = .seconds(3), condition: @escaping @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    private struct Fixture {
        let coordinator: CorralApplicationCoordinator
        let link: Issue20RecordingSessionLink
        let references: [SessionReference]
        let sessionIDs: [SessionID]
        let window: NSWindow
        let temporaryDirectory: URL
    }

    private enum FixtureError: Error { case sessionsDidNotLoad }
}

private actor Issue20EmptyDeviceRepository: DeviceRepositoryProtocol {
    func listDevices() async throws -> [DeviceRecord] { [] }
    func save(_ device: DeviceRecord) async throws {}
    func delete(id: DeviceID) async throws {}
}

private actor Issue20EmptyCredentialVault: DeviceCredentialVault {
    func store(_ secret: String, for handle: CredentialHandle) async throws {}
    func resolve(_ handle: CredentialHandle) async throws -> String? { nil }
    func delete(_ handle: CredentialHandle) async throws {}
}

private actor Issue20RecordingSessionLink: SessionLinkProtocol {
    private let stream = Issue20EventStream()
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
        let requestID: UInt32? = switch command {
        case let .list(id): id
        case let .createAgent(request): request.requestID
        case let .closeSession(request): request.requestID
        default: nil
        }
        if case let .subscribe(reference, _) = command {
            try await emit(.frame(.snapshot(reference: reference, ansi: Data())))
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
        let origin = SessionEventOrigin(linkInstanceID: authenticated.linkInstanceID,
                                        deviceID: authenticated.deviceID,
                                        connectionEpoch: authenticated.connectionEpoch,
                                        receiveOrdinal: ReceiveOrdinal(ordinal))
        try await stream.yield(SessionEventEnvelope(origin: origin, wireByteCount: 0, event: event))
    }

    func closedReferences() -> [SessionReference] {
        sentCommands.compactMap {
            if case let .closeSession(request) = $0 { request.reference } else { nil }
        }
    }
}

private actor Issue20EventStream: SessionEventStream {
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
