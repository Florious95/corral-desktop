import AppKit
import CorralContracts
import CorralMetalTerminal
import CorralProtocol
import CorralServices
import CorralUI
import XCTest
@testable import CorralApp

@MainActor
final class CorralApplicationCoordinatorTests: XCTestCase {
    func testNewAgentMenuItemIsBoundToCommandN() throws {
        let delegate = CorralAppDelegate()
        let mainMenu = delegate.makeMainMenu()

        let fileMenu = try XCTUnwrap(mainMenu.items.first(where: { $0.title == "File" })?.submenu)
        let item = try XCTUnwrap(fileMenu.items.first(where: { $0.identifier?.rawValue == "corral.newagent.menu" }))
        XCTAssertEqual(item.keyEquivalent, "n")
        XCTAssertTrue(item.keyEquivalentModifierMask.contains(.command))
        XCTAssertTrue(item.target === delegate)
        XCTAssertNotNil(item.action)
    }

    func testUnconfiguredCoordinatorDoesNotConnect() async throws {
        let link = RecordingSessionLink()
        let atlas = GlyphAtlasPool.shared
        let coordinator = try await makeCoordinator(link: link, atlas: atlas, environment: [:])

        await coordinator.start()

        XCTAssertFalse(coordinator.connected)
        let connectCount = await link.connectCount()
        XCTAssertEqual(connectCount, 0)
        let preferences = UserPreferences(theme: .light, fontFamily: "Menlo, monospace", fontSize: 16, followDirectory: true, sidebarCollapsed: true)
        try await coordinator.updateUserPreferences(preferences)
        XCTAssertEqual(coordinator.userPreferences, preferences)
        let persistedPreferences = await coordinator.userPreferencesStore.snapshot()
        XCTAssertEqual(persistedPreferences, preferences)
        XCTAssertTrue(coordinator.workspaceView.sidebar.isHidden)
        await coordinator.stop()
    }

    func testWorkspaceChromeActionsPersistThroughCoordinator() async throws {
        let link = RecordingSessionLink()
        let coordinator = try await makeCoordinator(link: link, atlas: .shared, environment: [:])
        await coordinator.start()

        coordinator.workspaceView.onCreateTab?()
        let created = await waitUntil { coordinator.workspaceState.tabs.count == 2 }
        XCTAssertTrue(created)
        let newTabID = coordinator.workspaceState.activeTabID
        coordinator.workspaceView.tabBar.onRenameTab?(newTabID, "Review")
        let renamed = await waitUntil { coordinator.workspaceState.tabs.first(where: { $0.id == newTabID })?.title == "Review" }
        XCTAssertTrue(renamed)
        coordinator.workspaceView.tabBar.onCloseTab?(newTabID)
        let closed = await waitUntil { coordinator.workspaceState.tabs.count == 1 }
        XCTAssertTrue(closed)

        coordinator.workspaceView.tabBar.sidebarToggleButton.performClick(nil)
        let collapsed = await waitUntil { await coordinator.userPreferencesStore.snapshot().sidebarCollapsed }
        XCTAssertTrue(collapsed)
        XCTAssertTrue(coordinator.workspaceView.isSidebarCollapsed)
        await coordinator.stop()
    }

