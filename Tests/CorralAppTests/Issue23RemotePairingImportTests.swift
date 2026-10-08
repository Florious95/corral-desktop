import AppKit
import CoreImage
import CryptoKit
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

        // The coordinator dials the host's Tailscale route first and LAN joins
        // after the head start, so its own authentication may still be in flight.
        for _ in 0..<250 where !coordinator.connected { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(coordinator.connected, "Importing the QR must connect the coordinator to the paired host")
        let coordinatorTokens = await fixture.authenticatedTokens()
        XCTAssertFalse(coordinatorTokens.isEmpty)
        XCTAssertTrue(coordinatorTokens.allSatisfy { $0 == fixture.token }, "Only the paired token may reach any route")

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
        XCTAssertEqual(acceptedTokens, coordinatorTokens + [fixture.token])
        await link.disconnect()
    }

    /// The machine running this suite has a system HTTP proxy.  This test
    /// first proves the private Tailscale listener is reachable with an
    /// explicitly direct URLSession, then requires the production probe to do
    /// the same.  The baseline probe inherits the proxy and times out on 100.x.
    func testHostIdentityProbeBypassesSystemProxyForTailnetWhoAmI() async throws {
        let addresses = LiveRoutePairingFixture.nonLoopbackPrivateIPv4Addresses()
        guard let tailnet = addresses.first(where: { ApprovedEndpoint.route(forHost: $0) == .tailnet }),
              let lan = addresses.first(where: { ApprovedEndpoint.route(forHost: $0) == .lan }) else {
            throw XCTSkip("Requires one local Tailscale and one local LAN IPv4 address")
        }
        let fixture = try LiveRoutePairingFixture(
            hostID: "issue23-whoami-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16),
            token: "issue23-whoami-token",
            tailnetHost: tailnet,
            lanHost: lan
        )
        try await fixture.start()
        defer { fixture.stop() }

        var whoamiURL = URLComponents(url: fixture.tailnet.endpoint.url, resolvingAgainstBaseURL: false)!
        whoamiURL.scheme = "http"
        whoamiURL.path = "/pair/whoami"
        let direct = try await directHTTPGet(whoamiURL.url!, timeout: 1)
        XCTAssertEqual(direct.1.statusCode, 200, "The isolated direct control must reach the local Tailscale listener")
        print("TAILNET_DIRECT_WHOAMI host=\(tailnet) status=\(direct.1.statusCode)")

        let identity = try await HostIdentityProbe(timeout: 1).whoami(at: fixture.tailnet.endpoint)
        XCTAssertEqual(identity.hostID, fixture.hostID,
                       "Production /pair/whoami must bypass the system proxy and reach the paired Tailscale host")
    }

    /// Real URLSession transport gate for the network-switch report.  The two
    /// listeners are private, dynamically allocated ports on this Mac's own
    /// Tailscale and LAN addresses; no production endpoint is touched.  The
    /// client is deliberately connected LAN-first, then the active LAN socket
    /// is black-holed; it must re-race the host's routes, authenticate over
    /// Tailscale, and restore every open session subscription there.
    func testLiveURLSessionFailsOverAcrossPrivateTailnetAndLANRoutes() async throws {
        let addresses = LiveRoutePairingFixture.nonLoopbackPrivateIPv4Addresses()
        guard let tailnet = addresses.first(where: { ApprovedEndpoint.route(forHost: $0) == .tailnet }),
              let lan = addresses.first(where: { ApprovedEndpoint.route(forHost: $0) == .lan }) else {
            throw XCTSkip("Requires one local Tailscale and one local LAN IPv4 address")
        }

        let fixture = try LiveRoutePairingFixture(
            hostID: "issue23-route-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16),
            token: "issue23-route-token-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24),
            tailnetHost: tailnet,
            lanHost: lan
        )
        try await fixture.start()
        defer { fixture.stop() }

        // Use the production URLSessionSessionLink so this gate exercises the
        // shipped proxy policy as well as route healing.  A Tailscale address
        // must never be handed to the user's HTTP proxy.
        let link = URLSessionSessionLink()
        let events = try await link.eventStream()

        _ = try await link.connect(toAnyOf: [fixture.lan.endpoint, fixture.tailnet.endpoint], deviceID: DeviceID("issue23-live-route"),
                                   credential: CredentialHandle(fixture.token))
        let initialRoute = await link.activeEndpoint()?.route
        XCTAssertEqual(initialRoute, .lan, "The controlled starting condition must be the LAN route")

        let references = try ["live-route-session-a", "live-route-session-b", "live-route-session-c"].map(SessionReference.init)
        for reference in references {
            _ = try await link.send(.subscribe(reference: reference, size: GridSize(rows: 32, columns: 110)))
        }
        for reference in references {
            let received = await fixture.lan.waitForCommand(containing: reference.rawValue)
            XCTAssertTrue(received,
                          "The initial LAN WebSocket must receive every open session subscription")
        }

        fixture.lan.blockAndDrop()
        let reconnected = await waitForReady(epoch: ConnectionEpoch(2), in: events)
        XCTAssertTrue(reconnected,
                      "The active LAN black hole must produce a new authenticated connection epoch")
        let healedRoute = await link.activeEndpoint()?.route
        XCTAssertEqual(healedRoute, .tailnet,
                       "When LAN is black-holed, reconnect must search and select the Tailscale route")
        for reference in references {
            let restored = await fixture.tailnet.waitForCommand(containing: reference.rawValue)
            XCTAssertTrue(restored,
                          "Failover to Tailscale must restore every open session subscription")
        }

        let tailnetAuth = await fixture.tailnet.authenticationCount()
        let lanAuth = await fixture.lan.authenticationCount()
        XCTAssertGreaterThanOrEqual(tailnetAuth, 1, "The reconnect must complete a fresh Tailscale authentication")
        XCTAssertGreaterThanOrEqual(lanAuth, 1, "The initial connection must authenticate on LAN")
        print("LIVE_ROUTE_FAILOVER initial=lan healed=tailnet tailnet=\(tailnet) lan=\(lan) authCounts=\(tailnetAuth)/\(lanAuth) epochs=1,2")
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

    private func waitForReady(
        epoch: ConnectionEpoch,
        in stream: any SessionEventStream,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    while let envelope = try await stream.next() {
                        if case let .connectionChanged(.authenticatedReady(ready)) = envelope.event, ready == epoch {
                            return true
                        }
                    }
                } catch is CancellationError {
                    return false
                } catch {
                    return false
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func directHTTPGet(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
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

/// A real daemon-shaped fixture on an ephemeral port.  It binds all local
/// interfaces so a LAN/Tailscale candidate is a genuine URLSession connection,
/// while remaining isolated from the production daemon on 9900.  Like
/// agentmirrord it answers `/pair/identify` (paired routes must prove the host
/// before the client sends its token) and the `/ws` WebSocket on one port.
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
        guard let dynamicPort = NWEndpoint.Port(rawValue: 0) else {
            throw Issue23TestError.listenerDidNotBecomeReady
        }
        listener = try NWListener(using: .tcp, on: dynamicPort)
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
            self.readRequest(on: connection, buffer: Data())
        }
        connection.start(queue: queue)
    }

    /// One HTTP request: `POST /pair/identify` is answered and closed; a WebSocket upgrade switches
    /// the connection to frames.
    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            let buffer = buffer + (data ?? Data())
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { connection.cancel() } else { self.readRequest(on: connection, buffer: buffer) }
                return
            }
            let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let body = buffer[headerEnd.upperBound...]
            if lines.first?.hasPrefix("POST /pair/identify ") == true {
                let length = Int(headers["content-length"] ?? "") ?? 0
                guard body.count >= length else { self.readRequest(on: connection, buffer: buffer); return }
                self.answerIdentify(Data(body.prefix(length)), on: connection)
            } else if let key = headers["sec-websocket-key"] {
                let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
                let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    self.readFrames(on: connection, buffer: Data(body))
                })
            } else {
                connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                                isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func answerIdentify(_ body: Data, on connection: NWConnection) {
        var status = "400 Bad Request", json = #"{"code":"bad_request"}"#
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let nonce = object["nonce"] as? String, let destination = object["dest_ip"] as? String,
           (object["host_id"] as? String).map({ $0 == hostID }) ?? true {
            let mac = HostIdentityProbe.identifyMAC(token: token, hostID: hostID, nonce: nonce, boundIP: destination, boundPort: Int(port))
            status = "200 OK"
            json = #"{"v":1,"host_id":"\#(hostID)","name":"\#(name)","bound":"\#(destination):\#(port)","mac":"\#(mac)"}"#
        }
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)"
        connection.send(content: Data(response.utf8), isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Client frames are masked (RFC 6455 §5.3); the only text frame that matters is `auth`.
    private func readFrames(on connection: NWConnection, buffer: Data) {
        var buffer = buffer
        while let frame = Self.takeFrame(from: &buffer) {
            switch frame.opcode {
            case 0x1:
                guard let token = Self.token(from: frame.payload) else { continue }
                Task { await self.state.record(token: token) }
                let ok = token == self.token
                let reply = ok ? #"{"v":1,"type":"auth_ack","payload":{"ok":true}}"#
                               : #"{"v":1,"type":"auth_ack","payload":{"ok":false,"reason":"unauthorized"}}"#
                connection.send(content: Self.serverFrame(opcode: 0x1, Data(reply.utf8)), completion: .contentProcessed { _ in
                    if !ok { connection.cancel() }
                })
                if !ok { return }
            case 0x9:
                connection.send(content: Self.serverFrame(opcode: 0xA, frame.payload), completion: .idempotent)
            case 0x8:
                connection.cancel(); return
            default:
                continue
            }
        }
        let pending = buffer
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, error == nil, !(complete && (data?.isEmpty ?? true)) else { connection.cancel(); return }
            self.readFrames(on: connection, buffer: pending + (data ?? Data()))
        }
    }

    private static func takeFrame(from buffer: inout Data) -> (opcode: UInt8, payload: Data)? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        var length = Int(bytes[1] & 0x7F), offset = 2
        if length == 126 { guard bytes.count >= 4 else { return nil }; length = Int(bytes[2]) << 8 | Int(bytes[3]); offset = 4 }
        else if length == 127 { guard bytes.count >= 10 else { return nil }; length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }; offset = 10 }
        let masked = bytes[1] & 0x80 != 0
        let mask = masked ? Array(bytes.dropFirst(offset).prefix(4)) : []
        offset += masked ? 4 : 0
        guard bytes.count >= offset + length else { return nil }
        let payload = Data(bytes[offset..<offset + length].enumerated().map { masked ? $0.element ^ mask[$0.offset % 4] : $0.element })
        buffer = Data(bytes[(offset + length)...])
        return (bytes[0] & 0x0F, payload)
    }

    private static func serverFrame(opcode: UInt8, _ payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 { frame.append(UInt8(payload.count)) }
        else { frame.append(126); frame.append(UInt8(payload.count >> 8)); frame.append(UInt8(payload.count & 0xFF)) }
        return frame + payload
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

private actor LiveRoutePairingState {
    private var authCount = 0
    private var commandTexts: [String] = []

    func recordAuth() { authCount += 1 }
    func recordCommand(_ text: String) { commandTexts.append(text) }
    func authenticationCount() -> Int { authCount }
    func hasCommand(containing value: String) -> Bool { commandTexts.contains { $0.contains(value) } }
}

/// Two real WebSocket listeners for one paired host.  Each listener is bound
/// by Network.framework to a private ephemeral port on all local interfaces,
/// while the client dials the actual Tailscale/LAN addresses discovered above.
private final class LiveRoutePairingFixture: @unchecked Sendable {
    let hostID: String
    let token: String
    let tailnet: LiveRouteListener
    let lan: LiveRouteListener

    init(hostID: String, token: String, tailnetHost: String, lanHost: String) throws {
        self.hostID = hostID
        self.token = token
        self.tailnet = try LiveRouteListener(hostID: hostID, token: token, host: tailnetHost, route: .tailnet)
        self.lan = try LiveRouteListener(hostID: hostID, token: token, host: lanHost, route: .lan)
    }

    var routes: [ApprovedEndpoint] { [tailnet.endpoint, lan.endpoint] }

    func start() async throws {
        try await tailnet.start()
        try await lan.start()
    }

    func stop() {
        tailnet.stop()
        lan.stop()
    }

    static func nonLoopbackPrivateIPv4Addresses() -> [String] {
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
            guard let route = ApprovedEndpoint.route(forHost: host), route != .loopback,
                  !result.contains(host) else { continue }
            result.append(host)
        }
        return result.sorted {
            let lhs = ApprovedEndpoint.route(forHost: $0)?.rawValue ?? Int.max
            let rhs = ApprovedEndpoint.route(forHost: $1)?.rawValue ?? Int.max
            return (lhs, $0) < (rhs, $1)
        }
    }
}

