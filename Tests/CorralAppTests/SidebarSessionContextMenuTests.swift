import AppKit
import ObjectiveC.runtime
import CorralContracts
import CorralProtocol
import CorralServices
import CorralUI
import XCTest
@testable import CorralApp

@MainActor
final class SidebarSessionContextMenuTests: XCTestCase {
    func testFavoriteContextActionPinsSessionAndPlaysFavoriteAnimation() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let sidebar = fixture.coordinator.workspaceView.sidebar
        let target = try XCTUnwrap(sidebar.agents.first { $0.sessionID == fixture.sessionIDs[1] })
        let menu = try XCTUnwrap(sidebar.agentContextMenu(for: target.id))
        XCTAssertTrue(menu.items.contains { $0.title == "收藏" })

        let favoriteItem = try XCTUnwrap(menu.items.first { $0.title == "收藏" })
        SidebarTableMoveProbe.start(watching: sidebar.agentsTable)
        defer { SidebarTableMoveProbe.stop() }
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(favoriteItem.action), to: favoriteItem.target, from: favoriteItem))
        let pinnedToTop = await waitUntil {
            sidebar.agents.first?.id == target.id && sidebar.agents.first?.isFavorite == true
        }
        XCTAssertTrue(pinnedToTop, "Favoriting a session must update its state and move it to the top of the sidebar")

        guard let row = sidebar.agentsTable.rowView(atRow: 0, makeIfNecessary: true) else {
            return XCTFail("The newly favorited session must have a rendered sidebar row")
        }
        XCTAssertTrue(SidebarTableMoveProbe.moves.contains { $0.0 == 1 && $0.1 == 0 },
                      "Pinning a non-top session must animate it to the first row with NSTableView.moveRow")
        XCTAssertTrue(hasFavoriteAnimation(row.layer), "The newly pinned row must play the smooth favorite animation")
    }

    func testCloseContextActionTerminatesTheRemoteAgentSession() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let sidebar = fixture.coordinator.workspaceView.sidebar
        let target = try XCTUnwrap(sidebar.agents.first { $0.sessionID == fixture.sessionIDs[0] })
        let menu = try XCTUnwrap(sidebar.agentContextMenu(for: target.id))
        let menuTitles = menu.items.map(\.title)
        XCTAssertTrue(menuTitles.contains { title in
            let normalized = title.lowercased()
            return normalized.contains("agent-cli") || normalized.contains("agent cli") || normalized.contains("终止")
        }, "The session menu must identify a CLI/session termination action, not a generic view close")

        // Trigger the current generic item too, so this test still checks its actual production action.
        let closeItem = try XCTUnwrap(menu.items.first { ["关闭 Agent CLI", "关闭 agent-cli", "终止会话", "终止 Agent", "关闭"].contains($0.title) })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(closeItem.action), to: closeItem.target, from: closeItem))
        let confirmButton = await waitUntil(timeout: .seconds(2)) {
            self.findSubviews(in: fixture.window.contentView ?? NSView()).compactMap { $0 as? NSButton }
                .first { $0.title == "关闭 Agent" } != nil
        }
        XCTAssertTrue(confirmButton, "Choosing the session termination menu action must ask for confirmation")
        let confirm = findSubviews(in: fixture.window.contentView ?? NSView()).compactMap { $0 as? NSButton }
            .first { $0.title == "关闭 Agent" }
        let dialog = try XCTUnwrap(confirm?.target as? CloseAgentDialogViewController)
        dialog.confirmAction()

        let closeSent = await waitUntil {
            await fixture.link.closedReferences().contains(fixture.references[0])
        }
        XCTAssertTrue(closeSent, "Confirming close must send a close_session request for the target Agent CLI, not close only its pane")
        XCTAssertTrue(fixture.coordinator.workspaceState.visibleRoot?.leafIDs.contains(fixture.sessionIDs[0]) ?? false,
                      "Sending a server termination request must not be confused with merely removing the workspace pane")
    }

    private func makeFixture() async throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("corral-sidebar-menu-\(UUID().uuidString)", isDirectory: true)
        let workspaceStore = try CorralWorkspaceStore(applicationSupportDirectory: root)
        let preferencesStore = try UserPreferencesStore(applicationSupportDirectory: root)
        let deviceID = DeviceID("corral-native-development-endpoint")
        let references = [try SessionReference("sidebar-menu-left"), try SessionReference("sidebar-menu-target")]
        let sessionIDs = references.map { SessionID("\(deviceID.rawValue.utf8.count):\(deviceID.rawValue)\($0.rawValue)") }
        _ = try await workspaceStore.smartOpenSession(sessionIDs[0], gesture: .doubleClick)
        _ = try await workspaceStore.splitSession(sessionIDs[1], target: sessionIDs[0], edge: .right)
        let link = SidebarMenuRecordingSessionLink()
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: SidebarMenuEmptyDeviceRepository(),
            credentialVault: SidebarMenuEmptyCredentialVault(),
            sessionLink: link,
            deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: link),
            workspaceStore: workspaceStore,
            userPreferencesStore: preferencesStore,
            initialWorkspaceState: await workspaceStore.snapshot(),
            initialUserPreferences: await preferencesStore.snapshot(),
            environment: [
                "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
                "CORRAL_NATIVE_TOKEN": "sidebar-menu-fixture-token",
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
            WorkspaceRecord(workingDirectory: "/fixture/sidebar-menu", sessionCount: 2, aggregateState: .idle,
                            sessions: references.map { WireSessionRecord(reference: $0, name: $0.rawValue,
                                workingDirectory: "/fixture/sidebar-menu", state: .idle, rows: 24, columns: 80) })
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

    private func hasFavoriteAnimation(_ layer: CALayer?) -> Bool {
        guard let layer else { return false }
        if layer.animation(forKey: "favorite-pin-highlight") != nil { return true }
        return layer.sublayers?.contains(where: hasFavoriteAnimation) ?? false
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
        let link: SidebarMenuRecordingSessionLink
        let references: [SessionReference]
        let sessionIDs: [SessionID]
        let window: NSWindow
        let temporaryDirectory: URL
    }

    private enum FixtureError: Error { case sessionsDidNotLoad }
}