    func testTelemetryReceiptRefreshesPeriodicallyWithoutConnecting() async throws {
        let link = RecordingSessionLink()
        let atlas = GlyphAtlasPool.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("corral-native-periodic-\(UUID().uuidString).json")
        let coordinator = try await makeCoordinator(link: link, atlas: atlas, environment: ["CORRAL_NATIVE_TELEMETRY_OUT": url.path])

        await coordinator.start()
        let initial = try Data(contentsOf: url)
        let initialDate = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date)
        try await Task.sleep(for: .milliseconds(650))
        let refreshed = try Data(contentsOf: url)
        let refreshedDate = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date)

        XCTAssertFalse(initial.isEmpty)
        XCTAssertFalse(refreshed.isEmpty)
        XCTAssertGreaterThan(refreshedDate, initialDate)
        XCTAssertFalse(try JSONDecoder().decode(CorralApplicationTelemetry.self, from: refreshed).connected)
        await coordinator.stop()
        try? FileManager.default.removeItem(at: url)
    }

    func testLoopback9900ConnectsThroughFakeLink() async throws {
        let link = RecordingSessionLink()
        let coordinator = try await makeCoordinator(link: link, atlas: .shared, environment: [
            "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9900/ws",
            "CORRAL_NATIVE_TOKEN": "fixture-only-token"
        ])

        await coordinator.start()

        XCTAssertTrue(coordinator.connected)
        XCTAssertTrue(coordinator.workspaceView.sidebar.devices.contains(where: { $0.isOnline }))
        XCTAssertNil(coordinator.lastConnectionError)
        let connectCount = await link.connectCount()
        XCTAssertEqual(connectCount, 1)
        await coordinator.stop()
    }

    func testEnvironmentTokenOverridesStoredCredential() async throws {
        let handle = CredentialHandle("keychain-item:production-test")
        let endpoint = try ApprovedEndpoint(host: "127.0.0.1", port: 9900)
        let repository = FixedDeviceRepository([DeviceRecord(
            id: DeviceID("production-device"),
            name: "Local manual acceptance",
            endpoint: endpoint,
            credential: handle
        )])
        let vault = TestDeviceCredentialVault()
        try await vault.store("stale-keychain-token", for: handle)
        let link = RecordingSessionLink()
        let coordinator = try await makeCoordinator(
            link: link,
            atlas: .shared,
            environment: [
                "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9900/ws",
                "CORRAL_NATIVE_TOKEN": "environment-token"
            ],
            deviceRepository: repository,
            credentialVault: vault
        )

        await coordinator.start()

        let forwardedCredential = await link.lastConnectedCredential()
        XCTAssertTrue(forwardedCredential?.rawValue == "environment-token", "explicit environment token must reach SessionLink auth")
        XCTAssertTrue(coordinator.connected)
        await coordinator.stop()
    }

    func testLive9919VerticalSliceConnectsListsRendersAndEchoesInput() async throws {
        guard let tokenPath = ProcessInfo.processInfo.environment["CORRAL_NATIVE_E2E_TOKEN_FILE"] else {
            throw XCTSkip("Set CORRAL_NATIVE_E2E_TOKEN_FILE to the isolated 9919 fixture token file")
        }
        let tokenURL = URL(fileURLWithPath: tokenPath).standardizedFileURL
        guard tokenURL.path == "/tmp/corral-gw-test-home/test-token",
              FileManager.default.isReadableFile(atPath: tokenURL.path) else {
            throw XCTSkip("Only the isolated fixture token at /tmp/corral-gw-test-home/test-token is accepted")
        }
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw XCTSkip("The isolated fixture token is empty") }

        let endpointText = "ws://127.0.0.1:9919/ws"
        let link = ObservingSessionLink(URLSessionSessionLink())
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-native-live-e2e-\(UUID().uuidString)", isDirectory: true)
        let telemetryURL = supportDirectory.appendingPathComponent("telemetry.json")
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let coordinator = try await makeCoordinator(link: link, atlas: .shared, environment: [
            "CORRAL_NATIVE_ENDPOINT": endpointText,
            "CORRAL_NATIVE_TOKEN": token,
            "CORRAL_NATIVE_BACKGROUND": "1",
            "CORRAL_NATIVE_TELEMETRY_OUT": telemetryURL.path
        ], supportDirectory: supportDirectory)
        guard let window = coordinator.windowController.window else {
            return XCTFail("coordinator must own a real window")
        }
        window.orderBack(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        let initialWindowFrame = window.frame

        await coordinator.start()
        let connectedEndpoint = await link.connectedEndpoint()
        let connectedCredential = await link.connectedCredential()
        XCTAssertEqual(connectedEndpoint?.url.absoluteString, endpointText)
        XCTAssertTrue(connectedCredential?.rawValue == token, "fixture token must reach URLSessionSessionLink auth without being logged")
        XCTAssertTrue(coordinator.connected)
        XCTAssertTrue(coordinator.workspaceView.sidebar.devices.contains(where: \.isOnline), "successful auth_ack must immediately mark the device online")

        let listed = await waitUntil(timeout: .seconds(12)) {
            coordinator.sessionCount == 6 && coordinator.workspaceView.sidebar.agents.count == 6
        }
        let eventKinds = await link.observedEvents().map { envelope -> String in
            switch envelope.event {
            case .connectionChanged: "connection"
            case .failed: "failed"
            case .control(.listing): "listing"
            case .control(.inputAck): "input_ack"
            case .frame(.snapshot): "snapshot"
            case .frame(.delta): "delta"
            default: "other"
            }
        }
        let listSent = await link.sentCommands().contains { if case .list = $0 { true } else { false } }
        XCTAssertTrue(listed, "the real 9919 listing must populate six sidebar agents; count=\(coordinator.sessionCount), agents=\(coordinator.workspaceView.sidebar.agents.count), connected=\(coordinator.connected), listSent=\(listSent), error=\(coordinator.lastConnectionError ?? "none"), events=\(eventKinds)")
        guard listed,
              let agent = coordinator.workspaceView.sidebar.agents.first(where: { $0.name.contains("static-long-text") }) else {
            await coordinator.stop()
            window.close()
            return
        }

        coordinator.workspaceView.sidebar.onSelectAgent?(agent.id)
        let subscribed = await waitUntil(timeout: .seconds(8)) {
            coordinator.subscribedSessionIDs.count == 1 && coordinator.stageView.activeInputSession != nil
        }
        XCTAssertTrue(subscribed, "opening a listed sidebar session must persist the tab and subscribe")
        XCTAssertEqual(window.frame, initialWindowFrame, "selecting an Agent must preserve native window geometry")
        guard subscribed, let session = coordinator.stageView.activeInputSession else {
            await coordinator.stop()
            window.close()
            return
        }

        let renderedSnapshot = await waitUntil(timeout: .seconds(12)) {
            coordinator.stageView.presentedSubmissions.contains {
                $0.session == session && self.snapshotText($0.snapshot).contains("STATIC-LINE-")
            }
        }
        XCTAssertTrue(renderedSnapshot, "the real SNAPSHOT must traverse SwiftTerm and reach the Metal stage")
        guard let initial = coordinator.stageView.presentedSubmissions.first(where: { $0.session == session }) else {
            await coordinator.stop()
            window.close()
            return
        }
        XCTAssertTrue(initial.snapshot.isValid)
        XCTAssertTrue(snapshotText(initial.snapshot).contains("STATIC-LINE-"))
        let initialGeneration = initial.snapshot.generation
        let snapshotReceived = await waitUntil(timeout: .seconds(4)) {
            await link.observedEvents().contains { envelope in
                if case let .frame(.snapshot(reference, _)) = envelope.event { return reference == session.reference }
                return false
            }
        }
        XCTAssertTrue(snapshotReceived)

        guard let inputView = coordinator.stageView.inputView(for: session) else {
            await coordinator.stop()
            window.close()
            return XCTFail("the active real session must own a text input view")
        }
        let marker = "NATIVE-E2E-\(UUID().uuidString)"
        inputView.insertText(marker, replacementRange: NSRange(location: NSNotFound, length: 0))
        inputView.insertText("\r", replacementRange: NSRange(location: NSNotFound, length: 0))

        let inputSent = await waitUntil(timeout: .seconds(8)) {
            let payloads = await link.sentCommands().compactMap { command -> ClientInputPayload? in
                guard case let .input(request) = command, request.reference == session.reference else { return nil }
                return request.payload
            }
            return payloads.contains(.text(marker, attachmentPath: nil)) && payloads.contains(.bareEnter)
        }
        XCTAssertTrue(inputSent, "typed text and Enter must become real ClientCommand.input messages")
        let ackReceived = await waitUntil(timeout: .seconds(8)) {
            guard let acknowledgement = coordinator.lastInputAcknowledgement else { return false }
            return acknowledgement.succeeded && acknowledgement.sequence >= 2
        }
        XCTAssertTrue(ackReceived, "the coordinator must receive a successful input_ack")
        let deltaReceived = await waitUntil(timeout: .seconds(8)) {
            await link.observedEvents().contains { envelope in
                if case let .frame(.delta(reference, _)) = envelope.event { return reference == session.reference }
                return false
            }
        }
        XCTAssertTrue(deltaReceived, "PTY echo must arrive as an incremental DELTA frame")
        let echoed = await waitUntil(timeout: .seconds(8)) {
            guard let submission = coordinator.stageView.presentedSubmissions.first(where: { $0.session == session }) else { return false }
            return submission.snapshot.generation > initialGeneration && self.snapshotText(submission.snapshot).contains(marker)
        }
        XCTAssertTrue(echoed, "the DELTA must update the rendered terminal grid with the typed text")

        await coordinator.stop()
        window.close()
    }

    /// 08-split regression: a restored split whose server panes are stale (69×1) must be re-sized from each
    /// pane's own 6pt-gap projection, and every later layout change (ratio, close) must publish new grids.
    func testRestoredSplitPublishesEveryPaneGridAndFollowsLayoutChanges() async throws {
        let references = [try SessionReference("split-left"), try SessionReference("split-right")]
        let records = references.enumerated().map { index, reference in
            WireSessionRecord(reference: reference, name: "Split \(index)", workingDirectory: "/fixture/split", state: .idle, rows: 1, columns: 69)
        }
        let link = RecordingSessionLink()
        let atlas = GlyphAtlasPool.shared
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-native-split-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let workspaceStore = try CorralWorkspaceStore(applicationSupportDirectory: supportDirectory)
        let userPreferencesStore = try UserPreferencesStore(applicationSupportDirectory: supportDirectory)
        let deviceID = DeviceID("corral-native-development-endpoint")
        let ids = references.map { SessionID("\(deviceID.rawValue.utf8.count):\(deviceID.rawValue)\($0.rawValue)") }
        _ = try await workspaceStore.smartOpenSession(ids[0], gesture: .doubleClick)
        _ = try await workspaceStore.splitSession(ids[1], target: ids[0], edge: .right)
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: EmptyDeviceRepository(),
            credentialVault: TestDeviceCredentialVault(),
            sessionLink: link,
            deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: link),
            renderer: try SharedMetalTerminalRenderer(glyphAtlas: atlas),
            workspaceStore: workspaceStore,
            userPreferencesStore: userPreferencesStore,
            initialWorkspaceState: await workspaceStore.snapshot(),
            initialUserPreferences: await userPreferencesStore.snapshot(),
            glyphAtlas: atlas,
            environment: ["CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws", "CORRAL_NATIVE_TOKEN": "fixture-only-token", "CORRAL_NATIVE_BACKGROUND": "1"]
        )
        guard let window = coordinator.windowController.window else { return XCTFail("coordinator must own a real window") }
        window.orderBack(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let stage = coordinator.stageView.bounds.size
        XCTAssertEqual(stage, NSSize(width: 1400 - 280, height: 860 - 38))
        await coordinator.start()
        // Real order: the window settles its stage geometry long before the first listing round-trip.
        let settled = await waitUntil { coordinator.stageView.currentGeometry?.0 == stage }
        XCTAssertTrue(settled)
        try await Task.sleep(for: .milliseconds(200))
        try await link.emit(.control(.listing(SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(workingDirectory: "/fixture/split", sessionCount: 2, aggregateState: .idle, sessions: records)
        ]))))

        let cell = coordinator.stageView.terminalCellSize
        func grid(width: CGFloat, height: CGFloat) -> GridSize {
            GridSize(rows: Int(height / cell.height), columns: Int(width / cell.width))
        }
        func lastSentGrid(_ reference: SessionReference) async -> GridSize? {
            await link.commands().reversed().lazy.compactMap { command -> GridSize? in
                switch command {
                case let .subscribe(ref, size) where ref == reference: size
                case let .resize(ref, size) where ref == reference: size
                default: nil
                }
            }.first
        }
        // 1120pt stage, 6pt gap: usable 1114 → 557 | 557.
        let half = grid(width: 557, height: stage.height)
        let restored = await waitUntil {
            let left = await lastSentGrid(references[0]), right = await lastSentGrid(references[1])
            return left == half && right == half
        }
        let restoredLeft = await lastSentGrid(references[0]), restoredRight = await lastSentGrid(references[1])
        XCTAssertTrue(restored, "both panes must be sized from their own viewport, got \(String(describing: restoredLeft)) / \(String(describing: restoredRight)), want \(half)")

        // A transient collapsed stage (window/Space churn) must never leave a pane committed at a 1-row grid.
        coordinator.stageView.configureStage(sizeInPoints: NSSize(width: stage.width, height: 20), backingScale: 2)
        coordinator.stageView.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let afterChurnLeft = await lastSentGrid(references[0]), afterChurnRight = await lastSentGrid(references[1])
        XCTAssertEqual(afterChurnLeft, half)
        XCTAssertEqual(afterChurnRight, half)

        await coordinator.updateWorkspaceSplitRatio(path: "root", ratio: 0.3)
        // floor(1114 × 0.3) = 334 | 780.
        let resized = await waitUntil {
            let left = await lastSentGrid(references[0]), right = await lastSentGrid(references[1])
            return left == grid(width: 334, height: stage.height) && right == grid(width: 780, height: stage.height)
        }
        XCTAssertTrue(resized, "a ratio change must re-publish both pane grids")

        await coordinator.closeWorkspacePane(ids[1])
        let promoted = await waitUntil { await lastSentGrid(references[0]) == grid(width: stage.width, height: stage.height) }
        XCTAssertTrue(promoted, "the surviving sibling must absorb the whole stage and be resized to it")
        let remoteCloses = await link.commands().filter { if case .closeSession = $0 { true } else { false } }.count
        XCTAssertEqual(remoteCloses, 0, "closing a pane never terminates its Agent")

        await coordinator.stop()
        window.close()
    }

    func testGoldenFramesDriveThreeRealMetalPanesAndInputRouting() async throws {
        let fixture = try GoldenFrameFixture.load()
        let codec = ProtocolV1Codec()
        let goldenSnapshot = try codec.decodeBinaryFrame(fixture.snapshot)
        guard case let .snapshot(goldenReference, ansi) = goldenSnapshot else {
            return XCTFail("golden fixture must contain a SNAPSHOT frame")
        }
        let goldenDelta = try codec.decodeBinaryFrame(fixture.delta)
        guard case .delta = goldenDelta else { return XCTFail("golden fixture must contain a DELTA frame") }

        let references = [goldenReference, try SessionReference("fixture-pane-2"), try SessionReference("fixture-pane-3")]
        let records = references.enumerated().map { index, reference in
            WireSessionRecord(
                reference: reference,
                name: "Fixture \(index + 1)",
                workingDirectory: "/fixture/workspace",
                state: .idle,
                rows: 24,
                columns: 80
            )
        }
        let link = RecordingSessionLink()
        let atlas = GlyphAtlasPool.shared
        let renderer = try SharedMetalTerminalRenderer(glyphAtlas: atlas)
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-native-coordinator-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let workspaceStore = try CorralWorkspaceStore(applicationSupportDirectory: supportDirectory)
        let userPreferencesStore = try UserPreferencesStore(applicationSupportDirectory: supportDirectory)
        let fixtureDeviceID = DeviceID("corral-native-development-endpoint")
        let workspaceSessionIDs = references.map {
            SessionID("\(fixtureDeviceID.rawValue.utf8.count):\(fixtureDeviceID.rawValue)\($0.rawValue)")
        }
        _ = try await workspaceStore.smartOpenSession(workspaceSessionIDs[0], gesture: .doubleClick)
        _ = try await workspaceStore.splitSession(workspaceSessionIDs[1], target: workspaceSessionIDs[0], edge: .right)
        _ = try await workspaceStore.splitSession(workspaceSessionIDs[2], target: workspaceSessionIDs[0], edge: .bottom)
        let initialWorkspaceState = await workspaceStore.snapshot()
        let initialUserPreferences = await userPreferencesStore.snapshot()
        let telemetryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-native-telemetry-\(UUID().uuidString).json")
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: EmptyDeviceRepository(),
            credentialVault: TestDeviceCredentialVault(),
            sessionLink: link,
            deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: link),
            renderer: renderer,
            workspaceStore: workspaceStore,
            userPreferencesStore: userPreferencesStore,
            initialWorkspaceState: initialWorkspaceState,
            initialUserPreferences: initialUserPreferences,
            glyphAtlas: atlas,
            environment: [
                "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
                "CORRAL_NATIVE_TOKEN": "fixture-only-token",
                "CORRAL_NATIVE_BACKGROUND": "1",
                "CORRAL_NATIVE_TELEMETRY_OUT": telemetryURL.path
            ],
            maximumVisiblePanes: 3
        )
        var createdSession: SessionKey?
        var closedSession: SessionKey?
        coordinator.onAgentCreated = { createdSession = $0 }
        coordinator.onAgentClosed = { closedSession = $0 }
        guard let window = coordinator.windowController.window else { return XCTFail("coordinator must own a real window") }
        window.setFrame(NSRect(x: 40, y: 40, width: 1500, height: 1000), display: false)
        window.orderBack(nil)
        XCTAssertFalse(window.isKeyWindow)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        coordinator.stageView.configureStage(sizeInPoints: NSSize(width: 1200, height: 800), backingScale: 1)

        await coordinator.start()
        XCTAssertTrue(coordinator.backgroundMode)
        let connectCount = await link.connectCount()
        XCTAssertEqual(connectCount, 1)
        let listSent = await waitUntil { await link.commands().contains { if case .list = $0 { true } else { false } } }
        XCTAssertTrue(listSent)
        let authAck = try codec.decodeControlMessage(Data(#"{"v":1,"type":"auth_ack","payload":{"ok":true,"agent_launchers":[{"provider":"pi","display_name":"Pi","supports_bypass":true,"naming":"cli"},{"provider":"codex","display_name":"Codex","supports_bypass":true,"naming":"cli"},{"provider":"cursor","display_name":"Cursor","supports_bypass":false,"naming":"cli"},{"provider":"grok","display_name":"Grok","supports_bypass":false,"naming":"cli"}]}}"#.utf8))
        guard case let .authAck(ok, reason, launchers) = authAck else {
            return XCTFail("The real auth_ack fixture must decode with its advertised launchers")
        }
        XCTAssertTrue(ok)
        XCTAssertNil(reason)
        XCTAssertEqual(launchers.map(\.provider), ["pi", "codex", "cursor", "grok"])
        try await link.emit(.control(authAck))
        let launcherReceived = await waitUntil { coordinator.availableAgentLaunchers == launchers }
        XCTAssertTrue(launcherReceived)
        XCTAssertEqual(coordinator.availableAgentLaunchers.count, 4)

        coordinator.showNewAgentDialog()
        let newAgentSheet = try XCTUnwrap(window.attachedSheet as? NSPanel)
        XCTAssertEqual(newAgentSheet.identifier?.rawValue, "corral.newagent.window")
        let newAgentDialog = try XCTUnwrap(newAgentSheet.contentViewController as? NewAgentDialogViewController)
        XCTAssertEqual(newAgentDialog.launchers, launchers.map {
            CorralAgentLauncher(provider: $0.provider, displayName: $0.displayName, supportsBypass: $0.supportsBypass)
        })
        newAgentDialog.cancelButton?.performClick(nil)
        let newAgentSheetDismissed = await waitUntil { window.attachedSheet == nil }
        XCTAssertTrue(newAgentSheetDismissed)

        let listing = SessionListing(
            requestID: 1,
            sequence: 1,
            workspaces: [WorkspaceRecord(
                workingDirectory: "/fixture/workspace",
                sessionCount: records.count,
                aggregateState: .idle,
                sessions: records
            )]
        )
        try await link.emit(.control(.listing(listing)))
        let subscribed = await waitUntil {
            await link.commands().filter { if case .subscribe = $0 { true } else { false } }.count == 3
        }
        XCTAssertTrue(subscribed)
        XCTAssertEqual(coordinator.workspaceView.stageContainer.splitView.splitterCount, 2)
        XCTAssertEqual(coordinator.workspaceView.stageContainer.splitView.projection.panes.map(\.sessionID), [workspaceSessionIDs[0], workspaceSessionIDs[2], workspaceSessionIDs[1]])

        try await link.emit(.frame(goldenSnapshot))
        for reference in references.dropFirst() {
            let frame = try codec.encodeBinaryFrame(.snapshot(reference: reference, ansi: ansi))
            try await link.emit(.frame(codec.decodeBinaryFrame(frame)))
        }
        try await link.emit(.frame(goldenDelta))

        let rendered = await waitUntil {
            coordinator.telemetry.renderedPaneCount == 3 && coordinator.telemetry.nonEmptyLineCount >= 45
        }
        XCTAssertTrue(rendered)
        let submitted = await waitUntil { coordinator.telemetry.metalSubmissionCount > 0 }
        XCTAssertTrue(submitted)
        XCTAssertGreaterThan(coordinator.telemetry.atlasPageCount, 0)

        let paneKey = SessionKey(deviceID: fixtureDeviceID, reference: references[1])
        let commandsBeforeSwitch = await link.commands()
        let subscribedBeforeSwitch = commandsBeforeSwitch.filter { if case .subscribe = $0 { true } else { false } }.count
        let resizeBeforeSwitch = commandsBeforeSwitch.filter { if case .resize = $0 { true } else { false } }.count
        let targetSidebarID = try XCTUnwrap(
            coordinator.workspaceView.sidebar.devices.flatMap(\.sessions).first(where: { $0.name == "Fixture 2" })?.id
        )
        coordinator.selectSidebarSession(id: targetSidebarID)
        XCTAssertEqual(coordinator.stageView.activeInputSession, paneKey)
        let commandsAfterSwitch = await link.commands()
        XCTAssertEqual(commandsAfterSwitch.filter { if case .subscribe = $0 { true } else { false } }.count, subscribedBeforeSwitch)
        XCTAssertEqual(commandsAfterSwitch.filter { if case .resize = $0 { true } else { false } }.count, resizeBeforeSwitch)

        let inputView = try XCTUnwrap(coordinator.stageView.inputView(for: paneKey))
        inputView.insertText("typed", replacementRange: NSRange(location: NSNotFound, length: 0))
        let inputSent = await waitUntil {
            await link.commands().contains { command in
                guard case let .input(request) = command else { return false }
                return request.reference == paneKey.reference && request.payload == .text("typed", attachmentPath: nil)
            }
        }
        XCTAssertTrue(inputSent)
        let userInputCount = await link.commands().filter { if case .input = $0 { true } else { false } }.count
        try await link.emit(.frame(.delta(reference: references[0], ansi: Data("\u{1b}[5n".utf8))))
        let localReplyProduced = await waitUntil { coordinator.discardedAutoReplyByteCount > 0 }
        XCTAssertTrue(localReplyProduced)
        let inputCountAfterTerminalReply = await link.commands().filter { if case .input = $0 { true } else { false } }.count
        XCTAssertEqual(inputCountAfterTerminalReply, userInputCount)
        let stillPresented = await waitUntil {
            coordinator.telemetry.renderedPaneCount == 3 && coordinator.telemetry.nonEmptyLineCount >= 45
        }
        XCTAssertTrue(stillPresented)

        await coordinator.flushTelemetry()
        let receiptData = try Data(contentsOf: telemetryURL)
        let receipt = try JSONDecoder().decode(CorralApplicationTelemetry.self, from: receiptData)
        XCTAssertEqual(receipt.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(receipt.connected)
        XCTAssertEqual(receipt.sessionCount, 3)
        XCTAssertEqual(receipt.subscribedSessionIDs.count, 3)
        XCTAssertEqual(receipt.renderedPaneCount, 3)
        XCTAssertGreaterThanOrEqual(receipt.nonEmptyLineCount, 45)
        XCTAssertGreaterThan(receipt.metalSubmissionCount, 0)
        XCTAssertGreaterThan(receipt.atlasPageCount, 0)
        let idleSubmissionCount = coordinator.telemetry.metalSubmissionCount
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(coordinator.telemetry.metalSubmissionCount, idleSubmissionCount)

        let createRequestID = try await coordinator.createAgent(
            workspace: "/fixture/workspace",
            anchorReference: references[0],
            provider: "codex",
            name: "Created Agent",
            bypass: true
        )
        let createCommand = ClientCommand.createAgent(CreateAgentRequest(
            requestID: createRequestID,
            workspace: "/fixture/workspace",
            anchorReference: references[0],
            provider: "codex",
            name: "Created Agent",
            bypass: true
        ))
        let commandsAfterCreate = await link.commands()
        XCTAssertTrue(commandsAfterCreate.contains(createCommand))
        try await link.emit(.control(.createAgentResult(CreateAgentResult(
            requestID: createRequestID,
            ok: true,
            reference: try SessionReference("created-agent"),
            name: "Created Agent",
            naming: .cli
        ))))
        let createResultReceived = await waitUntil { coordinator.lastCreateAgentResult?.requestID == createRequestID }
        XCTAssertTrue(createResultReceived)
        XCTAssertEqual(coordinator.telemetry.sessionCount, records.count, "create ACK does not synthesize a client-side session")

        let paneKeyToClose = SessionKey(deviceID: fixtureDeviceID, reference: references[2])
        let closeRequestID = try await coordinator.closeAgent(paneKeyToClose)
        let commandsAfterClose = await link.commands()
        XCTAssertTrue(commandsAfterClose.contains(.closeSession(CloseSessionRequest(requestID: closeRequestID, reference: references[2]))))
        try await link.emit(.control(.closeSessionResult(CloseSessionResult(requestID: closeRequestID, ok: true))))
        let closeResultReceived = await waitUntil { coordinator.lastCloseSessionResult?.requestID == closeRequestID }
        XCTAssertTrue(closeResultReceived)
        XCTAssertEqual(coordinator.telemetry.sessionCount, records.count, "close ACK waits for authoritative listing removal")

        let createdRecord = WireSessionRecord(reference: try SessionReference("created-agent"), name: "Created Agent", workingDirectory: "/fixture/workspace", state: .working, rows: 24, columns: 80, provider: "codex", activity: "working", health: "normal")
        let refreshedListing = SessionListing(requestID: 1, sequence: 2, workspaces: [WorkspaceRecord(
            workingDirectory: "/fixture/workspace",
            sessionCount: records.count,
            aggregateState: .idle,
            sessions: Array(records.dropLast()) + [createdRecord]
        )])
        try await link.emit(.control(.listing(refreshedListing)))
        let staleSessionRemoved = await waitUntil(timeout: .seconds(2)) {
            let commands = await link.commands()
            return coordinator.telemetry.sessionCount == records.count &&
                coordinator.telemetry.subscribedSessionIDs.count == records.count &&
                createdSession?.reference == (try? SessionReference("created-agent")) &&
                closedSession == paneKeyToClose &&
                commands.contains(.unsubscribe(reference: references[2]))
        }
        XCTAssertTrue(staleSessionRemoved)
        XCTAssertEqual(createdSession?.reference, try SessionReference("created-agent"))
        XCTAssertEqual(closedSession, paneKeyToClose)
        try await link.emit(.control(.listDelta(SessionListDelta(sequence: 3, removedReferences: [references[1]]))))
        let deltaRemovalApplied = await waitUntil {
            let commands = await link.commands()
            return coordinator.telemetry.sessionCount == records.count - 1 &&
                coordinator.telemetry.subscribedSessionIDs.count == records.count - 1 &&
                coordinator.stageView.activeInputSession?.reference == (try? SessionReference("created-agent")) &&
                commands.contains(.unsubscribe(reference: references[1]))
        }
        XCTAssertTrue(deltaRemovalApplied)
        XCTAssertEqual(coordinator.stageView.activeInputSession?.reference, try SessionReference("created-agent"))
        let remoteCloseCountBeforePresentationClose = await link.commands().filter { if case .closeSession = $0 { true } else { false } }.count
        await coordinator.closeWorkspaceTab(id: coordinator.workspaceState.activeTabID)
        await coordinator.closeWorkspacePane(workspaceSessionIDs[0])
        let remoteCloseCountAfterPresentationClose = await link.commands().filter { if case .closeSession = $0 { true } else { false } }.count
        XCTAssertEqual(remoteCloseCountAfterPresentationClose, remoteCloseCountBeforePresentationClose, "closing a tab or pane must not terminate an Agent")

        await coordinator.stop()
        window.close()
        try? FileManager.default.removeItem(at: telemetryURL)
    }

    private func makeCoordinator(
        link: any SessionLinkProtocol,
        atlas: GlyphAtlasPool,
        environment: [String: String],
        supportDirectory: URL? = nil,
        deviceRepository: any DeviceRepositoryProtocol = EmptyDeviceRepository(),
        credentialVault: any DeviceCredentialVault = TestDeviceCredentialVault()
    ) async throws -> CorralApplicationCoordinator {
        let supportDirectory = supportDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-native-coordinator-store-\(UUID().uuidString)", isDirectory: true)
        let workspaceStore = try CorralWorkspaceStore(applicationSupportDirectory: supportDirectory)
        let userPreferencesStore = try UserPreferencesStore(applicationSupportDirectory: supportDirectory)
        return CorralApplicationCoordinator(
            deviceRepository: deviceRepository,
            credentialVault: credentialVault,
            sessionLink: link,
            deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: link),
            renderer: try SharedMetalTerminalRenderer(glyphAtlas: atlas),
            workspaceStore: workspaceStore,
            userPreferencesStore: userPreferencesStore,
            initialWorkspaceState: await workspaceStore.snapshot(),
            initialUserPreferences: await userPreferencesStore.snapshot(),
            glyphAtlas: atlas,
            environment: environment
        )
    }

    private func snapshotText(_ snapshot: TerminalGridSnapshot) -> String {
        snapshot.cells.compactMap { cell in
            guard case let .cluster(text, _) = cell.content else { return nil }
            return text
        }.joined()
    }

    private func waitUntil(
        timeout: Duration = .seconds(8),
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }
}

