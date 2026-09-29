import AppKit
import CorralContracts
import CorralProtocol
import CorralServices
import CorralUI
import Foundation
import XCTest
@testable import CorralApp

@MainActor
final class Issue14TabFolderTrackingTests: XCTestCase {
    func testSwitchingTabSelectsItsSpaceAndFiltersSessionsToThatSpace() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-issue14-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let link = Issue14SessionLink()
        let repository = try DeviceRepository(applicationSupportDirectory: root.appendingPathComponent("devices"))
        let vault = Issue14CredentialVault()
        let workspaceStore = try CorralWorkspaceStore(applicationSupportDirectory: root.appendingPathComponent("workspace"))
        let preferencesStore = try UserPreferencesStore(applicationSupportDirectory: root.appendingPathComponent("preferences"))
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: repository,
            credentialVault: vault,
            sessionLink: link,
            deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: link),
            workspaceStore: workspaceStore,
            userPreferencesStore: preferencesStore,
            initialWorkspaceState: await workspaceStore.snapshot(),
            initialUserPreferences: await preferencesStore.snapshot(),
            environment: [
                "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
                "CORRAL_NATIVE_TOKEN": "issue14-fixture-only",
                "CORRAL_NATIVE_BACKGROUND": "1"
            ]
        )
        let window = try XCTUnwrap(coordinator.windowController.window)
        window.orderBack(nil)
        defer { window.close() }
        await coordinator.start()
        XCTAssertTrue(coordinator.connected, "The isolated fixture link must connect without dialing a real endpoint")

        let deviceID = DeviceID("corral-native-development-endpoint")
        let references = try (1...4).map { try SessionReference("issue14-session-\($0)") }
        let sessionsA = [
            WireSessionRecord(reference: references[0], name: "A-session-1", workingDirectory: "/fixture/space-a", state: .idle, rows: 24, columns: 80),
            WireSessionRecord(reference: references[1], name: "A-session-2", workingDirectory: "/fixture/space-a", state: .idle, rows: 24, columns: 80)
        ]
        let sessionsB = [
            WireSessionRecord(reference: references[2], name: "B-session-1", workingDirectory: "/fixture/space-b", state: .idle, rows: 24, columns: 80),
            WireSessionRecord(reference: references[3], name: "B-session-2", workingDirectory: "/fixture/space-b", state: .idle, rows: 24, columns: 80)
        ]
        try await link.emit(.control(.listing(SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(workingDirectory: "/fixture/space-a", sessionCount: 2, aggregateState: .idle, sessions: sessionsA),
            WorkspaceRecord(workingDirectory: "/fixture/space-b", sessionCount: 2, aggregateState: .idle, sessions: sessionsB)
        ]))))
        let sidebar = coordinator.workspaceView.sidebar
        let listed = await waitUntil {
            coordinator.sessionCount == 4 && sidebar.spaces.contains { $0.name == "space-a" } && sidebar.spaces.contains { $0.name == "space-b" }
        }
        XCTAssertTrue(listed, "Both fixture folders must be registered before opening their Tabs")

        let sessionA1 = SessionID("\(deviceID.rawValue.utf8.count):\(deviceID.rawValue)\(references[0].rawValue)")
        let sessionB1 = SessionID("\(deviceID.rawValue.utf8.count):\(deviceID.rawValue)\(references[2].rawValue)")
        let expectedBIDs = Set([
            sessionB1,
            SessionID("\(deviceID.rawValue.utf8.count):\(deviceID.rawValue)\(references[3].rawValue)")
        ])
        let spaceB = try XCTUnwrap(sidebar.spaces.first { $0.name == "space-b" })
        let tabAID = coordinator.workspaceState.activeTabID
        XCTAssertEqual(coordinator.workspaceState.activeTab?.activeSessionID, sessionA1, "Tab A must initially represent the first Space A session")

        await coordinator.openSession(SessionKey(deviceID: deviceID, reference: references[2]), gesture: .doubleClick)
        let openedTabB = await waitUntil {
            coordinator.workspaceState.tabs.count == 2 && coordinator.workspaceState.activeTab?.activeSessionID == sessionB1
        }
        XCTAssertTrue(openedTabB, "Opening the Space B session must create its own active Tab")
        let tabBID = coordinator.workspaceState.activeTabID

        await coordinator.selectWorkspaceTab(id: tabAID)
        XCTAssertEqual(coordinator.workspaceState.visibleSessionID, sessionA1)
        await coordinator.selectWorkspaceTab(id: tabBID)
        XCTAssertEqual(coordinator.workspaceState.visibleSessionID, sessionB1)

        XCTAssertEqual(sidebar.selectedSpaceID, spaceB.id, "Switching to a Space B Tab must select Space B in the sidebar")
        XCTAssertEqual(sidebar.agents.count, 2, "The visible sidebar rows must contain exactly Space B's sessions")
        XCTAssertEqual(Set(sidebar.agents.compactMap(\.sessionID)), expectedBIDs, "Space A sessions must not leak into the Space B session list")
        XCTAssertEqual(sidebar.agents.map(\.name).sorted(), ["B-session-1", "B-session-2"])
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

private actor Issue14CredentialVault: DeviceCredentialVault {
    func store(_ secret: String, for handle: CredentialHandle) async throws {}
    func resolve(_ handle: CredentialHandle) async throws -> String? { nil }
    func delete(_ handle: CredentialHandle) async throws {}
}

private actor Issue14SessionLink: SessionLinkProtocol {
    private let stream = Issue14EventStream()
    private var authenticated: AuthenticatedConnection?
    private var ordinal: UInt64 = 0

    func connect(to endpoint: ApprovedEndpoint, deviceID: DeviceID, credential: CredentialHandle) async throws -> AuthenticatedConnection {
        let connection = try AuthenticatedConnection(linkInstanceID: LinkInstanceID(), deviceID: deviceID, connectionEpoch: ConnectionEpoch(1))
        authenticated = connection
        return connection
    }

    func eventStream() async throws -> any SessionEventStream { stream }

    func send(_ command: ClientCommand) async throws -> CommandSendReceipt {
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
}

private actor Issue14EventStream: SessionEventStream {
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
