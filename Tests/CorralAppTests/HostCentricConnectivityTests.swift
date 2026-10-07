import AppKit
import CorralContracts
import CorralProtocol
import CorralServices
import CorralUI
import Foundation
import XCTest
@testable import CorralApp

/// The user pairs a host, not an IP. A QR-paired device keeps every route of its host, the coordinator
/// dials Tailscale first, learns the Tailscale route the QR could not carry (only after identify proves
/// it), and re-pairing the same host_id updates the same device.
@MainActor
final class HostCentricConnectivityTests: XCTestCase {
    private let hostID = "studio-host-0001"
    private let token = "host-centric-token"

    func testPairedHostKeepsEveryRouteDialsTailscaleFirstAndLearnsProvenRoutes() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("corral-host-centric-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let repository = try DeviceRepository(applicationSupportDirectory: support)
        let credentials = PrivateFileCredentialVault(directoryURL: support.appendingPathComponent(".credentials", isDirectory: true))
        let link = HostCentricRecordingLink()
        // The daemon prints its QR before tsnet is up: the QR knows the LAN route only. Whoami later lists
        // the Tailscale address too, plus an address an impostor answers for without the pairing token.
        let host = FakeAgentMirrorHost(hostID: hostID, token: token, port: 9931,
                                       addresses: ["192.168.31.116", "100.101.2.3", "192.168.31.250"],
                                       impostors: ["192.168.31.250"])
        let workspace = try CorralWorkspaceStore(applicationSupportDirectory: support.appendingPathComponent("workspace"))
        let preferences = try UserPreferencesStore(applicationSupportDirectory: support.appendingPathComponent("preferences"))
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: repository, credentialVault: credentials, sessionLink: link,
            deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: link),
            workspaceStore: workspace, userPreferencesStore: preferences,
            initialWorkspaceState: await workspace.snapshot(), initialUserPreferences: await preferences.snapshot(),
            environment: ["CORRAL_NATIVE_BACKGROUND": "1", "HOME": root.path],
            hostIdentityProbe: HostIdentityProbe(transport: host.transport)
        )
        let window = try XCTUnwrap(coordinator.windowController.window)
        defer { coordinator.devicesCardPanel?.orderOut(nil); window.close(); ToastManager.shared.dismissCurrent() }

        try await importPairing(qr(candidates: ["ws://192.168.31.116:9931/ws", "ws://127.0.0.1:9931/ws"]), into: coordinator, window: window)
        let learned = await waitUntil { await link.routeUpdates().isEmpty == false }
        XCTAssertTrue(learned, "Connecting must learn the host's other proven routes")

        let dials = await link.dials()
        XCTAssertEqual(dials.first, ["ws://192.168.31.116:9931/ws"], "The phone-local loopback candidate is never a route to a paired host")
        let stored = try await repository.listDevices()
        let device = try XCTUnwrap(stored.first)
        XCTAssertEqual(device.endpoints.map(\.url.absoluteString), ["ws://100.101.2.3:9931/ws", "ws://192.168.31.116:9931/ws"],
                       "The proven Tailscale route is stored and dialed first; the impostor address is not")
        let updates = await link.routeUpdates()
        XCTAssertEqual(updates.last?.map(\.route), [.tailnet, .lan], "Later reconnects must race the learned Tailscale route")
        XCTAssertEqual(host.identifiedAddresses.sorted(), ["100.101.2.3", "192.168.31.250"], "Every new address must be proven before use")
        XCTAssertEqual(coordinator.activeRoute?.route, .lan)

        // Re-pairing the same host from another network updates that host instead of adding a second one.
        try await importPairing(qr(candidates: ["ws://10.0.0.8:9931/ws", "ws://100.101.2.3:9931/ws"]), into: coordinator, window: window)
        let redialed = await waitUntil { await link.dials().count == 2 }
        XCTAssertTrue(redialed)
        let devices = try await repository.listDevices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.id, device.id)
        let secondDial = await link.dials().last
        XCTAssertEqual(secondDial, ["ws://100.101.2.3:9931/ws", "ws://10.0.0.8:9931/ws"], "Tailscale is dialed before LAN")
    }

    private func qr(candidates: [String]) -> String {
        let object: [String: Any] = ["v": 1, "host_id": hostID, "name": "Mac Studio", "token": token, "url": candidates[0], "candidates": candidates, "port": 9931]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func importPairing(_ payload: String, into coordinator: CorralApplicationCoordinator, window: NSWindow) async throws {
        window.orderBack(nil)
        coordinator.workspaceView.sidebar.devicesButton.performClick(nil)
        var pressed = false
        for _ in 0..<100 where !pressed {
            if let devices = coordinator.devicesCardPanel?.contentViewController as? DevicesPopoverViewController {
                pressed = devices.addRow.accessibilityPerformPress()
            } else { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertTrue(pressed, "The real Add Device row must be pressable")
        var dialog: AddDeviceDialogViewController?
        for _ in 0..<100 where dialog == nil {
            dialog = Mirror(reflecting: coordinator).children.first { $0.label == "addDeviceDialog" }?.value as? AddDeviceDialogViewController
            if dialog == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let addDialog = try XCTUnwrap(dialog)
        XCTAssertTrue(addDialog.acceptPairingJSON(payload))
        addDialog.submit()
    }

    private func waitUntil(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }
}

/// Speaks `/pair/whoami` and `/pair/identify` for one host; impostor addresses answer identify without the token.
private final class FakeAgentMirrorHost: @unchecked Sendable {
    let hostID: String, token: String, port: Int, addresses: [String], impostors: Set<String>
    private let lock = NSLock()
    private var identified: [String] = []

    init(hostID: String, token: String, port: Int, addresses: [String], impostors: Set<String>) {
        self.hostID = hostID; self.token = token; self.port = port; self.addresses = addresses; self.impostors = impostors
    }

    var identifiedAddresses: [String] { lock.withLock { identified } }

    var transport: HostIdentityProbe.Transport {
        { [self] request in
            let url = try XCTUnwrap(request.url)
            let ok = { (body: String) in (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
            if url.path == "/pair/whoami" {
                let list = addresses.map { "\"\($0)\"" }.joined(separator: ",")
                return ok(#"{"v":1,"host_id":"\#(hostID)","name":"Mac Studio","port":\#(port),"addresses":[\#(list)]}"#)
            }
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            let nonce = try XCTUnwrap(body["nonce"] as? String), address = try XCTUnwrap(url.host)
            lock.withLock { identified.append(address) }
            let key = impostors.contains(address) ? "not-the-pairing-token" : token
            let mac = HostIdentityProbe.identifyMAC(token: key, hostID: hostID, nonce: nonce, boundIP: address, boundPort: port)
            return ok(#"{"v":1,"host_id":"\#(hostID)","name":"Mac Studio","bound":"\#(address):\#(port)","mac":"\#(mac)"}"#)
        }
    }
}

private actor HostCentricRecordingLink: SessionLinkProtocol {
    private var dialed: [[String]] = []
    private var updates: [[ApprovedEndpoint]] = []
    private var active: ApprovedEndpoint?

    func connect(to endpoint: ApprovedEndpoint, deviceID: DeviceID, credential: CredentialHandle) async throws -> AuthenticatedConnection {
        try await connect(toAnyOf: [endpoint], deviceID: deviceID, credential: credential)
    }
    func connect(toAnyOf routes: [ApprovedEndpoint], deviceID: DeviceID, credential: CredentialHandle) async throws -> AuthenticatedConnection {
        dialed.append(routes.map(\.url.absoluteString))
        // The preferred route of the first dial is unreachable from this "network": LAN wins.
        active = dialed.count == 1 ? routes.last : routes.first
        return try AuthenticatedConnection(linkInstanceID: LinkInstanceID(), deviceID: deviceID, connectionEpoch: ConnectionEpoch(UInt64(dialed.count)))
    }
    func updateRoutes(_ routes: [ApprovedEndpoint]) async { updates.append(routes) }
    func activeEndpoint() async -> ApprovedEndpoint? { active }
    func eventStream() async throws -> any SessionEventStream { HostCentricSilentStream() }
    func send(_ command: ClientCommand) async throws -> CommandSendReceipt { CommandSendReceipt(requestID: nil, socketWritten: true) }
    func disconnect() async {}
    func dials() -> [[String]] { dialed }
    func routeUpdates() -> [[ApprovedEndpoint]] { updates }
}

private struct HostCentricSilentStream: SessionEventStream {
    var budget: SessionEventStreamBudget { SessionEventStreamBudget(maximumBufferedBytes: 1_024, maximumBufferedEvents: 1, maximumBufferedControls: 1) }
    func next() async throws -> SessionEventEnvelope? { nil }
}