private actor TestDeviceCredentialVault: DeviceCredentialVault {
    private var secrets: [CredentialHandle: String] = [:]
    func store(_ secret: String, for handle: CredentialHandle) async throws { secrets[handle] = secret }
    func resolve(_ handle: CredentialHandle) async throws -> String? { secrets[handle] }
    func delete(_ handle: CredentialHandle) async throws { secrets.removeValue(forKey: handle) }
}

private struct GoldenFrameFixture {
    let snapshot: Data
    let delta: Data

    private struct Envelope: Decodable {
        struct Frames: Decodable {
            struct Frame: Decodable {
                let rawHex: String
                enum CodingKeys: String, CodingKey { case rawHex = "raw_hex" }
            }
            let snapshot: Frame
            let delta: Frame
        }
        let frames: Frames
    }

    static func load() throws -> Self {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtureURL = repositoryRoot.appendingPathComponent("TestSupport/Fixtures/golden-frames.json")
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fixtureURL))
        return Self(
            snapshot: try Data(hex: envelope.frames.snapshot.rawHex),
            delta: try Data(hex: envelope.frames.delta.rawHex)
        )
    }
}

private extension Data {
    init(hex: String) throws {
        guard hex.count.isMultiple(of: 2) else { throw CocoaError(.fileReadCorruptFile) }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw CocoaError(.fileReadCorruptFile) }
            data.append(byte)
            index = next
        }
        self = data
    }
}