private final class LiveRouteListener: @unchecked Sendable {
    let hostID: String
    let token: String
    let host: String
    let route: ApprovedEndpoint.Route
    private(set) var port: UInt16 = 0
    private(set) var endpoint: ApprovedEndpoint!

    private let listener: NWListener
    private let queue: DispatchQueue
    private let state = LiveRoutePairingState()
    private let lock = NSLock()
    private var blocked = false
    private var connections: [NWConnection] = []
    private var tailnetBridge: TailnetTCPBridge?

    init(hostID: String, token: String, host: String, route: ApprovedEndpoint.Route) throws {
        self.hostID = hostID
        self.token = token
        self.host = host
        self.route = route
        guard let dynamicPort = NWEndpoint.Port(rawValue: 0) else { throw Issue23TestError.listenerDidNotBecomeReady }
        let parameters = NWParameters.tcp
        if route == .tailnet {
            // The backend stays on loopback; TailnetTCPBridge binds the real
            // 100.x address so URLSession exercises the actual route.
            parameters.requiredInterfaceType = .loopback
        } else if let name = Self.interfaceName(for: host), let interface = Self.interface(named: name) {
            parameters.requiredInterface = interface
        } else {
            parameters.requiredInterfaceType = .wiredEthernet
        }
        listener = try NWListener(using: parameters, on: dynamicPort)
        queue = DispatchQueue(label: "corral.issue23.live-\(route)")
    }

