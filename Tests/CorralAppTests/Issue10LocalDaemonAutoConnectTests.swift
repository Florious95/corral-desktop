import AppKit
import CorralContracts
import CorralProtocol
import CorralServices
import Foundation
import XCTest
@testable import CorralApp

@MainActor
final class Issue10LocalDaemonAutoConnectTests: XCTestCase {
    func testEmptyDeviceStoreAutoConnectsToLocalDaemonUsingHomeTokenFile() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("corral-issue10-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let tokenDirectory = home.appendingPathComponent(".corral", isDirectory: true)
        try FileManager.default.createDirectory(at: tokenDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let token = "isolated-issue10-token-\(UUID().uuidString)"
        let tokenURL = tokenDirectory.appendingPathComponent("token")
        try Data(token.utf8).write(to: tokenURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)

        let support = root.appendingPathComponent("support", isDirectory: true)
        let repository = try DeviceRepository(applicationSupportDirectory: support)
        let initialDevices = try await repository.listDevices()
        XCTAssertTrue(initialDevices.isEmpty)
        let workspaceStore = try CorralWorkspaceStore(applicationSupportDirectory: support)
        let preferencesStore = try UserPreferencesStore(applicationSupportDirectory: support)
        let link = Issue10RecordingSessionLink()
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: repository,
            credentialVault: Issue10UnusedCredentialVault(),
            sessionLink: link,
            deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: link),
            workspaceStore: workspaceStore,
            userPreferencesStore: preferencesStore,
            initialWorkspaceState: await workspaceStore.snapshot(),
            initialUserPreferences: await preferencesStore.snapshot(),
            environment: ["HOME": home.path, "CORRAL_NATIVE_BACKGROUND": "1"]
        )
        let window = try XCTUnwrap(coordinator.windowController.window)
        defer { window.close() }
        window.orderBack(nil)

        // The injected link records the requested endpoint; this test never dials port 9900.
        await coordinator.start()
        let connection = await link.connectionSnapshot()
        XCTAssertEqual(connection.endpoint, "ws://127.0.0.1:9900/ws", "An empty device store must select the default local daemon")
        XCTAssertEqual(connection.credential, token, "The token in the isolated HOME/.corral/token file must reach the link")
        XCTAssertEqual(connection.count, 1, "Cold start must initiate exactly one connection")
        XCTAssertTrue(coordinator.connected)
        XCTAssertTrue(coordinator.workspaceView.sidebar.devices.contains {
            $0.isOnline && ($0.name.localizedCaseInsensitiveContains("local") || $0.name.contains("本机"))
        }, "The fallback endpoint must be presented as the local device")
        let commands = await link.commands()
        XCTAssertTrue(commands.contains { if case .list = $0 { true } else { false } }, "A successful fallback connection must request the local session listing")

        await coordinator.stop()
    }
}

private actor Issue10RecordingSessionLink: SessionLinkProtocol {
    private let stream = Issue10IdleEventStream()
    private var endpoint: String?
    private var credential: String?
    private var connections = 0
    private var sentCommands: [ClientCommand] = []

    func connect(to endpoint: ApprovedEndpoint, deviceID: DeviceID, credential: CredentialHandle) async throws -> AuthenticatedConnection {
        self.endpoint = endpoint.url.absoluteString
        self.credential = credential.rawValue
        connections += 1
        return try AuthenticatedConnection(linkInstanceID: LinkInstanceID(), deviceID: deviceID, connectionEpoch: ConnectionEpoch(1))
    }

    func eventStream() async throws -> any SessionEventStream { stream }
    func send(_ command: ClientCommand) async throws -> CommandSendReceipt {
        sentCommands.append(command)
        return CommandSendReceipt(requestID: nil, socketWritten: true)
    }
    func disconnect() async {}

    func connectionSnapshot() -> (endpoint: String?, credential: String?, count: Int) {
        (endpoint, credential, connections)
    }
    func commands() -> [ClientCommand] { sentCommands }
}

private actor Issue10IdleEventStream: SessionEventStream {
    var budget: SessionEventStreamBudget {
        SessionEventStreamBudget(maximumBufferedBytes: 1_000_000, maximumBufferedEvents: 128, maximumBufferedControls: 32)
    }

    func next() async throws -> SessionEventEnvelope? {
        try await Task.sleep(for: .seconds(3_600))
        return nil
    }
}

private actor Issue10UnusedCredentialVault: DeviceCredentialVault {
    func store(_ secret: String, for handle: CredentialHandle) async throws {}
    func resolve(_ handle: CredentialHandle) async throws -> String? { nil }
    func delete(_ handle: CredentialHandle) async throws {}
}
