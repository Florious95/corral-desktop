import AppKit
import CoreImage
import CorralContracts
import CorralProtocol
import CorralServices
import CorralUI
import Darwin
import Foundation
import ImageIO
import Network
import Vision
import XCTest
@testable import CorralApp

/// Issue 23 red gate.  This is deliberately an app-local, real-transport test:
/// the QR is encoded to PNG and decoded again with Vision, the Add Device
/// dialog is the production dialog, the repository is the production actor, and
/// the connection uses URLSession's WebSocket implementation against a private
/// dynamically allocated listener.  Nothing in this file uses production 9900.
@MainActor
final class Issue23RemotePairingImportTests: XCTestCase {
    func testImportedRemoteQRCodePersistsReloadsAndReconnects() async throws {
        _ = NSApplication.shared
        let fixture = try RemotePairingDaemonFixture(token: "issue23-remote-token")
        try await fixture.start()
        defer { fixture.stop() }

        let qrPayload = fixture.qrPayload
        let png = try makeQRCodePNG(qrPayload)
        let decodedPayload = try decodeQRCodePNG(png)
        XCTAssertEqual(decodedPayload, qrPayload, "The imported QR must round-trip as one-line v1 JSON")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-issue23-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let credentials = PrivateFileCredentialVault(
            directoryURL: support
                .appendingPathComponent(DeviceRepository.namespace, isDirectory: true)
                .appendingPathComponent(".credentials", isDirectory: true)
        )
        let repository = try DeviceRepository(applicationSupportDirectory: support)
        let coordinator = try await makeCoordinator(
            repository: repository,
            credentials: credentials,
            support: support
        )
        let window = try XCTUnwrap(coordinator.windowController.window)
        defer {
            coordinator.devicesCardPanel?.orderOut(nil)
            window.close()
            ToastManager.shared.dismissCurrent()
        }

        let dialog = try await presentAddDeviceDialog(in: coordinator, window: window)
        XCTAssertTrue(dialog.acceptPairingJSON(decodedPayload), "The production import surface must accept the decoded v1 QR payload")
        dialog.submit()

        // The current baseline shows an error Toast here: addDevice() reaches
        // ApprovedEndpoint before any repository write.  Keep this assertion
        // after the real UI path so the failure identifies the delivery gap.
        var devices = try await repository.listDevices()
        for _ in 0..<100 where devices.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            devices = try await repository.listDevices()
        }
        XCTAssertEqual(devices.count, 1,
                       "A QR-imported LAN/Tailscale device must be persisted; production currently rejects the non-loopback endpoint")
        guard let device = devices.first else { return }
        XCTAssertEqual(device.name, fixture.name)
        XCTAssertEqual(device.endpoint.url.absoluteString, fixture.primaryCandidate)

        // Reload the actual private stores, as a second app process would, and
        // reconnect through the same URLSession WebSocket implementation.
        let reloadedRepository = try DeviceRepository(applicationSupportDirectory: support)
        let reloaded = try await reloadedRepository.listDevices()
        XCTAssertEqual(reloaded, devices, "The imported remote device must survive app restart")
        let resolvedToken = try await credentials.resolve(device.credential)
        let token = try XCTUnwrap(resolvedToken)
        XCTAssertEqual(token, fixture.token)