    func start() async throws {
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state { fputs("Issue23 live route fixture failed: \(error)\n", stderr) }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        for _ in 0..<200 {
            if case .ready = listener.state, let port = listener.port?.rawValue {
                if route == .tailnet {
                    let bridge = try TailnetTCPBridge(host: host, backendPort: port)
                    try bridge.start()
                    tailnetBridge = bridge
                    self.port = bridge.port
                } else {
                    self.port = port
                }
                self.endpoint = try ApprovedEndpoint(host: host, port: Int(port), pairingHostID: hostID)
                if route == .tailnet {
                    self.endpoint = try ApprovedEndpoint(host: host, port: Int(self.port), pairingHostID: hostID)
                }
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Issue23TestError.listenerDidNotBecomeReady
    }

    func stop() {
        tailnetBridge?.stop()
        tailnetBridge = nil
        listener.cancel()
        lock.lock(); let active = connections; connections.removeAll(); lock.unlock()
        active.forEach { $0.cancel() }
    }

    func blockAndDrop() {
        lock.lock(); blocked = true; let active = connections; lock.unlock()
        active.forEach { $0.cancel() }
    }

    func allow() { lock.lock(); blocked = false; lock.unlock() }
    func authenticationCount() async -> Int { await state.authenticationCount() }
    func waitForCommand(containing value: String) async -> Bool {
        for _ in 0..<300 {
            if await state.hasCommand(containing: value) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await state.hasCommand(containing: value)
    }

    private func accepting() -> Bool { lock.lock(); defer { lock.unlock() }; return !blocked }

    private static func interfaceName(for host: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var storage = sockaddr_in()
            memcpy(&storage, address, MemoryLayout<sockaddr_in>.size)
            let value = withUnsafePointer(to: &storage.sin_addr) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: 4) { bytes in
                    (0..<4).map { String(bytes[$0]) }.joined(separator: ".")
                }
            }
            if value == host, let name = item.pointee.ifa_name { return String(cString: name) }
        }
        return nil
    }

