import AppKit
import CorralContracts
import CorralProtocol
import CorralServices
import CorralUI
import Foundation
import XCTest
@testable import CorralApp

/// Issue 352: "全部设备" must keep every selected host on its own authenticated link at once.
/// Two fake links stand in for two hosts; nothing here dials a real endpoint. Both hosts list the
/// same tmux reference (`%1`) on purpose, so a key that loses its host would collide.
@MainActor
final class Issue352MultiHostLinkPoolTests: XCTestCase {
    private let alpha = DeviceRecord(id: DeviceID("issue352-alpha"), name: "Alpha",
                                     endpoint: try! ApprovedEndpoint(host: "127.0.0.1", port: 9941),
                                     credential: CredentialHandle("issue352-alpha"))
    private let beta = DeviceRecord(id: DeviceID("issue352-beta"), name: "Beta",
                                    endpoint: try! ApprovedEndpoint(host: "127.0.0.1", port: 9942),
                                    credential: CredentialHandle("issue352-beta"))

    func testAllDevicesConnectsEveryHostAndRoutesTheRemotePaneToItsOwnLink() async throws {
        let harness = try await Harness(devices: [alpha, beta], explicitEndpoint: alpha)
        defer { harness.close() }
        let coordinator = harness.coordinator
        await coordinator.start()
        XCTAssertTrue(coordinator.connected)
        let alphaDials = await harness.seed.dialedDeviceIDs
        XCTAssertEqual(alphaDials, [alpha.id], "The explicit endpoint's host is dialed on the injected link")

        let reference = try SessionReference("%1")
        try await harness.seed.emit(.control(.listing(listing(sequence: 1, reference: reference, name: "alpha-agent", directory: "/hosts/alpha"))))
        let sidebar = coordinator.workspaceView.sidebar
        let alphaListed = await waitUntil { sidebar.agents.contains { $0.name == "alpha-agent" } }
        XCTAssertTrue(alphaListed)

        // The card opens with every host checked; that selection must dial the second host.
        sidebar.devicesButton.performClick(nil)
        let popover = try await devicesPopover(in: coordinator)
        let bothReady = await waitUntil { popover.readyDeviceIDs == [self.alpha.id, self.beta.id] }
        XCTAssertTrue(bothReady, "Both hosts must be live: \(popover.selectionSummary.stringValue)")
        XCTAssertEqual(popover.selectionSummary.stringValue, "2 台设备 · 2 台已连接")
        XCTAssertTrue(popover.allDevicesRow.isChecked)
        let betaLink = try XCTUnwrap(harness.madeLinks.first, "The second host gets its own link")
        let betaDials = await betaLink.dialedDeviceIDs
        let betaTokens = await betaLink.tokens
        XCTAssertEqual(betaDials, [beta.id])
        XCTAssertEqual(betaTokens, ["issue352-beta-token"], "Each host is dialed with its own credential")
        let seedDials = await harness.seed.dialedDeviceIDs
        XCTAssertEqual(seedDials, [alpha.id], "The first host's link is never redialed for the second")

        try await betaLink.emit(.control(.listing(listing(sequence: 1, reference: reference, name: "beta-agent", directory: "/hosts/beta"))))
        // The auto-opened Alpha session scopes the agent list to Alpha's directory; All Spaces lists every host.
        let betaSpaceListed = await waitUntil { sidebar.spaces.contains { $0.name == "beta" } }
        XCTAssertTrue(betaSpaceListed)
        sidebar.selectSpace(id: CorralSidebarSpace.allSpacesID)
        let merged = await waitUntil {
            sidebar.agents.contains { $0.name == "alpha-agent" } && sidebar.agents.contains { $0.name == "beta-agent" }
                && sidebar.spaces.contains { $0.name == "alpha" } && sidebar.spaces.contains { $0.name == "beta" }
        }
        XCTAssertTrue(merged, "Both hosts' sessions and Spaces are listed together")

        // A newer catalog from one host replaces only that host's sessions.
        try await harness.seed.emit(.control(.listing(listing(sequence: 2, reference: reference, name: "alpha-agent", directory: "/hosts/alpha"))))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(sidebar.agents.contains { $0.name == "beta-agent" }, "Alpha's catalog must not erase Beta's session")

        let betaAgent = try XCTUnwrap(sidebar.agents.first { $0.name == "beta-agent" })
        let betaSessionID = try XCTUnwrap(betaAgent.sessionID)
        coordinator.workspaceView.onSelectAgent?(betaSessionID, .doubleClick)
        let betaKey = SessionKey(deviceID: beta.id, reference: reference)
        let rendered = await waitUntil {
            guard let view = coordinator.terminalView(for: betaKey), !view.isHidden else { return false }
            return Self.text(of: view).contains("BETA-LIVE")
        }
        XCTAssertTrue(rendered, "Beta's pane is attached, visible and painted from Beta's own link")
        XCTAssertEqual(coordinator.workspaceState.visibleSessionID, betaSessionID)
        let betaSubscribed = await betaLink.subscribedReferences
        XCTAssertEqual(betaSubscribed, [reference])
        let betaSpace = try XCTUnwrap(sidebar.spaces.first { $0.name == "beta" })
        let spaceKept = await waitUntil { sidebar.selectedSpaceID == betaSpace.id }
        XCTAssertTrue(spaceKept, "Opening Beta's session selects Beta's own directory, not All Spaces")

        // Keystrokes in Beta's pane go to Beta's link only.
        let view = try XCTUnwrap(coordinator.terminalView(for: betaKey))
        coordinator.windowController.window?.makeFirstResponder(view)
        let alphaInputsBefore = await harness.seed.inputs.count
        coordinator.send(source: view, data: Array("ls\r".utf8)[...])
        let typed = await waitUntil { await betaLink.inputs.contains(Data("ls\r".utf8)) }
        XCTAssertTrue(typed, "Input reaches the host the pane belongs to")
        let alphaInputsAfter = await harness.seed.inputs.count
        XCTAssertEqual(alphaInputsAfter, alphaInputsBefore, "No keystroke leaks to the other host")

        // Deselecting a host releases only that host.
        popover.setDevice(beta.id, selected: false)
        let released = await waitUntil {
            await betaLink.disconnects > 0 && !sidebar.agents.contains { $0.name == "beta-agent" }
        }
        XCTAssertTrue(released)
        XCTAssertTrue(sidebar.agents.contains { $0.name == "alpha-agent" })
        XCTAssertEqual(popover.readyDeviceIDs, [alpha.id])
        XCTAssertTrue(coordinator.connected)
        await coordinator.stop()
    }