        let link = URLSessionSessionLink()
        let connection = try await link.connect(
            to: device.endpoint,
            deviceID: device.id,
            credential: CredentialHandle(token)
        )
        XCTAssertEqual(connection.deviceID, device.id)
        let acceptedTokens = await fixture.authenticatedTokens()
        XCTAssertEqual(acceptedTokens, [fixture.token, fixture.token])
        await link.disconnect()
    }

    func testNegativeControlsRejectOrdinaryRemoteEndpointsMalformedURLsAndWrongTokens() async throws {
        let fixture = try RemotePairingDaemonFixture(token: "issue23-correct-token")
        try await fixture.start()
        defer { fixture.stop() }

        // A normal developer endpoint must remain loopback-only.  The positive
        // QR-import path above must use an explicit pairing trust boundary, not
        // silently make every manually entered development URL remote-safe.
        XCTAssertThrowsError(try ApprovedEndpoint(url: XCTUnwrap(URL(string: fixture.primaryCandidate)))) {
            XCTAssertEqual($0 as? EndpointSafetyError, .nonLoopbackEndpointForbidden)
        }

        let host = try XCTUnwrap(URL(string: fixture.primaryCandidate)?.host)
        for rawURL in [
            "ws://user:password@\(host):\(fixture.port)/ws",
            "ws://\(host):\(fixture.port)/ws?token=leak",
            "ws://\(host):\(fixture.port)/ws#fragment",
            "ws://\(host):\(fixture.port)/not-ws"
        ] {
            XCTAssertThrowsError(try ApprovedEndpoint(url: XCTUnwrap(URL(string: rawURL))), rawURL)
        }

        // The real private daemon rejects an identity/token mismatch.  This is
        // a negative transport control, not a fake socket or a production call.
        let loopback = try ApprovedEndpoint(url: XCTUnwrap(URL(string: fixture.loopbackCandidate)))
        let link = URLSessionSessionLink()
        do {
            _ = try await link.connect(
                to: loopback,
                deviceID: DeviceID("issue23-negative"),
                credential: CredentialHandle("wrong-token")
            )
            XCTFail("A token for a different paired host must not authenticate")
        } catch let error as SessionLinkFailure {
            XCTAssertEqual(error, .unauthorized)
        }
        await link.disconnect()
        let rejectedTokens = await fixture.authenticatedTokens()
        XCTAssertEqual(rejectedTokens, ["wrong-token"])
    }

    private func makeCoordinator(
        repository: DeviceRepository,
        credentials: PrivateFileCredentialVault,
        support: URL
    ) async throws -> CorralApplicationCoordinator {
        let workspace = try CorralWorkspaceStore(applicationSupportDirectory: support.appendingPathComponent("workspace"))
        let preferences = try UserPreferencesStore(applicationSupportDirectory: support.appendingPathComponent("preferences"))
        let link = URLSessionSessionLink()
        return CorralApplicationCoordinator(
            deviceRepository: repository,
            credentialVault: credentials,
            sessionLink: link,
            deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: link),
            workspaceStore: workspace,
            userPreferencesStore: preferences,
            initialWorkspaceState: await workspace.snapshot(),
            initialUserPreferences: await preferences.snapshot(),
            environment: ["CORRAL_NATIVE_BACKGROUND": "1"]
        )
    }

    private func presentAddDeviceDialog(
        in coordinator: CorralApplicationCoordinator,
        window: NSWindow
    ) async throws -> AddDeviceDialogViewController {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        coordinator.workspaceView.sidebar.devicesButton.performClick(nil)
        for _ in 0..<100 {
            if let panel = coordinator.devicesCardPanel,
               let devices = panel.contentViewController as? DevicesPopoverViewController {
                XCTAssertTrue(devices.addRow.accessibilityPerformPress(), "The real Add Device row must be pressable")
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<100 {
            if let value = Mirror(reflecting: coordinator).children.first(where: { $0.label == "addDeviceDialog" })?.value,
               let dialog = value as? AddDeviceDialogViewController {
                return dialog
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Issue23TestError.dialogDidNotOpen
    }
}

private enum Issue23TestError: Error {
    case dialogDidNotOpen
    case listenerDidNotBecomeReady
    case noPrivateIPv4Address
    case qrEncodingFailed
    case qrDecodingFailed
}

private func makeQRCodePNG(_ payload: String) throws -> Data {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(payload.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { throw Issue23TestError.qrEncodingFailed }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    let context = CIContext()
    guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
        throw Issue23TestError.qrEncodingFailed
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw Issue23TestError.qrEncodingFailed
    }
    return png
}

private func decodeQRCodePNG(_ png: Data) throws -> String {
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    let handler = VNImageRequestHandler(data: png, options: [:])
    try handler.perform([request])
    guard let payload = request.results?.compactMap(\.payloadStringValue).first else {
        throw Issue23TestError.qrDecodingFailed
    }
    return payload
}

private actor RemotePairingDaemonState {
    private var tokens: [String] = []

    func record(token: String) { tokens.append(token) }
    func tokensSnapshot() -> [String] { tokens }
}

/// A real WebSocket fixture on an ephemeral port.  It binds all local
/// interfaces so a LAN/Tailscale candidate is a genuine URLSession connection,
/// while remaining isolated from the production daemon on 9900.
private final class RemotePairingDaemonFixture: @unchecked Sendable {
    let token: String
    let hostID = "issue23-remote-host"
    let name = "Issue 23 Remote Fixture"
    private(set) var port: UInt16 = 0
    private(set) var primaryCandidate = ""
    private(set) var loopbackCandidate = ""
    private(set) var qrPayload = ""

    private let listener: NWListener
    private let queue = DispatchQueue(label: "corral.issue23.remote-websocket")
    private let state = RemotePairingDaemonState()
    private var connections: [NWConnection] = []

    init(token: String) throws {
        self.token = token
        let addresses = Self.nonLoopbackIPv4Addresses()
        guard addresses.first != nil else { throw Issue23TestError.noPrivateIPv4Address }
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        guard let dynamicPort = NWEndpoint.Port(rawValue: 0) else {
            throw Issue23TestError.listenerDidNotBecomeReady
        }
        listener = try NWListener(using: parameters, on: dynamicPort)
    }

    func start() async throws {
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                fputs("Issue23 WebSocket fixture failed: \(error)\n", stderr)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        for _ in 0..<200 {
            if case .ready = listener.state, let port = listener.port?.rawValue {
                let addresses = Self.nonLoopbackIPv4Addresses()
                let primary = addresses.first ?? "127.0.0.1"
                let tailnet = addresses.first(where: { $0.hasPrefix("100.") })
                let lan = addresses.first(where: { !$0.hasPrefix("100.") }) ?? primary
                let candidates = [lan, tailnet].compactMap { $0 }.map { "ws://\($0):\(port)/ws" } + ["ws://127.0.0.1:\(port)/ws"]
                self.port = port
                self.primaryCandidate = candidates[0]
                self.loopbackCandidate = candidates.last!
                self.qrPayload = try! Self.makePayload(
                    hostID: self.hostID,
                    name: self.name,
                    port: port,
                    token: self.token,
                    candidates: candidates
                )
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Issue23TestError.listenerDidNotBecomeReady
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    func authenticatedTokens() async -> [String] { await state.tokensSnapshot() }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .ready = state, let self, let connection else { return }
            self.receive(on: connection)
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, context, _, _ in
            guard let self, let connection, let data,
                  let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata,
                  metadata.opcode == .text else {
                connection?.cancel()
                return
            }
            let token = Self.token(from: data) ?? ""
            Task { await self.state.record(token: token) }
            let ok = token == self.token
            let response = ok
                ? #"{"v":1,"type":"auth_ack","payload":{"ok":true}}"#
                : #"{"v":1,"type":"auth_ack","payload":{"ok":false,"reason":"unauthorized"}}"#
            let responseMetadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let responseContext = NWConnection.ContentContext(
                identifier: "issue23-auth-ack",
                metadata: [responseMetadata]
            )
            connection.send(
                content: Data(response.utf8),
                contentContext: responseContext,
                isComplete: true,
                completion: .contentProcessed { _ in
                    if ok { self.receive(on: connection) }
                    else { connection.cancel() }
                }
            )
        }
    }

    private static func token(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "auth",
              let payload = object["payload"] as? [String: Any] else { return nil }
        return payload["token"] as? String
    }

    private static func makePayload(
        hostID: String,
        name: String,
        port: UInt16,
        token: String,
        candidates: [String]
    ) throws -> String {
        let value: [String: Any] = [
            "v": 1,
            "host_id": hostID,
            "name": name,
            "port": Int(port),
            "url": candidates[0],
            "token": token,
            "candidates": candidates
        ]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func nonLoopbackIPv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [String] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var storage = sockaddr_in()
            memcpy(&storage, address, MemoryLayout<sockaddr_in>.size)
            let host = withUnsafePointer(to: &storage.sin_addr) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: 4) { bytes in
                    (0..<4).map { String(bytes[$0]) }.joined(separator: ".")
                }
            }
            guard host != "127.0.0.1", !host.isEmpty else { continue }
            if !result.contains(host) { result.append(host) }
        }
        return result.sorted { lhs, rhs in
            let lhsTailnet = lhs.hasPrefix("100.")
            let rhsTailnet = rhs.hasPrefix("100.")
            if lhsTailnet != rhsTailnet { return !lhsTailnet }
            return lhs < rhs
        }
    }
}