@MainActor
private enum SidebarTableMoveProbe {
    private final class State: @unchecked Sendable {
        let table: NSTableView
        var moves: [(Int, Int)] = []
        init(table: NSTableView) { self.table = table }
    }

    private static let selector = #selector(NSTableView.moveRow(at:to:))
    private static var originalImplementation: IMP?
    private static var replacementImplementation: IMP?
    private static var state: State?
    static var moves: [(Int, Int)] { state?.moves ?? [] }

    static func start(watching table: NSTableView) {
        let method = class_getInstanceMethod(NSTableView.self, selector)!
        let original = method_getImplementation(method)
        let watched = State(table: table)
        let callOriginal = unsafeBitCast(original, to: (@convention(c) (NSTableView, Selector, Int, Int) -> Void).self)
        let replacement: @convention(block) (NSTableView, Int, Int) -> Void = { table, source, destination in
            if table === watched.table { watched.moves.append((source, destination)) }
            callOriginal(table, selector, source, destination)
        }
        originalImplementation = original
        replacementImplementation = imp_implementationWithBlock(replacement)
        state = watched
        method_setImplementation(method, replacementImplementation!)
    }

    static func stop() {
        guard let originalImplementation, let replacementImplementation,
              let method = class_getInstanceMethod(NSTableView.self, selector) else { return }
        method_setImplementation(method, originalImplementation)
        imp_removeBlock(replacementImplementation)
        self.originalImplementation = nil
        self.replacementImplementation = nil
        state = nil
    }
}

private actor SidebarMenuEmptyDeviceRepository: DeviceRepositoryProtocol {
    func listDevices() async throws -> [DeviceRecord] { [] }
    func save(_ device: DeviceRecord) async throws {}
    func delete(id: DeviceID) async throws {}
}

private actor SidebarMenuEmptyCredentialVault: DeviceCredentialVault {
    func store(_ secret: String, for handle: CredentialHandle) async throws {}
    func resolve(_ handle: CredentialHandle) async throws -> String? { nil }
    func delete(_ handle: CredentialHandle) async throws {}
}

private actor SidebarMenuRecordingSessionLink: SessionLinkProtocol {
    private let stream = SidebarMenuEventStream()
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
        sentCommands.compactMap { if case let .closeSession(request) = $0 { request.reference } else { nil } }
    }
}

private actor SidebarMenuEventStream: SessionEventStream {
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