    func testLaunchDialsEverySavedHostBeforeTheDevicesCardIsOpened() async throws {
        let harness = try await Harness(devices: [alpha, beta], explicitEndpoint: nil)
        defer { harness.close() }
        let coordinator = harness.coordinator
        await coordinator.start()
        let bothDialed = await waitUntil {
            let seed = await harness.seed.dialedDeviceIDs
            let made = await harness.madeLinks.first?.dialedDeviceIDs ?? []
            return Set(seed + made) == [self.alpha.id, self.beta.id]
        }
        XCTAssertTrue(bothDialed, "Until a selection is made every saved host is selected, so every one is dialed")

        coordinator.workspaceView.sidebar.devicesButton.performClick(nil)
        let popover = try await devicesPopover(in: coordinator)
        let bothReady = await waitUntil { popover.readyDeviceIDs == [self.alpha.id, self.beta.id] }
        XCTAssertTrue(bothReady)
        XCTAssertEqual(popover.selectionSummary.stringValue, "2 台设备 · 2 台已连接")
        await coordinator.stop()
    }

    private func listing(sequence: UInt64, reference: SessionReference, name: String, directory: String) -> SessionListing {
        SessionListing(requestID: 1, sequence: sequence, workspaces: [
            WorkspaceRecord(workingDirectory: directory, sessionCount: 1, aggregateState: .idle, sessions: [
                WireSessionRecord(reference: reference, name: name, workingDirectory: directory, state: .idle, rows: 24, columns: 80)
            ])
        ])
    }

    private static func text(of view: CorralNativeTerminalView) -> String {
        let terminal = view.getTerminal()
        return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n")
    }

    private func devicesPopover(in coordinator: CorralApplicationCoordinator) async throws -> DevicesPopoverViewController {
        for _ in 0..<200 {
            if let controller = coordinator.devicesCardPanel?.contentViewController as? DevicesPopoverViewController,
               controller.devices.count == 2 { return controller }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw XCTSkip("The Devices card did not load")
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ predicate: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }
}

@MainActor
private final class Harness {
    let coordinator: CorralApplicationCoordinator
    let seed = PoolLink(snapshotText: "ALPHA-LIVE")
    private let factory = PoolLinkFactory()
    var madeLinks: [PoolLink] { factory.made }
    private let root: URL

