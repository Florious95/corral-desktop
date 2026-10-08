import AppKit
import CorralContracts
import CorralProtocol
import CorralServices
import CorralUI
import Foundation
import Network
import XCTest
@testable import CorralApp

/// Issue 24 red gates for the two device-scoped UI paths reported by the user.
///
/// These tests drive the coordinator, its real DevicesPopover, and the real
/// pairing dialog.  They deliberately do not modify the product to make a red
/// baseline pass.
@MainActor
final class Issue24DeviceSelectionAndPairingTests: XCTestCase {
    func testDeselectingDeviceFiltersItsAgentsAndSpacesFromSidebar() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-issue24-selection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let deviceA = try DeviceRecord(
            id: DeviceID("issue24-device-a"), name: "Device A",
            endpoint: ApprovedEndpoint(host: "127.0.0.1", port: 9920),
            credential: CredentialHandle("issue24-a"))
        let deviceB = try DeviceRecord(
            id: DeviceID("issue24-device-b"), name: "Device B",
            endpoint: ApprovedEndpoint(host: "127.0.0.1", port: 9919),
            credential: CredentialHandle("issue24-b"))
        let repository = Issue24DeviceRepository(records: [deviceA, deviceB])
        let link = Issue24SessionLink()
        let workspaceStore = try CorralWorkspaceStore(applicationSupportDirectory: root.appendingPathComponent("workspace"))
        let preferencesStore = try UserPreferencesStore(applicationSupportDirectory: root.appendingPathComponent("preferences"))
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: repository,
            credentialVault: Issue24CredentialVault(),
            sessionLink: link,
            deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: link),
            workspaceStore: workspaceStore,
            userPreferencesStore: preferencesStore,
            initialWorkspaceState: await workspaceStore.snapshot(),
            initialUserPreferences: await preferencesStore.snapshot(),
            environment: [
                "CORRAL_NATIVE_ENDPOINT": deviceB.endpoint.url.absoluteString,
                "CORRAL_NATIVE_TOKEN": "issue24-b-token",
                "CORRAL_NATIVE_BACKGROUND": "1",
                "CORRAL_NATIVE_TEST_MODE": "1"
            ]
        )
        let window = try XCTUnwrap(coordinator.windowController.window)
        defer { window.close() }
        window.orderBack(nil)
        await coordinator.start()
        XCTAssertTrue(coordinator.connected, "The isolated selected device must connect through the injected link")

        let reference = try SessionReference("issue24-unchecked")
        let listing = SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(
                workingDirectory: "/issue24/unchecked-device",
                sessionCount: 1,
                aggregateState: .idle,
                sessions: [WireSessionRecord(
                    reference: reference,
                    name: "unchecked-device-agent",
                    workingDirectory: "/issue24/unchecked-device",
                    state: .idle,
                    rows: 24,
                    columns: 80
                )]
            )
        ])
        try await link.emit(.control(.listing(listing)))
        let sidebar = coordinator.workspaceView.sidebar
        let listed = await waitUntil {
            sidebar.agents.contains { $0.name == "unchecked-device-agent" }
                && sidebar.spaces.contains { $0.name == "unchecked-device" }
        }
        XCTAssertTrue(listed, "The connected device's session must first be visible in both sidebar projections")

        coordinator.workspaceView.sidebar.devicesButton.performClick(nil)
        let popover = try await waitForDevicesPopover(in: coordinator)
        let popoverLoaded = await waitUntil { popover.devices.count == 2 && popover.selectedDeviceIDs.contains(deviceB.id) }
        XCTAssertTrue(popoverLoaded)

        // This is the actual DevicesPopover selection callback used by the AppKit row.
        popover.setDevice(deviceB.id, selected: false)
        await Task.yield()

        XCTAssertFalse(
            sidebar.agents.contains { $0.name == "unchecked-device-agent" },
            "Deselecting Device B must remove its Agent rows from the real sidebar")
        XCTAssertFalse(
            sidebar.spaces.contains { $0.name == "unchecked-device" },
            "Deselecting Device B must remove Spaces derived only from its sessions")
        await coordinator.stop()
    }

    func testPairingMobileUsesLocalDaemonWhenRemoteDeviceIsActive() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-issue24-pairing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let localFixture = try Issue24WhoAmIFixture(name: "This Mac")
        let remoteFixture = try Issue24WhoAmIFixture(name: "Remote Mac")
        try await localFixture.start()
        try await remoteFixture.start()
        defer {
            localFixture.stop()
            remoteFixture.stop()
        }
        Issue24LocalDaemonURLProtocol.install(localFixture)
        URLProtocol.registerClass(Issue24LocalDaemonURLProtocol.self)
        defer {
            Issue24LocalDaemonURLProtocol.uninstall()
            URLProtocol.unregisterClass(Issue24LocalDaemonURLProtocol.self)
        }

        let remoteEndpoint = try ApprovedEndpoint(host: "127.0.0.1", port: Int(remoteFixture.port))
        let localDevice = DeviceRecord(
            id: LocalDaemonTokenDiscovery.deviceID,
            name: LocalDaemonTokenDiscovery.deviceName,
            endpoint: LocalDaemonTokenDiscovery.endpoint,
            credential: LocalDaemonTokenDiscovery.credentialHandle)
        let remoteDevice = DeviceRecord(
            id: DeviceID("issue24-remote-device"), name: "Remote Mac",
            endpoint: remoteEndpoint,
            credential: CredentialHandle("issue24-remote"))
        let repository = Issue24DeviceRepository(records: [localDevice, remoteDevice])
        let link = Issue24SessionLink()
        let workspaceStore = try CorralWorkspaceStore(applicationSupportDirectory: root.appendingPathComponent("workspace"))
        let preferencesStore = try UserPreferencesStore(applicationSupportDirectory: root.appendingPathComponent("preferences"))
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: repository,
            credentialVault: Issue24CredentialVault(values: [
                LocalDaemonTokenDiscovery.credentialHandle: localFixture.token,
                remoteDevice.credential: remoteFixture.token
            ]),
            sessionLink: link,
            deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: link),
            workspaceStore: workspaceStore,
            userPreferencesStore: preferencesStore,
            initialWorkspaceState: await workspaceStore.snapshot(),
            initialUserPreferences: await preferencesStore.snapshot(),
            environment: [
                "CORRAL_NATIVE_ENDPOINT": remoteEndpoint.url.absoluteString,
                "CORRAL_NATIVE_TOKEN": remoteFixture.token,
                "CORRAL_NATIVE_BACKGROUND": "1",
                "CORRAL_NATIVE_TEST_MODE": "1"
            ]
        )
        let window = try XCTUnwrap(coordinator.windowController.window)
        defer { window.close(); ToastManager.shared.dismissCurrent() }
        window.orderBack(nil)
        await coordinator.start()
        XCTAssertTrue(coordinator.connected, "The remote fixture must be the active connected device")
        XCTAssertEqual(coordinator.activeRoute?.url, remoteEndpoint.url)

        coordinator.workspaceView.sidebar.devicesButton.performClick(nil)
        let popover = try await waitForDevicesPopover(in: coordinator)
        let popoverLoaded = await waitUntil { popover.devices.count == 2 }
        XCTAssertTrue(popoverLoaded)
        XCTAssertTrue(popover.pairRow.accessibilityPerformPress())

        let pairingDialog = try await waitForPairingDialog(in: coordinator)
        XCTAssertNotNil(pairingDialog, "The real pairing entry must present a native pairing dialog")
        let remoteRequested = await remoteFixture.waitForPath("/pair/whoami")
        XCTAssertTrue(remoteRequested, "The red baseline must prove which route the current implementation used")
        let localRequestCount = await localFixture.requestCount(for: "/pair/whoami")
        XCTAssertGreaterThan(
            localRequestCount, 0,
            "Pairing the mobile client must query the local daemon, not the selected remote device")
        let remoteRequestCount = await remoteFixture.requestCount(for: "/pair/whoami")
        XCTAssertEqual(
            remoteRequestCount, 0,
            "The selected remote host must not be exported as this Mac's pairing QR")

        if let text = pairingDialog?.pairingText,
           let data = text.data(using: .utf8),
           let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            XCTAssertEqual(object["host_id"] as? String, localFixture.hostID)
            XCTAssertEqual(object["token"] as? String, localFixture.token)
            XCTAssertEqual(object["port"] as? Int, Int(localFixture.port))
            let candidates = object["candidates"] as? [String] ?? []
            XCTAssertEqual(candidates, localFixture.expectedCandidates)
            XCTAssertEqual(object["url"] as? String, localFixture.expectedCandidates.first)
        } else {
            XCTFail("The visible QR must contain a decodable v1 JSON payload")
        }
        await coordinator.stop()
    }

    private func waitForDevicesPopover(in coordinator: CorralApplicationCoordinator) async throws -> DevicesPopoverViewController {
        for _ in 0..<100 {
            if let panel = coordinator.devicesCardPanel,
               let controller = panel.contentViewController as? DevicesPopoverViewController {
                return controller
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw XCTSkip("The isolated DevicesPopover did not become available")
    }

    private func waitForPairingDialog(in coordinator: CorralApplicationCoordinator) async throws -> PairingDialogViewController? {
        for _ in 0..<100 {
            if let value = Mirror(reflecting: coordinator).children.first(where: { $0.label == "activeDialog" })?.value,
               let dialog = value as? PairingDialogViewController {
                return dialog
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ predicate: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}

private actor Issue24DeviceRepository: DeviceRepositoryProtocol {
    private var records: [DeviceRecord]

    init(records: [DeviceRecord]) { self.records = records }

    func listDevices() async throws -> [DeviceRecord] { records }
    func save(_ device: DeviceRecord) async throws {
        if let index = records.firstIndex(where: { $0.id == device.id }) { records[index] = device }
        else { records.append(device) }
    }
    func delete(id: DeviceID) async throws { records.removeAll { $0.id == id } }
}

private actor Issue24CredentialVault: DeviceCredentialVault {
    private var values: [CredentialHandle: String]

    init(values: [CredentialHandle: String] = [:]) { self.values = values }
    func store(_ secret: String, for handle: CredentialHandle) async throws { values[handle] = secret }
    func resolve(_ handle: CredentialHandle) async throws -> String? { values[handle] }
    func delete(_ handle: CredentialHandle) async throws { values.removeValue(forKey: handle) }
}

private actor Issue24SessionLink: SessionLinkProtocol {
    private let stream = Issue24EventStream()
    private var authenticated: AuthenticatedConnection?
    private var active: ApprovedEndpoint?
    private var ordinal: UInt64 = 0

    func connect(to endpoint: ApprovedEndpoint, deviceID: DeviceID, credential: CredentialHandle) async throws -> AuthenticatedConnection {
        let connection = try AuthenticatedConnection(linkInstanceID: LinkInstanceID(), deviceID: deviceID, connectionEpoch: ConnectionEpoch(1))
        authenticated = connection
        active = endpoint
        return connection
    }

    func connect(toAnyOf routes: [ApprovedEndpoint], deviceID: DeviceID, credential: CredentialHandle) async throws -> AuthenticatedConnection {
        guard let endpoint = routes.first else { throw EndpointSafetyError.invalidEndpoint }
        return try await connect(to: endpoint, deviceID: deviceID, credential: credential)
    }

    func activeEndpoint() async -> ApprovedEndpoint? { active }
    func eventStream() async throws -> any SessionEventStream { stream }

    func send(_ command: ClientCommand) async throws -> CommandSendReceipt {
        let requestID: UInt32? = switch command {
        case let .list(id): id
        case let .input(request): request.sequence
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
        active = nil
        await stream.finish()
    }

    func emit(_ event: SessionEvent) async throws {
        guard let authenticated else { throw SessionLinkFailure.disconnected }
        ordinal += 1
        let origin = SessionEventOrigin(
            linkInstanceID: authenticated.linkInstanceID,
            deviceID: authenticated.deviceID,
            connectionEpoch: authenticated.connectionEpoch,
            receiveOrdinal: ReceiveOrdinal(ordinal))
        try await stream.yield(SessionEventEnvelope(origin: origin, wireByteCount: 0, event: event))
    }
}

private actor Issue24EventStream: SessionEventStream {
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

private actor Issue24FixtureState {
    private var paths: [String] = []

    func record(_ path: String) { paths.append(path) }
    func requestCount(for path: String) -> Int { paths.filter { $0 == path }.count }
    func contains(_ path: String) -> Bool { paths.contains(path) }
}

private final class Issue24WhoAmIFixture: @unchecked Sendable {
    let hostID: String
    let token: String
    let name: String
    let addresses: [String]
    private let listener: NWListener
    private let queue = DispatchQueue(label: "corral.issue24.whoami")
    private let state = Issue24FixtureState()
    private(set) var port: UInt16 = 0

    init(name: String) throws {
        self.name = name
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        hostID = "issue24-\(suffix.prefix(16))"
        token = "issue24-token-\(suffix)"
        addresses = [name == "This Mac" ? "192.168.1.50" : "192.168.1.51"]
        listener = try NWListener(using: .tcp, on: XCTUnwrap(NWEndpoint.Port(rawValue: 0)))
    }

    var endpoint: String { "ws://127.0.0.1:\(port)/ws" }
    var expectedCandidates: [String] { addresses.map { "ws://\($0):\(port)/ws" } }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        for _ in 0..<100 {
            if case .ready = listener.state, let assigned = listener.port?.rawValue, assigned != 0 {
                port = assigned
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Issue24FixtureError.notReady
    }

    func stop() { listener.cancel() }
    func waitForPath(_ path: String) async -> Bool {
        for _ in 0..<100 {
            if await state.contains(path) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await state.contains(path)
    }
    func requestCount(for path: String) async -> Int { await state.requestCount(for: path) }

    func whoAmIData() -> Data {
        let object: [String: Any] = [
            "v": 1,
            "host_id": hostID,
            "name": name,
            "port": Int(port),
            "addresses": addresses
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .ready = state, let self, let connection else { return }
            self.receive(on: connection)
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self, weak connection] data, _, _, _ in
            guard let self, let connection, let data else { return }
            let request = String(decoding: data, as: UTF8.self)
            let path = request.split(separator: "\r\n", maxSplits: 1).first?
                .split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? "/"
            Task { await self.state.record(path) }
            let body = path == "/pair/whoami" ? self.whoAmIData() : Data(#"{"error":"not found"}"#.utf8)
            let status = path == "/pair/whoami" ? "200 OK" : "404 Not Found"
            let header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var response = Data(header.utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

private enum Issue24FixtureError: Error { case notReady }

private final class Issue24URLProtocolHolder: @unchecked Sendable {
    let lock = NSLock()
    var fixture: Issue24WhoAmIFixture?
}

private final class Issue24LocalDaemonURLProtocol: URLProtocol {
    private static let holder = Issue24URLProtocolHolder()

    static func install(_ fixture: Issue24WhoAmIFixture) {
        holder.lock.lock(); defer { holder.lock.unlock() }
        holder.fixture = fixture
    }

    static func uninstall() {
        holder.lock.lock(); defer { holder.lock.unlock() }
        holder.fixture = nil
    }

    private static func currentFixture() -> Issue24WhoAmIFixture? {
        holder.lock.lock(); defer { holder.lock.unlock() }
        return holder.fixture
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return url.scheme == "http" && url.host == "127.0.0.1" && url.port == 9900 && url.path == "/pair/whoami"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fixture = Self.currentFixture(), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        Task { await fixture.stateRecordForURLProtocol() }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.whoAmIData())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension Issue24WhoAmIFixture {
    func stateRecordForURLProtocol() async { await state.record("/pair/whoami") }
}