private actor ObservingSessionLink: SessionLinkProtocol {
    private let base: any SessionLinkProtocol
    private var endpoint: ApprovedEndpoint?
    private var credential: CredentialHandle?
    private var commands: [ClientCommand] = []
    private var events: [SessionEventEnvelope] = []

    init(_ base: any SessionLinkProtocol) { self.base = base }

    func connect(to endpoint: ApprovedEndpoint, deviceID: DeviceID, credential: CredentialHandle) async throws -> AuthenticatedConnection {
        self.endpoint = endpoint
        self.credential = credential
        return try await base.connect(to: endpoint, deviceID: deviceID, credential: credential)
    }

    func eventStream() async throws -> any SessionEventStream {
        ObservingSessionEventStream(base: try await base.eventStream(), observer: self)
    }

    func send(_ command: ClientCommand) async throws -> CommandSendReceipt {
        commands.append(command)
        return try await base.send(command)
    }

    func disconnect() async { await base.disconnect() }
    func connectedEndpoint() -> ApprovedEndpoint? { endpoint }
    func connectedCredential() -> CredentialHandle? { credential }
    func sentCommands() -> [ClientCommand] { commands }
    func observedEvents() -> [SessionEventEnvelope] { events }
    func record(_ event: SessionEventEnvelope) { events.append(event) }
}

