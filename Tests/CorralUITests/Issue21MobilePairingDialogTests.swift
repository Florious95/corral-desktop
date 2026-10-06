import AppKit
import CorralContracts
import CorralProtocol
import CorralServices
import CorralUI
import Foundation
import Network
import XCTest
@testable import CorralApp

/// Issue 21 red gate: the user-visible pairing entry must open the native QR
/// dialog.  A Toast is not a pairing surface and must not satisfy this test.
@MainActor
final class Issue21MobilePairingDialogTests: XCTestCase {
    func testIsolatedWhoAmIFixtureAdvertisesPhoneReachableCandidates() async throws {
        let fixture = try Issue21PairWhoAmIFixture()
        try await fixture.start()
        defer { fixture.stop() }

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:9919/pair/whoami"))
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["v"] as? Int, 1)
        XCTAssertEqual(body["host_id"] as? String, fixture.hostID)
        XCTAssertEqual(body["addresses"] as? [String], ["100.64.0.1", "192.168.1.50", "127.0.0.1"])
        let requestPaths = await fixture.requestPaths()
        XCTAssertEqual(requestPaths, ["/pair/whoami"])
    }

    func testPairingEntryPresentsQRCodeDialogAndMobileV1Payload() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-issue21-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let whoAmIFixture = try Issue21PairWhoAmIFixture()
        try await whoAmIFixture.start()
        defer { whoAmIFixture.stop() }

        let link = Issue21UnusedSessionLink()
        let workspaceStore = try CorralWorkspaceStore(applicationSupportDirectory: root.appendingPathComponent("workspace"))
        let preferencesStore = try UserPreferencesStore(applicationSupportDirectory: root.appendingPathComponent("preferences"))
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: Issue21EmptyDeviceRepository(),
            credentialVault: Issue21EmptyCredentialVault(),
            sessionLink: link,
            deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: link),
            workspaceStore: workspaceStore,
            userPreferencesStore: preferencesStore,
            initialWorkspaceState: await workspaceStore.snapshot(),
            initialUserPreferences: await preferencesStore.snapshot(),
            environment: [
                "CORRAL_NATIVE_ENDPOINT": whoAmIFixture.endpoint,
                "CORRAL_NATIVE_TOKEN": "issue21-private-daemon-token",
                "CORRAL_NATIVE_BACKGROUND": "1"
            ]
        )
        let window = try XCTUnwrap(coordinator.windowController.window)
        defer {
            coordinator.devicesCardPanel?.orderOut(nil)
            window.close()
            ToastManager.shared.dismissCurrent()
        }

        // This is an isolated AppKit window; it does not connect to or activate
        // the production client.  Drive the same sidebar device entry used by
        // the packaged app, then invoke the actual pair row's AX press action.
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        let devicesButton = coordinator.workspaceView.sidebar.devicesButton
        XCTAssertTrue(devicesButton.accessibilityPerformPress() || devicesButton.isEnabled,
                      "The real devices entry must be pressable")

        let opened = await waitUntil { coordinator.devicesCardPanel?.isVisible == true }
        XCTAssertTrue(opened, "The devices popover must open before pairing can be selected")
        let panel = try XCTUnwrap(coordinator.devicesCardPanel)
        let devices = try XCTUnwrap(panel.contentViewController as? DevicesPopoverViewController)
        XCTAssertTrue(devices.pairRow.accessibilityPerformPress(), "The pairing row must expose AXPress")

        let dialog = await waitForPairingDialog(in: coordinator)
        if dialog == nil, let toast = ToastManager.shared.currentToast {
            XCTFail("Pairing entry produced a Toast instead of a QR dialog: \(toast.messageLabel.stringValue)")
            return
        }
        let pairingDialog = try XCTUnwrap(dialog, "Pairing entry must present PairingDialogViewController, not a placeholder")
        let receivedWhoAmI = await whoAmIFixture.waitForWhoAmI()
        XCTAssertTrue(receivedWhoAmI, "The dialog must obtain metadata from the isolated daemon endpoint")
        let requestPaths = await whoAmIFixture.requestPaths()
        XCTAssertEqual(requestPaths, ["/pair/whoami"])
        let text = try XCTUnwrap(pairingDialog.pairingText, "The visible pairing dialog must contain one QR payload")
        let data = try XCTUnwrap(text.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["v"] as? Int, 1, "The mobile contract is v1 JSON")
        let hostID = try XCTUnwrap(object["host_id"] as? String, "QR payload must contain the daemon host_id")
        XCTAssertEqual(hostID, whoAmIFixture.hostID)
        let token = try XCTUnwrap(object["token"] as? String, "QR payload must contain the daemon token")
        XCTAssertEqual(token, "issue21-private-daemon-token", "QR must use the daemon credential, not a placeholder")
        let candidates = try XCTUnwrap(object["candidates"] as? [String], "QR payload must contain endpoint candidates")
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.hasPrefix("ws://") || $0.hasPrefix("wss://") })
        XCTAssertTrue(candidates.contains(whoAmIFixture.tailnetURL), "QR must advertise a phone-reachable Tailnet candidate")
        XCTAssertTrue(candidates.contains(whoAmIFixture.lanURL), "QR must advertise a phone-reachable LAN candidate")
        XCTAssertEqual(URL(string: candidates.first ?? "")?.host, "100.64.0.1", "The primary QR endpoint must not be a phone-local loopback")
        if let loopbackIndex = candidates.firstIndex(where: { URL(string: $0)?.host == "127.0.0.1" }) {
            XCTAssertGreaterThan(loopbackIndex, 0, "127.0.0.1 may only be a lower-priority diagnostic fallback")
        }
        XCTAssertEqual(object["url"] as? String, candidates.first)
        XCTAssertNotNil(pairingDialog.qrImage, "The QR image itself must be rendered")

        // Token is allowed in the machine-readable QR payload, but not in
        // ordinary labels, toast text, or any other visible plaintext field.
        let visiblePlaintext = descendants(of: window.contentView)
            .compactMap { view -> String? in
                guard let field = view as? NSTextField, !(field is NSSecureTextField) else { return nil }
                return field.stringValue
            }
            .joined(separator: "\n")
        XCTAssertFalse(visiblePlaintext.contains(token), "The sensitive token must not leak into visible plaintext UI")
        XCTAssertFalse((ToastManager.shared.currentToast?.messageLabel.stringValue ?? "").contains(token))
    }

    private func waitForPairingDialog(in coordinator: CorralApplicationCoordinator) async -> PairingDialogViewController? {
        for _ in 0..<50 {
            // `activeDialog` is intentionally private in production. Reflection
            // keeps this gate attached to the real coordinator-owned dialog
            // without adding a product-only testing escape hatch.
            if let value = Mirror(reflecting: coordinator).children.first(where: { $0.label == "activeDialog" })?.value,
               let dialog = value as? PairingDialogViewController {
                return dialog
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}

@MainActor
private func descendants(of root: NSView?) -> [NSView] {
    guard let root else { return [] }
    return [root] + root.subviews.flatMap(descendants)
}

private actor Issue21EmptyDeviceRepository: DeviceRepositoryProtocol {
    func listDevices() async throws -> [DeviceRecord] { [] }
    func save(_ device: DeviceRecord) async throws {}
    func delete(id: DeviceID) async throws {}
}

private actor Issue21EmptyCredentialVault: DeviceCredentialVault {
    func store(_ secret: String, for handle: CredentialHandle) async throws {}
    func resolve(_ handle: CredentialHandle) async throws -> String? { nil }
    func delete(_ handle: CredentialHandle) async throws {}
}

private struct Issue21UnusedSessionLink: SessionLinkProtocol {
    func connect(to endpoint: ApprovedEndpoint, deviceID: DeviceID, credential: CredentialHandle) async throws -> AuthenticatedConnection {
        throw SessionLinkFailure.disconnected
    }

    func eventStream() async throws -> any SessionEventStream { Issue21NeverEventStream() }
    func send(_ command: ClientCommand) async throws -> CommandSendReceipt { throw SessionLinkFailure.disconnected }
    func disconnect() async {}
}

private struct Issue21NeverEventStream: SessionEventStream {
    var budget: SessionEventStreamBudget {
        SessionEventStreamBudget(maximumBufferedBytes: 1_024, maximumBufferedEvents: 1, maximumBufferedControls: 1)
    }

    func next() async throws -> SessionEventEnvelope? { nil }
}

private actor Issue21PairWhoAmIState {
    private var paths: [String] = []

    func record(path: String) { paths.append(path) }
    func requestPaths() -> [String] { paths }
    func hasWhoAmI() -> Bool { paths.contains("/pair/whoami") }
}

/// A real loopback HTTP fixture. It binds the development-only 9919 port and
/// never listens on or connects to production 9900.
private final class Issue21PairWhoAmIFixture: @unchecked Sendable {
    let hostID = "issue21-host-fixture"
    let endpoint = "ws://127.0.0.1:9919/ws"
    let tailnetURL = "ws://100.64.0.1:9919/ws"
    let lanURL = "ws://192.168.1.50:9919/ws"

    private let listener: NWListener
    private let queue = DispatchQueue(label: "corral.issue21.pair-whoami")
    private let state = Issue21PairWhoAmIState()

    init() throws {
        guard let port = NWEndpoint.Port(rawValue: 9919) else { throw Issue21PairWhoAmIFixtureError.invalidPort }
        listener = try NWListener(using: .tcp, on: port)
    }

    func start() async throws {
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                fputs("Issue21 /pair/whoami fixture failed: \(error)\n", stderr)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        for _ in 0..<100 {
            if case .ready = listener.state { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Issue21PairWhoAmIFixtureError.notReady
    }

    func stop() { listener.cancel() }

    func requestPaths() async -> [String] { await state.requestPaths() }

    func waitForWhoAmI() async -> Bool {
        for _ in 0..<100 {
            if await state.hasWhoAmI() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await state.hasWhoAmI()
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
            guard let self, let connection, let data,
                  let request = String(data: data, encoding: .utf8),
                  let requestLine = request.components(separatedBy: "\r\n").first,
                  let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) else {
                connection?.cancel()
                return
            }
            Task { await self.state.record(path: path) }
            let body = #"{"v":1,"host_id":"issue21-host-fixture","name":"issue21-daemon","port":9919,"addresses":["100.64.0.1","192.168.1.50","127.0.0.1"]}"#
            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

private enum Issue21PairWhoAmIFixtureError: Error {
    case invalidPort
    case notReady
}