    init(devices: [DeviceRecord], explicitEndpoint: DeviceRecord?) async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("corral-issue352-\(UUID().uuidString)", isDirectory: true)
        let workspace = try CorralWorkspaceStore(applicationSupportDirectory: root.appendingPathComponent("workspace"))
        let preferences = try UserPreferencesStore(applicationSupportDirectory: root.appendingPathComponent("preferences"))
        var environment = ["CORRAL_NATIVE_BACKGROUND": "1", "CORRAL_NATIVE_TEST_MODE": "1", "HOME": root.path]
        if let explicitEndpoint {
            environment["CORRAL_NATIVE_ENDPOINT"] = explicitEndpoint.endpoint.url.absoluteString
            environment["CORRAL_NATIVE_TOKEN"] = explicitEndpoint.credential.rawValue + "-token"
        }
        let seed = seed
        let factory = factory
        let tokens = Dictionary(uniqueKeysWithValues: devices.map { ($0.credential, $0.credential.rawValue + "-token") })
        coordinator = CorralApplicationCoordinator(
            deviceRepository: PoolDeviceRepository(records: devices),
            credentialVault: PoolCredentialVault(values: tokens),
            sessionLink: seed,
            deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: seed),
            workspaceStore: workspace,
            userPreferencesStore: preferences,
            initialWorkspaceState: await workspace.snapshot(),
            initialUserPreferences: await preferences.snapshot(),
            environment: environment,
            makeSessionLink: { factory.make() }
        )
        coordinator.windowController.window?.orderBack(nil)
    }

    func close() {
        coordinator.devicesCardPanel?.orderOut(nil)
        coordinator.windowController.window?.close()
        ToastManager.shared.dismissCurrent()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class PoolLinkFactory {
    private(set) var made: [PoolLink] = []
    func make() -> PoolLink {
        let link = PoolLink(snapshotText: "BETA-LIVE")
        made.append(link)
        return link
    }
}

private actor PoolLink: SessionLinkProtocol {
    private let stream = PoolEventStream()
    private let instance = LinkInstanceID()
    private let snapshotText: String
    private var authenticated: AuthenticatedConnection?
    private var endpoint: ApprovedEndpoint?
    private var ordinal: UInt64 = 0
    private var epoch: UInt64 = 0
    private(set) var dialedDeviceIDs: [DeviceID] = []
    private(set) var tokens: [String] = []
    private(set) var subscribedReferences: [SessionReference] = []
    private(set) var inputs: [Data] = []
    private(set) var disconnects = 0

    init(snapshotText: String) { self.snapshotText = snapshotText }

    func connect(to endpoint: ApprovedEndpoint, deviceID: DeviceID, credential: CredentialHandle) async throws -> AuthenticatedConnection {
        epoch += 1
        let connection = try AuthenticatedConnection(linkInstanceID: instance, deviceID: deviceID, connectionEpoch: ConnectionEpoch(epoch))
        authenticated = connection
        self.endpoint = endpoint
        dialedDeviceIDs.append(deviceID)
        tokens.append(credential.rawValue)
        return connection
    }

    func activeEndpoint() async -> ApprovedEndpoint? { authenticated == nil ? nil : endpoint }
    func eventStream() async throws -> any SessionEventStream { stream }

    func send(_ command: ClientCommand) async throws -> CommandSendReceipt {
        guard authenticated != nil else { throw SessionLinkFailure.unauthenticated }
        var requestID: UInt32?
        switch command {
        case let .list(id): requestID = id
        case let .input(request):
            requestID = request.sequence
            if case let .bytes(bytes) = request.payload { inputs.append(bytes) }
        case let .subscribe(reference, _):
            subscribedReferences.append(reference)
            try await emit(.frame(.snapshot(reference: reference, ansi: Data("\u{1b}[2J\u{1b}[H\(snapshotText)\r\n".utf8))))
        default: break
        }
        return CommandSendReceipt(requestID: requestID, socketWritten: true)
    }

    func disconnect() async {
        authenticated = nil
        disconnects += 1
    }

    func emit(_ event: SessionEvent) async throws {
        guard let authenticated else { throw SessionLinkFailure.disconnected }
        ordinal += 1
        let origin = SessionEventOrigin(linkInstanceID: authenticated.linkInstanceID, deviceID: authenticated.deviceID,
                                        connectionEpoch: authenticated.connectionEpoch, receiveOrdinal: ReceiveOrdinal(ordinal))
        await stream.yield(try SessionEventEnvelope(origin: origin, wireByteCount: 0, event: event))
    }
}

/// Like the real link's mailbox, the stream outlives a disconnect.
private actor PoolEventStream: SessionEventStream {
    private var queued: [SessionEventEnvelope] = []
    private var waiter: CheckedContinuation<SessionEventEnvelope?, Never>?

    var budget: SessionEventStreamBudget {
        SessionEventStreamBudget(maximumBufferedBytes: 1_000_000, maximumBufferedEvents: 128, maximumBufferedControls: 32)
    }

    func next() async throws -> SessionEventEnvelope? {
        if !queued.isEmpty { return queued.removeFirst() }
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
}

private actor PoolDeviceRepository: DeviceRepositoryProtocol {
    private var records: [DeviceRecord]
    init(records: [DeviceRecord]) { self.records = records }
    func listDevices() async throws -> [DeviceRecord] { records }
    func save(_ device: DeviceRecord) async throws {
        if let index = records.firstIndex(where: { $0.id == device.id }) { records[index] = device } else { records.append(device) }
    }
    func delete(id: DeviceID) async throws { records.removeAll { $0.id == id } }
}

private actor PoolCredentialVault: DeviceCredentialVault {
    private var values: [CredentialHandle: String]
    init(values: [CredentialHandle: String]) { self.values = values }
    func store(_ secret: String, for handle: CredentialHandle) async throws { values[handle] = secret }
    func resolve(_ handle: CredentialHandle) async throws -> String? { values[handle] }
    func delete(_ handle: CredentialHandle) async throws { values.removeValue(forKey: handle) }
}
