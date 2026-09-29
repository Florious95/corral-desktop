import AppKit
import CorralContracts
import CorralProtocol
import CorralServices
import Foundation
import XCTest
@testable import CorralApp

@MainActor
final class Issue10LocalDaemonAutoConnectTests: XCTestCase {
    func testMacOSApplicationSupportTokenPathsAreDiscovered() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("corral-issue10-token-paths-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        for (relativePath, token) in [
            ("Library/Application Support/agentmirror/token", "agentmirror-fixture-token"),
            ("Library/Application Support/corral/token", "corral-fixture-token")
        ] {
            let tokenFile = home.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: tokenFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(token.utf8).write(to: tokenFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
            let discoveredToken = await LocalDaemonTokenDiscovery.token(
                environment: ["HOME": home.path],
                credentialVault: Issue10EmptyCredentialVault()
            )
            XCTAssertEqual(discoveredToken, token, "The app must discover tokens in ~/\(relativePath)")
            try FileManager.default.removeItem(at: tokenFile)
        }
    }

    func testMissingLocalTokenDoesNotOpenUnauthenticatedSession() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("corral-issue10-no-token-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let support = root.appendingPathComponent("support", isDirectory: true)
        let repository = try DeviceRepository(applicationSupportDirectory: support)
        let workspaceStore = try CorralWorkspaceStore(applicationSupportDirectory: support)
        let preferencesStore = try UserPreferencesStore(applicationSupportDirectory: support)
        let link = Issue10PairingSessionLink()
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: repository,
            credentialVault: Issue10EmptyCredentialVault(),
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

        await coordinator.start()
        let connection = await link.connectionSnapshot()
        XCTAssertEqual(connection.count, 0, "The app must not mark a tokenless local socket authenticated")
        XCTAssertFalse(coordinator.connected)
        await coordinator.stop()
    }