private struct ObservingSessionEventStream: SessionEventStream {
    let base: any SessionEventStream
    let observer: ObservingSessionLink

    var budget: SessionEventStreamBudget {
        get async { await base.budget }
    }

    func next() async throws -> SessionEventEnvelope? {
        guard let event = try await base.next() else { return nil }
        await observer.record(event)
        return event
    }
}

private actor FixedDeviceRepository: DeviceRepositoryProtocol {
    private let devices: [DeviceRecord]
    init(_ devices: [DeviceRecord]) { self.devices = devices }
    func listDevices() async throws -> [DeviceRecord] { devices }
    func save(_ device: DeviceRecord) async throws {}
    func delete(id: DeviceID) async throws {}
}

private actor EmptyDeviceRepository: DeviceRepositoryProtocol {
    func listDevices() async throws -> [DeviceRecord] { [] }
    func save(_ device: DeviceRecord) async throws {}
    func delete(id: DeviceID) async throws {}
}

private actor RecordingSessionLink: SessionLinkProtocol {
    private let stream = RecordingEventStream()
    private var authenticated: AuthenticatedConnection?
    private var commandsSent: [ClientCommand] = []
    private var connectCalls = 0
    private var lastCredential: CredentialHandle?
    private var ordinal: UInt64 = 0

    func connect(to endpoint: ApprovedEndpoint, deviceID: DeviceID, credential: CredentialHandle) async throws -> AuthenticatedConnection {
        connectCalls += 1
        lastCredential = credential
        let connection = try AuthenticatedConnection(
            linkInstanceID: LinkInstanceID(),
            deviceID: deviceID,
            connectionEpoch: ConnectionEpoch(1)
        )
        authenticated = connection
        return connection
    }

    func eventStream() async throws -> any SessionEventStream { stream }

    func send(_ command: ClientCommand) async throws -> CommandSendReceipt {
        commandsSent.append(command)
        let requestID: UInt32? = switch command {
        case let .list(requestID): requestID
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
    func connectCount() -> Int { connectCalls }
    func lastConnectedCredential() -> CredentialHandle? { lastCredential }
    func commands() -> [ClientCommand] { commandsSent }

    func emit(_ event: SessionEvent) async throws {
        guard let authenticated else { throw SessionLinkFailure.disconnected }
        ordinal += 1
        let origin = SessionEventOrigin(
            linkInstanceID: authenticated.linkInstanceID,
            deviceID: authenticated.deviceID,
            connectionEpoch: authenticated.connectionEpoch,
            receiveOrdinal: ReceiveOrdinal(ordinal)
        )
        await stream.yield(try SessionEventEnvelope(origin: origin, wireByteCount: 0, event: event))
    }
}

private actor RecordingEventStream: SessionEventStream {
    private var queued: [SessionEventEnvelope] = []
    private var waiter: CheckedContinuation<SessionEventEnvelope?, Never>?
    private var finished = false

    var budget: SessionEventStreamBudget {
        get async { SessionEventStreamBudget(maximumBufferedBytes: 1_000_000, maximumBufferedEvents: 128, maximumBufferedControls: 32) }
    }

    func next() async throws -> SessionEventEnvelope? {
        if !queued.isEmpty { return queued.removeFirst() }
        if finished { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }

    func yield(_ event: SessionEventEnvelope) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: event)
        } else if !finished {
            queued.append(event)
        }
    }

    func finish() {
        finished = true
        waiter?.resume(returning: nil)
        waiter = nil
    }
}