    private static func interface(named name: String) -> NWInterface? {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "corral.issue23.interface-lookup")
        let semaphore = DispatchSemaphore(value: 0)
        let box = InterfaceLookupBox()
        monitor.pathUpdateHandler = { path in
            box.set(path.availableInterfaces.first { $0.name == name })
            semaphore.signal()
        }
        monitor.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 1)
        monitor.cancel()
        return box.value
    }

    private func accept(_ connection: NWConnection) {
        lock.lock(); connections.append(connection); lock.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .ready = state, let self, let connection else { return }
            guard self.accepting() else { connection.cancel(); return }
            self.readRequest(on: connection, buffer: Data())
        }
        connection.start(queue: queue)
    }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, error == nil, self.accepting() else { connection.cancel(); return }
            let buffer = buffer + (data ?? Data())
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { connection.cancel() } else { self.readRequest(on: connection, buffer: buffer) }
                return
            }
            let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            let lines = header.components(separatedBy: "\r\n")
            let headers = Dictionary(uniqueKeysWithValues: lines.dropFirst().compactMap { line -> (String, String)? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            })
            let body = buffer[headerEnd.upperBound...]
            if lines.first?.hasPrefix("GET /pair/whoami ") == true {
                let json = #"{"v":1,"host_id":"\#(self.hostID)","name":"Issue 23 Live Fixture","port":\#(self.port),"addresses":["\#(self.host)"]}"#
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)"
                connection.send(content: Data(response.utf8), isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if lines.first?.hasPrefix("POST /pair/identify ") == true {
                let length = Int(headers["content-length"] ?? "") ?? 0
                guard body.count >= length else {
                    self.readRequest(on: connection, buffer: buffer)
                    return
                }
                self.answerIdentify(Data(body.prefix(length)), on: connection)
                return
            }
            guard let key = headers["sec-websocket-key"] else { connection.cancel(); return }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                self.readFrames(on: connection, buffer: Data(buffer[headerEnd.upperBound...]))
            })
        }
    }

    private func answerIdentify(_ body: Data, on connection: NWConnection) {
        var status = "400 Bad Request"
        var json = #"{"code":"bad_request"}"#
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let nonce = object["nonce"] as? String,
           let destination = object["dest_ip"] as? String,
           (object["host_id"] as? String).map({ $0 == hostID }) ?? true {
            let mac = HostIdentityProbe.identifyMAC(token: token, hostID: hostID, nonce: nonce,
                                                    boundIP: destination, boundPort: Int(port))
            status = "200 OK"
            json = #"{"v":1,"host_id":"\#(hostID)","name":"Issue 23 Live Fixture","bound":"\#(destination):\#(port)","mac":"\#(mac)"}"#
        }
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)"
        connection.send(content: Data(response.utf8), isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func readFrames(on connection: NWConnection, buffer: Data) {
        var buffer = buffer
        while let frame = Self.takeFrame(from: &buffer) {
            switch frame.opcode {
            case 0x1:
                let text = String(decoding: frame.payload, as: UTF8.self)
                guard let object = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] else { continue }
                if object["type"] as? String == "auth" {
                    awaitRecordAuth()
                    let payload = object["payload"] as? [String: Any]
                    let ok = payload?["token"] as? String == token
                    let reply = ok ? #"{"v":1,"type":"auth_ack","payload":{"ok":true}}"# : #"{"v":1,"type":"auth_ack","payload":{"ok":false,"reason":"unauthorized"}}"#
                    connection.send(content: Self.serverFrame(opcode: 0x1, Data(reply.utf8)), completion: .contentProcessed { _ in
                        if !ok { connection.cancel() }
                    })
                    if !ok { return }
                } else {
                    Task { await state.recordCommand(text) }
                }
            case 0x9:
                connection.send(content: Self.serverFrame(opcode: 0xA, frame.payload), completion: .idempotent)
            case 0x8:
                connection.cancel(); return
            default: break
            }
        }
        let pending = buffer
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, error == nil, !(complete && (data?.isEmpty ?? true)) else { connection.cancel(); return }
            self.readFrames(on: connection, buffer: pending + (data ?? Data()))
        }
    }

    private func awaitRecordAuth() { Task { await state.recordAuth() } }

    private static func takeFrame(from buffer: inout Data) -> (opcode: UInt8, payload: Data)? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        var length = Int(bytes[1] & 0x7F), offset = 2
        if length == 126 { guard bytes.count >= 4 else { return nil }; length = Int(bytes[2]) << 8 | Int(bytes[3]); offset = 4 }
        else if length == 127 { guard bytes.count >= 10 else { return nil }; length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }; offset = 10 }
        let masked = bytes[1] & 0x80 != 0
        let mask = masked ? Array(bytes.dropFirst(offset).prefix(4)) : []
        offset += masked ? 4 : 0
        guard bytes.count >= offset + length else { return nil }
        let payload = Data(bytes[offset..<offset + length].enumerated().map { masked ? $0.element ^ mask[$0.offset % 4] : $0.element })
        buffer = Data(bytes[(offset + length)...])
        return (bytes[0] & 0x0F, payload)
    }

    private static func serverFrame(opcode: UInt8, _ payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 { frame.append(UInt8(payload.count)) }
        else { frame.append(126); frame.append(UInt8(payload.count >> 8)); frame.append(UInt8(payload.count & 0xFF)) }
        return frame + payload
    }
}