    func testFreshInstallWithMacOSPersistedTokenAuthenticatesAndListsSessions() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("corral-issue10-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let presetTokenPaths = [
            home.appendingPathComponent(".corral/token"),
            home.appendingPathComponent(".config/corral/token"),
            home.appendingPathComponent(".config/agentmirror/token")
        ]
        XCTAssertTrue(presetTokenPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let localToken = "issue10-persisted-local-token"
        let tokenFile = home.appendingPathComponent("Library/Application Support/agentmirror/token")
        try FileManager.default.createDirectory(at: tokenFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(localToken.utf8).write(to: tokenFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)

        let support = root.appendingPathComponent("support", isDirectory: true)
        let repository = try DeviceRepository(applicationSupportDirectory: support)
        let initialDevices = try await repository.listDevices()
        XCTAssertTrue(initialDevices.isEmpty)
        let workspaceStore = try CorralWorkspaceStore(applicationSupportDirectory: support)
        let preferencesStore = try UserPreferencesStore(applicationSupportDirectory: support)
        let link = Issue10PairingSessionLink()
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: repository,
            credentialVault: Issue10EmptyCredentialVault(),
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

        // The isolated link models auth_ack then listing without dialing production 9900.
        await coordinator.start()
        let connection = await link.connectionSnapshot()
        XCTAssertEqual(connection.endpoint, "ws://127.0.0.1:9900/ws", "A zero-config install must select the default local daemon")
        XCTAssertEqual(connection.count, 1, "A zero-config install must initiate the local authenticated connection")
        XCTAssertTrue(connection.authHandshakeCompleted, "The local auth handshake must complete with the persisted token")
        XCTAssertEqual(connection.credential, localToken, "The discovered macOS token must reach the authenticated link")
        XCTAssertTrue(coordinator.connected, "A successful local handshake must mark the local device online")
        XCTAssertTrue(coordinator.workspaceView.sidebar.devices.contains {
            $0.isOnline && ($0.name.localizedCaseInsensitiveContains("local") || $0.name.contains("本机"))
        }, "The fallback endpoint must be presented as the local device")

        var listed = false
        for _ in 0..<100 {
            if coordinator.sessionCount == 1 && coordinator.workspaceView.sidebar.agents.count == 1 {
                listed = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(listed, "The authenticated local connection must pull the first live session into the sidebar")
        let commands = await link.commands()
        XCTAssertTrue(commands.contains { if case .list = $0 { true } else { false } }, "A successful local handshake must request the local session listing")

        await coordinator.stop()
    }
}

private actor Issue10PairingSessionLink: SessionLinkProtocol {
    private let stream = Issue10PairingEventStream()
    private var endpoint: String?
    private var credential: String?
    private var connections = 0
    private var authHandshakeCompleted = false
    private var authenticatedConnection: AuthenticatedConnection?
    private var sentCommands: [ClientCommand] = []

    func connect(to endpoint: ApprovedEndpoint, deviceID: DeviceID, credential: CredentialHandle) async throws -> AuthenticatedConnection {
        self.endpoint = endpoint.url.absoluteString
        self.credential = credential.rawValue
        connections += 1
        authHandshakeCompleted = !credential.rawValue.isEmpty && credential.rawValue != SessionLinkCredential.localPeerAnonymous.rawValue
        let connection = try AuthenticatedConnection(linkInstanceID: LinkInstanceID(), deviceID: deviceID, connectionEpoch: ConnectionEpoch(1))
        authenticatedConnection = connection
        return connection
    }

    func eventStream() async throws -> any SessionEventStream { stream }
    func send(_ command: ClientCommand) async throws -> CommandSendReceipt {
        sentCommands.append(command)
        if case .list = command, let authenticatedConnection {
            await stream.enqueueListing(for: authenticatedConnection)
        }
        return CommandSendReceipt(requestID: nil, socketWritten: true)
    }
    func disconnect() async {}

    func connectionSnapshot() -> (endpoint: String?, credential: String?, count: Int, authHandshakeCompleted: Bool) {
        (endpoint, credential, connections, authHandshakeCompleted)
    }
    func commands() -> [ClientCommand] { sentCommands }
}

private actor Issue10PairingEventStream: SessionEventStream {
    private var pending: [SessionEventEnvelope] = []
    private var nextWaiter: CheckedContinuation<SessionEventEnvelope?, Never>?
    private var listingEnqueued = false

    var budget: SessionEventStreamBudget {
        SessionEventStreamBudget(maximumBufferedBytes: 1_000_000, maximumBufferedEvents: 128, maximumBufferedControls: 32)
    }

    func enqueueListing(for connection: AuthenticatedConnection) {
        let reference = try! SessionReference("local-agent-1")
        let session = WireSessionRecord(
            reference: reference,
            name: "local-agent-1",
            workingDirectory: "/Users/fixture",
            state: .working,
            rows: 24,
            columns: 80,
            provider: "codex",
            activity: "working",
            health: "normal"
        )
        let listing = SessionListing(
            requestID: 1,
            sequence: 1,
            workspaces: [WorkspaceRecord(
                workingDirectory: "/Users/fixture",
                sessionCount: 1,
                aggregateState: .working,
                workingCount: 1,
                sessions: [session]
            )]
        )
        let origin = SessionEventOrigin(
            linkInstanceID: connection.linkInstanceID,
            deviceID: connection.deviceID,
            connectionEpoch: connection.connectionEpoch,
            receiveOrdinal: ReceiveOrdinal(1)
        )
        let envelope = try! SessionEventEnvelope(
            origin: origin,
            wireByteCount: 1,
            event: .control(.listing(listing))
        )
        listingEnqueued = true
        if let nextWaiter {
            self.nextWaiter = nil
            nextWaiter.resume(returning: envelope)
        } else {
            pending.append(envelope)
        }
    }

    func next() async throws -> SessionEventEnvelope? {
        if !pending.isEmpty { return pending.removeFirst() }
        if listingEnqueued { return nil }
        return await withCheckedContinuation { continuation in
            nextWaiter = continuation
        }
    }
}

private actor Issue10EmptyCredentialVault: DeviceCredentialVault {
    func store(_ secret: String, for handle: CredentialHandle) async throws {}
    func resolve(_ handle: CredentialHandle) async throws -> String? { nil }
    func delete(_ handle: CredentialHandle) async throws {}
}