private final class InterfaceLookupBox: @unchecked Sendable {
    private let lock = NSLock()
    private var interface: NWInterface?

    func set(_ interface: NWInterface?) { lock.withLock { self.interface = interface } }
    var value: NWInterface? { lock.withLock { interface } }
}

/// Binds the real local Tailscale IPv4 and forwards bytes to the loopback
/// Network.framework listener.  NWListener cannot bind a utun address on this
/// macOS host, while a real TCP listener can; the client still dials the
/// actual 100.x endpoint and the relay remains private to this test.
private final class TailnetTCPBridge: @unchecked Sendable {
    private let host: String
    private let backendPort: UInt16
    private(set) var port: UInt16 = 0
    private var process: Process?

    init(host: String, backendPort: UInt16) throws {
        self.host = host
        self.backendPort = backendPort
    }

    func start() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", Self.script, host, String(backendPort)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        var data = Data()
        while !data.contains(0x0A) {
            // The relay prints a short decimal port line.  Reading a larger
            // fixed size here can block forever because Pipe only returns
            // once bytes are available and the child intentionally keeps its
            // stdout open for the lifetime of the listener.
            let chunk = output.fileHandleForReading.readData(ofLength: 1)
            guard !chunk.isEmpty else { process.terminate(); throw Issue23TestError.listenerDidNotBecomeReady }
            data.append(chunk)
        }
        guard let line = String(data: data, encoding: .utf8),
              let first = line.split(whereSeparator: \.isNewline).first,
              let port = UInt16(String(first)) else {
            process.terminate()
            throw Issue23TestError.listenerDidNotBecomeReady
        }
        self.process = process
        self.port = port
    }

    func stop() {
        guard let process else { return }
        if process.isRunning { process.terminate() }
        self.process = nil
    }

    private static let script = #"""
import socket
import sys
import threading

host = sys.argv[1]
backend = int(sys.argv[2])
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind((host, 0))
server.listen(32)
print(server.getsockname()[1], flush=True)

def pump(source, target):
    try:
        while True:
            data = source.recv(65536)
            if not data:
                break
            target.sendall(data)
    except OSError:
        pass
    finally:
        try:
            source.close()
        except OSError:
            pass
        try:
            target.close()
        except OSError:
            pass

while True:
    try:
        client, _ = server.accept()
        backend_socket = socket.create_connection(("127.0.0.1", backend), timeout=2)
    except OSError:
        try:
            client.close()
        except (NameError, OSError):
            pass
        continue
    threading.Thread(target=pump, args=(client, backend_socket), daemon=True).start()
    threading.Thread(target=pump, args=(backend_socket, client), daemon=True).start()
"""#
}
