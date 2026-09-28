import AppKit
import CorralContracts
import CorralMetalTerminal
import CorralProtocol
import CorralServices
import CorralUI
import SwiftTerm
import XCTest
@testable import CorralApp

@MainActor
final class CorralApplicationCoordinatorTests: XCTestCase {
    func testMVPDefaultsToProductionLoopbackAndAcceptsAnExplicitEndpoint() throws {
        let production = try CorralMVPConfiguration.endpoint(environment: [:])
        XCTAssertEqual(production.url.absoluteString, "ws://127.0.0.1:9900/ws")
        let fixture = try CorralMVPConfiguration.endpoint(environment: ["CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws"])
        XCTAssertEqual(fixture.port, 9919)
        XCTAssertThrowsError(try CorralMVPConfiguration.endpoint(environment: ["CORRAL_NATIVE_ENDPOINT": "ws://192.0.2.1:9900/ws"]))
    }

    func testFullAppMenuExposesNewAgentShortcut() throws {
        let mainMenu = CorralAppDelegate().makeMainMenu()
        XCTAssertTrue(mainMenu.items.contains { $0.submenu?.title == "File" })
        XCTAssertTrue(mainMenu.items.first?.submenu?.items.contains { $0.keyEquivalent == "q" } == true)
        let newAgent = try XCTUnwrap(mainMenu.items.first(where: { $0.submenu?.title == "File" })?.submenu?.items.first)
        XCTAssertEqual(newAgent.title, "New Agent")
        XCTAssertEqual(newAgent.keyEquivalent, "n")
        XCTAssertTrue(newAgent.keyEquivalentModifierMask.contains(.command))
    }

    private func waitUntilMVP(timeoutNanoseconds: UInt64 = 2_000_000_000, _ predicate: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await predicate()
    }

    private func visibleText(in terminalView: TerminalView) -> String {
        (0..<terminalView.terminal.rows).compactMap { terminalView.terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }

    private func terminalText(_ coordinator: CorralApplicationCoordinator, reference: SessionReference) -> String {
        guard let view = coordinator.terminalView(for: reference) else { return "" }
        return visibleText(in: view)
    }

    func testMVPUsesSwiftTermGridAndKeepsScrollbackOutOfLiveTerminal() async throws {
        let link = RecordingSessionLink()
        let coordinator = CorralMVPCoordinator(
            sessionLink: link,
            environment: [
                "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
                "CORRAL_NATIVE_TOKEN": "fixture-test-only"
            ]
        )
        coordinator.window.contentView = nil
        await coordinator.start()
        let reference = try SessionReference("mvp-resize-session")
        let record = WireSessionRecord(
            reference: reference, name: "resize", workingDirectory: "/fixture/resize",
            state: .working, rows: 24, columns: 80, provider: "pi", activity: "working", health: "normal"
        )
        try await link.emit(.control(.listing(SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(workingDirectory: "/fixture/resize", sessionCount: 1, aggregateState: .working, sessions: [record])
        ]))))
        let subscribed = await waitUntilMVP {
            await link.commands().contains { if case .subscribe(reference: reference, _) = $0 { true } else { false } }
        }
        XCTAssertTrue(subscribed)
        let terminalView = try XCTUnwrap(coordinator.workspaceView.stageContainer.subviews.first as? TerminalView)
        XCTAssertFalse(terminalView.isUsingMetalRenderer, "SwiftTerm must use its stable CoreGraphics renderer")

        let grid = GridSize(rows: 48, columns: 132)
        coordinator.sizeChanged(source: terminalView, newCols: grid.columns, newRows: grid.rows)
        let resized = await waitUntilMVP {
            await link.commands().contains { if case .resize(reference: reference, size: grid) = $0 { true } else { false } }
        }
        XCTAssertTrue(resized, "SwiftTerm's measured grid must be sent to the server")
        let commands = await link.commands()
        let subscribeIndex = try XCTUnwrap(commands.firstIndex { if case .subscribe(reference: reference, _) = $0 { true } else { false } })
        let resizeIndex = try XCTUnwrap(commands.firstIndex { if case .resize(reference: reference, size: grid) = $0 { true } else { false } })
        XCTAssertLessThan(subscribeIndex, resizeIndex)

        try await link.emit(.frame(.snapshot(reference: reference, ansi: Data("LIVE".utf8))))
        let liveRendered = await waitUntilMVP { visibleText(in: terminalView).contains("LIVE") }
        XCTAssertTrue(liveRendered)
        let metadata = try ScrollbackMetadata(requestID: 1, fromLine: 0, lineCount: 1)
        try await link.emit(.frame(.scrollback(reference: reference, metadata: metadata, ansi: Data("HISTORY_SHOULD_NOT_APPEAR".utf8))))
        try await link.emit(.frame(.delta(reference: reference, ansi: Data("\r\nTAIL".utf8))))
        let deltaRendered = await waitUntilMVP { visibleText(in: terminalView).contains("TAIL") }
        XCTAssertTrue(deltaRendered)
        XCTAssertFalse(visibleText(in: terminalView).contains("HISTORY_SHOULD_NOT_APPEAR"))
        await coordinator.stop()
    }

    func testBareLineFeedsReturnToColumnZeroAcrossSnapshotAndDeltaFrames() async throws {
        let link = RecordingSessionLink()
        let coordinator = CorralMVPCoordinator(
            sessionLink: link,
            environment: [
                "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
                "CORRAL_NATIVE_TOKEN": "fixture-test-only"
            ]
        )
        coordinator.window.contentView = nil
        await coordinator.start()
        let reference = try SessionReference("mvp-linefeed-session")
        let record = WireSessionRecord(
            reference: reference, name: "linefeeds", workingDirectory: "/fixture/linefeeds",
            state: .working, rows: 24, columns: 80, provider: "pi", activity: "working", health: "normal"
        )
        try await link.emit(.control(.listing(SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(workingDirectory: "/fixture/linefeeds", sessionCount: 1, aggregateState: .working, sessions: [record])
        ]))))
        let subscribed = await waitUntilMVP {
            await link.commands().contains { if case .subscribe(reference: reference, _) = $0 { true } else { false } }
        }
        XCTAssertTrue(subscribed)
        let terminalView = try XCTUnwrap(coordinator.workspaceView.stageContainer.subviews.first as? TerminalView)

        let snapshot = "\u{1b}[31mFIRST\n\u{1b}[32mSECOND\r\n\u{1b}[33mTHIRD\r"
        try await link.emit(.frame(.snapshot(reference: reference, ansi: Data(snapshot.utf8))))
        try await link.emit(.frame(.delta(reference: reference, ansi: Data("\nFOURTH\nFIFTH".utf8))))
        let rendered = await waitUntilMVP { visibleText(in: terminalView).contains("FIFTH") }
        XCTAssertTrue(rendered)

        let rows = (0..<5).compactMap { terminalView.terminal.getLine(row: $0)?.translateToString(trimRight: true) }
        XCTAssertTrue(rows[0].hasPrefix("FIRST"))
        XCTAssertTrue(rows[1].hasPrefix("SECOND"))
        XCTAssertTrue(rows[2].hasPrefix("THIRD"))
        XCTAssertTrue(rows[3].hasPrefix("FOURTH"))
        XCTAssertTrue(rows[4].hasPrefix("FIFTH"))
        await coordinator.stop()
    }

    func testMVPForwardsUserBytesAndMouseButSuppressesVTReplies() async throws {
        let link = RecordingSessionLink()
        let coordinator = CorralMVPCoordinator(
            sessionLink: link,
            environment: [
                "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
                "CORRAL_NATIVE_TOKEN": "fixture-test-only"
            ]
        )
        coordinator.window.contentView = nil
        await coordinator.start()
        let reference = try SessionReference("mvp-input-session")
        let record = WireSessionRecord(
            reference: reference, name: "input", workingDirectory: "/fixture/input",
            state: .working, rows: 24, columns: 80, provider: "pi", activity: "working", health: "normal"
        )
        try await link.emit(.control(.listing(SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(workingDirectory: "/fixture/input", sessionCount: 1, aggregateState: .working, sessions: [record])
        ]))))
        let subscribed = await waitUntilMVP {
            await link.commands().contains { if case .subscribe(reference: reference, _) = $0 { true } else { false } }
        }
        XCTAssertTrue(subscribed)
        let terminalView = try XCTUnwrap(coordinator.workspaceView.stageContainer.subviews.first as? TerminalView)

        let userBytes = Array("hello".utf8)
        terminalView.send(data: userBytes[...])
        let userInputSent = await waitUntilMVP {
            await link.commands().contains { if case .input = $0 { true } else { false } }
        }
        XCTAssertTrue(userInputSent)

        let mouseBytes = Array("\u{1b}[<0;1;1M".utf8)
        terminalView.send(data: mouseBytes[...])
        let mouseInputSent = await waitUntilMVP {
            await link.commands().filter { if case .input = $0 { true } else { false } }.count == 2
        }
        XCTAssertTrue(mouseInputSent, "mouse reports must use the terminal user-input send path")

        terminalView.feed(byteArray: Array("\u{1b}[5n".utf8)[...])
        try? await Task.sleep(nanoseconds: 30_000_000)
        let inputCommands = await link.commands()
        let inputRequests = inputCommands.compactMap { command -> ClientInputRequest? in
            guard case let .input(request) = command else { return nil }
            return request
        }
        XCTAssertEqual(inputRequests.count, 2, "SwiftTerm VT query replies must not be echoed as user input")
        XCTAssertEqual(inputRequests.map(\.sequence), [1, 2])
        XCTAssertEqual(inputRequests[0].payload, .bytes(Data(userBytes)))
        XCTAssertEqual(inputRequests[1].payload, .bytes(Data(mouseBytes)))
        await coordinator.stop()
    }

    func testWarmSessionSwitchesPersistentTerminalViewsWithoutResubscribe() async throws {
        let link = RecordingSessionLink()
        let coordinator = CorralMVPCoordinator(
            sessionLink: link,
            environment: [
                "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
                "CORRAL_NATIVE_TOKEN": "fixture-test-only"
            ]
        )
        coordinator.window.contentView = nil
        await coordinator.start()
        XCTAssertTrue(coordinator.connected)

        let firstReference = try SessionReference("mvp-session-a")
        let secondReference = try SessionReference("mvp-session-b")
        let records = [
            WireSessionRecord(reference: firstReference, name: "A", workingDirectory: "/fixture/a", state: .working, rows: 24, columns: 80, provider: "pi", activity: "working", health: "normal"),
            WireSessionRecord(reference: secondReference, name: "B", workingDirectory: "/fixture/b", state: .idle, rows: 24, columns: 80, provider: "codex", activity: "idle", health: "normal")
        ]
        try await link.emit(.control(.listing(SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(workingDirectory: "/fixture", sessionCount: records.count, aggregateState: .working, sessions: records)
        ]))))
        let listed = await waitUntilMVP { coordinator.sessionRows.count == 2 && coordinator.workspaceView.stageContainer.subviews.first is TerminalView }
        XCTAssertTrue(listed)
        let firstID = try XCTUnwrap(coordinator.sessionRows.first { $0.name == "A" }?.id)
        let secondID = try XCTUnwrap(coordinator.sessionRows.first { $0.name == "B" }?.id)
        XCTAssertEqual(coordinator.selectedAgentID, firstID, "first listing entry is selected by default")

        try await link.emit(.frame(.snapshot(reference: firstReference, ansi: Data("session A".utf8))))
        let firstView = try XCTUnwrap(coordinator.workspaceView.stageContainer.subviews.first as? TerminalView)
        let firstRendered = await waitUntilMVP { visibleText(in: firstView).contains("session A") }
        XCTAssertTrue(firstRendered)
        let stageIdentity = ObjectIdentifier(coordinator.workspaceView.stageContainer)

        coordinator.switchSession(secondID)
        let secondSubscribed = await waitUntilMVP {
            guard coordinator.workspaceView.stageContainer.subviews.first !== firstView else { return false }
            let commands = await link.commands()
            return commands.contains { if case .subscribe(reference: secondReference, _) = $0 { true } else { false } }
        }
        XCTAssertTrue(secondSubscribed)
        let secondView = try XCTUnwrap(coordinator.workspaceView.stageContainer.subviews.first as? TerminalView)
        try await link.emit(.frame(.snapshot(reference: secondReference, ansi: Data("session B".utf8))))
        let secondRendered = await waitUntilMVP { visibleText(in: secondView).contains("session B") }
        XCTAssertTrue(secondRendered)

        let commandsBeforeWarmSwitches = await link.commands()
        for _ in 0..<10 {
            coordinator.switchSession(firstID)
            XCTAssertTrue(coordinator.workspaceView.stageContainer.subviews.first === firstView)
            XCTAssertTrue(visibleText(in: firstView).contains("session A"))
            coordinator.switchSession(secondID)
            XCTAssertTrue(coordinator.workspaceView.stageContainer.subviews.first === secondView)
            XCTAssertTrue(visibleText(in: secondView).contains("session B"))
        }
        let commandsAfterWarmSwitches = await link.commands()
        XCTAssertEqual(commandsAfterWarmSwitches.filter { if case .subscribe = $0 { true } else { false } }.count,
                       commandsBeforeWarmSwitches.filter { if case .subscribe = $0 { true } else { false } }.count)
        XCTAssertFalse(commandsAfterWarmSwitches.contains { if case .unsubscribe = $0 { true } else { false } })
        XCTAssertEqual(ObjectIdentifier(coordinator.workspaceView.stageContainer), stageIdentity)
        XCTAssertEqual(coordinator.selectedAgentID, secondID)
        await coordinator.stop()
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

    func testSidebarAgentOpenUsesRegularTabAndPreviewCloseRestoresPinnedHostTitle() async throws {
        let link = RecordingSessionLink()
        let coordinator = try await makeCoordinator(link: link, atlas: .shared, environment: [
            "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
            "CORRAL_NATIVE_TOKEN": "fixture-only-token",
            "CORRAL_NATIVE_BACKGROUND": "1"
        ])
        let window = try XCTUnwrap(coordinator.windowController.window)
        window.orderBack(nil)
        await coordinator.start()
        XCTAssertTrue(coordinator.connected)

        let leaderReference = try SessionReference("leader-session")
        let previewReference = try SessionReference("preview-session")
        let records = [
            WireSessionRecord(reference: leaderReference, name: "全自动编排leader", workingDirectory: "/Users/fixture/Aaron", state: .working, rows: 24, columns: 80, provider: "pi", activity: "working", health: "normal"),
            WireSessionRecord(reference: previewReference, name: "rust-developer", workingDirectory: "/Users/fixture/rust", state: .idle, rows: 24, columns: 80, provider: "codex", activity: "idle", health: "normal")
        ]
        try await link.emit(.control(.listing(SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(workingDirectory: "/Users/fixture", sessionCount: records.count, aggregateState: .working, sessions: records)
        ]))))
        let listed = await waitUntil { coordinator.sessionCount == 2 && coordinator.workspaceView.sidebar.agents.count == 2 }
        XCTAssertTrue(listed)

        let leader = try XCTUnwrap(coordinator.workspaceView.sidebar.agents.first { $0.name == "全自动编排leader" })
        let tabID = coordinator.workspaceState.activeTabID
        coordinator.workspaceView.sidebar.onSelectAgent?(leader.id)
        let opened = await waitUntil {
            coordinator.workspaceState.activeTab?.activeSessionID != nil &&
                coordinator.workspaceView.tabs.first(where: { $0.id == tabID })?.title == "全自动编排leader"
        }
        XCTAssertTrue(opened)
        var tab = try XCTUnwrap(coordinator.workspaceView.tabs.first { $0.id == tabID })
        XCTAssertFalse(coordinator.workspaceState.activeTab?.pinned ?? true)
        XCTAssertFalse(tab.isPinned)
        XCTAssertEqual(tab.title, "全自动编排leader", "session name must win over cwd basename Aaron")
        XCTAssertEqual(tab.provider, "pi")
        XCTAssertEqual(tab.status, .working)
        let title = try XCTUnwrap(descendants(of: coordinator.workspaceView.tabBar).compactMap { $0 as? NSTextField }.first {
            $0.accessibilityIdentifier() == "corral.tab.title"
        })
        XCTAssertEqual(title.stringValue, "全自动编排leader")

        await coordinator.pinWorkspaceTab(tabID, pinned: true)
        let explicitlyPinned = await waitUntil { coordinator.workspaceState.activeTab?.pinned == true }
        XCTAssertTrue(explicitlyPinned)
        let previewAgent = try XCTUnwrap(coordinator.workspaceView.sidebar.agents.first { $0.name == "rust-developer" })
        coordinator.workspaceView.sidebar.onSelectAgent?(previewAgent.id)
        let previewed = await waitUntil {
            coordinator.workspaceState.previewUID != nil &&
                coordinator.workspaceView.tabs.first(where: { $0.id == tabID })?.isPreview == true &&
                coordinator.workspaceView.tabs.first(where: { $0.id == tabID })?.title == "rust-developer"
        }
        XCTAssertTrue(previewed)
        tab = try XCTUnwrap(coordinator.workspaceView.tabs.first { $0.id == tabID })
        XCTAssertTrue(tab.isPinned, "preview must preserve an explicit pin on its host Tab")
        XCTAssertEqual(tab.provider, "codex")
        XCTAssertEqual(tab.status, .idle)
        let previewClose = try XCTUnwrap(descendants(of: coordinator.workspaceView.tabBar).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "corral.tab.close"
        })
        XCTAssertEqual(previewClose.accessibilityLabel(), "关闭预览")
        previewClose.performClick(previewClose)
        let previewClosed = await waitUntil {
            coordinator.workspaceState.previewUID == nil &&
                coordinator.workspaceView.tabs.first(where: { $0.id == tabID })?.isPreview == false &&
                coordinator.workspaceView.tabs.first(where: { $0.id == tabID })?.title == "全自动编排leader"
        }
        XCTAssertTrue(previewClosed)
        XCTAssertEqual(coordinator.workspaceState.tabs.count, 1, "closing a preview must not close its durable host")
        XCTAssertTrue(coordinator.workspaceState.activeTab?.pinned == true)
        XCTAssertEqual(coordinator.workspaceView.tabs.first?.provider, "pi")
        XCTAssertEqual(coordinator.workspaceView.tabs.first?.status, .working)

        coordinator.workspaceView.tabBar.onRenameTab?(tabID, "用户自定义标题")
        let renamed = await waitUntil { coordinator.workspaceState.activeTab?.isCustomTitle == true }
        XCTAssertTrue(renamed)
        let changedRecords = [
            WireSessionRecord(reference: leaderReference, name: "Updated Agent Name", workingDirectory: "/Users/fixture/NewCWD", state: .working, rows: 24, columns: 80, provider: "pi", activity: "working", health: "normal"),
            records[1]
        ]
        try await link.emit(.control(.listing(SessionListing(requestID: 1, sequence: 2, workspaces: [
            WorkspaceRecord(workingDirectory: "/Users/fixture/NewCWD", sessionCount: changedRecords.count, aggregateState: .working, sessions: changedRecords)
        ]))))
        let customTitlePreserved = await waitUntil { coordinator.workspaceView.tabs.first(where: { $0.id == tabID })?.title == "用户自定义标题" }
        XCTAssertTrue(customTitlePreserved)
        await coordinator.renameWorkspaceTab(tabID, to: "")
        let sessionTitleRestored = await waitUntil { coordinator.workspaceView.tabs.first(where: { $0.id == tabID })?.title == "Updated Agent Name" }
        XCTAssertTrue(sessionTitleRestored, "session name must still win over the changed cwd basename")
        let leaderKey = SessionKey(deviceID: DeviceID("corral-native-development-endpoint"), reference: leaderReference)
        await coordinator.renameAgent(leaderKey, to: "Local Agent Title")
        XCTAssertEqual(coordinator.workspaceView.tabs.first(where: { $0.id == tabID })?.title, "Local Agent Title")
        XCTAssertTrue(coordinator.workspaceState.tabs.first(where: { $0.id == tabID })?.isCustomTitle == true)
        XCTAssertTrue(coordinator.workspaceView.sidebar.agents.contains { $0.name == "Updated Agent Name" }, "workspace title overrides must not rename the server Agent")
        await coordinator.stop()
        window.close()
    }

    func testOpenSessionHonorsTargetTabAndReplacesStageContent() async throws {
        let link = RecordingSessionLink()
        let coordinator = try await makeCoordinator(link: link, atlas: .shared, environment: [
            "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
            "CORRAL_NATIVE_TOKEN": "fixture-only-token",
            "CORRAL_NATIVE_BACKGROUND": "1"
        ])
        let window = try XCTUnwrap(coordinator.windowController.window)
        window.orderBack(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        let initialFrame = window.frame
        await coordinator.start()

        let firstReference = try SessionReference("switch-leader")
        let secondReference = try SessionReference("switch-rust-developer")
        let deviceRawID = "corral-native-development-endpoint"
        let firstSessionID = SessionID("\(deviceRawID.utf8.count):\(deviceRawID)\(firstReference.rawValue)")
        let secondSessionID = SessionID("\(deviceRawID.utf8.count):\(deviceRawID)\(secondReference.rawValue)")
        let records = [
            WireSessionRecord(reference: firstReference, name: "leader", workingDirectory: "/fixture/leader", state: .working, rows: 24, columns: 80, provider: "pi", activity: "working", health: "normal"),
            WireSessionRecord(reference: secondReference, name: "rust-developer", workingDirectory: "/fixture/rust", state: .idle, rows: 24, columns: 80, provider: "codex", activity: "idle", health: "normal")
        ]
        try await link.emit(.control(.listing(SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(workingDirectory: "/fixture", sessionCount: records.count, aggregateState: .working, sessions: records)
        ]))))
        let firstOpened = await waitUntil {
            coordinator.activeTerminalSessionKey?.reference == firstReference &&
                coordinator.subscribedSessionIDs.contains(firstReference.rawValue)
        }
        XCTAssertTrue(firstOpened, "the initial listing should auto-open and subscribe its first session")
        try await link.emit(.frame(.snapshot(reference: firstReference, ansi: Data("FIRST-SESSION-CONTENT\r\n".utf8))))
        let firstRendered = await waitUntil {
            self.terminalText(coordinator, reference: firstReference).contains("FIRST-SESSION-CONTENT")
        }
        XCTAssertTrue(firstRendered)

        let firstTabID = coordinator.workspaceState.activeTabID
        await coordinator.createWorkspaceTab()
        let targetTabID = coordinator.workspaceState.activeTabID
        XCTAssertNotEqual(targetTabID, firstTabID)
        await coordinator.selectWorkspaceTab(id: firstTabID)
        let secondAgent = try XCTUnwrap(coordinator.workspaceView.sidebar.agents.first { $0.name == "rust-developer" })
        coordinator.workspaceView.onOpenSession?(secondAgent.id, targetTabID, false)

        let secondOpenedInTarget = await waitUntil {
            coordinator.workspaceState.activeTabID == targetTabID &&
                coordinator.workspaceState.tabs.first(where: { $0.id == targetTabID })?.sessionIDs == [secondSessionID] &&
                coordinator.workspaceState.visibleSessionID == secondSessionID &&
                coordinator.workspaceState.visibleRoot?.leafIDs == [secondSessionID] &&
                coordinator.activeTerminalSessionKey?.reference == secondReference &&
                coordinator.subscribedSessionIDs.contains(secondReference.rawValue)
        }
        XCTAssertTrue(secondOpenedInTarget, "the requested blank Tab must receive and subscribe the clicked session")
        XCTAssertEqual(coordinator.workspaceState.tabs.count, 2, "the click must not create an unintended extra Tab")
        XCTAssertEqual(coordinator.workspaceState.tabs.first(where: { $0.id == firstTabID })?.sessionIDs, [firstSessionID])
        XCTAssertNil(coordinator.workspaceState.previewUID)
        try await link.emit(.frame(.snapshot(reference: secondReference, ansi: Data("SECOND-SESSION-CONTENT\r\n".utf8))))
        let secondRendered = await waitUntil {
            self.terminalText(coordinator, reference: secondReference).contains("SECOND-SESSION-CONTENT")
        }
        XCTAssertTrue(secondRendered, "the new session snapshot must feed the selected SwiftTerm view")

        let firstAgent = try XCTUnwrap(coordinator.workspaceView.sidebar.agents.first { $0.name == "leader" })
        coordinator.selectSidebarSession(id: firstAgent.id)
        let returnedToFirst = await waitUntil {
            coordinator.workspaceState.activeTabID == firstTabID &&
                coordinator.workspaceState.visibleSessionID == firstSessionID &&
                coordinator.activeTerminalSessionKey?.reference == firstReference &&
                self.terminalText(coordinator, reference: firstReference).contains("FIRST-SESSION-CONTENT")
        }
        XCTAssertTrue(returnedToFirst, "selecting a session from another Tab must switch to its owning Tab and render it")
        await coordinator.selectWorkspaceTab(id: targetTabID)
        let returnedToSecond = await waitUntil {
            coordinator.workspaceState.activeTabID == targetTabID &&
                coordinator.workspaceState.visibleSessionID == secondSessionID &&
                coordinator.activeTerminalSessionKey?.reference == secondReference &&
                self.terminalText(coordinator, reference: secondReference).contains("SECOND-SESSION-CONTENT")
        }
        XCTAssertTrue(returnedToSecond, "switching Tabs must restore that Tab's session to the stage")
        XCTAssertEqual(window.frame, initialFrame, "session and Tab switching must preserve native window geometry")
        await coordinator.stop()
        window.close()
    }

    func testOpenSessionFallsBackInsteadOfDroppingForStaleTabID() async throws {
        let link = RecordingSessionLink()
        let coordinator = try await makeCoordinator(link: link, atlas: .shared, environment: [
            "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
            "CORRAL_NATIVE_TOKEN": "fixture-only-token",
            "CORRAL_NATIVE_BACKGROUND": "1"
        ])
        let window = try XCTUnwrap(coordinator.windowController.window)
        window.orderBack(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        await coordinator.start()

        let firstReference = try SessionReference("stale-target-host")
        let requestedReference = try SessionReference("stale-target-requested")
        let records = [
            WireSessionRecord(reference: firstReference, name: "host", workingDirectory: "/fixture", state: .working, rows: 24, columns: 80, provider: "pi", activity: "working", health: "normal"),
            WireSessionRecord(reference: requestedReference, name: "requested", workingDirectory: "/fixture", state: .idle, rows: 24, columns: 80, provider: "codex", activity: "idle", health: "normal")
        ]
        try await link.emit(.control(.listing(SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(workingDirectory: "/fixture", sessionCount: records.count, aggregateState: .working, sessions: records)
        ]))))
        let listed = await waitUntil {
            coordinator.sessionCount == records.count && coordinator.workspaceView.sidebar.agents.count == records.count
        }
        XCTAssertTrue(listed)

        await coordinator.createWorkspaceTab()
        let expectedActiveTabID = coordinator.workspaceState.activeTabID
        let requestedAgent = try XCTUnwrap(coordinator.workspaceView.sidebar.agents.first { $0.name == "requested" })
        coordinator.workspaceView.onOpenSession?(requestedAgent.id, UUID(), false)
        let opened = await waitUntil {
            coordinator.workspaceState.activeTabID == expectedActiveTabID &&
                coordinator.workspaceState.visibleSessionID?.rawValue.hasSuffix(requestedReference.rawValue) == true &&
                coordinator.activeTerminalSessionKey?.reference == requestedReference &&
                coordinator.subscribedSessionIDs.contains(requestedReference.rawValue)
        }
        XCTAssertTrue(opened, "a stale UI Tab ID must not silently discard a valid session-open request")
        XCTAssertTrue(coordinator.lastConnectionError?.contains("requested workspace Tab no longer exists") == true)

        try await link.emit(.frame(.snapshot(reference: requestedReference, ansi: Data("STALE-TAB-FALLBACK-CONTENT\r\n".utf8))))
        let rendered = await waitUntil {
            self.terminalText(coordinator, reference: requestedReference).contains("STALE-TAB-FALLBACK-CONTENT")
        }
        XCTAssertTrue(rendered, "the fallback session snapshot must still reach the SwiftTerm view")
        await coordinator.stop()
        window.close()
    }

    func testSnapshotArrivingBeforeSubscribeReceiptIsNotDiscarded() async throws {
        let link = RecordingSessionLink()
        let coordinator = try await makeCoordinator(link: link, atlas: .shared, environment: [
            "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
            "CORRAL_NATIVE_TOKEN": "fixture-only-token",
            "CORRAL_NATIVE_BACKGROUND": "1"
        ])
        let window = try XCTUnwrap(coordinator.windowController.window)
        window.orderBack(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        await coordinator.start()

        let firstReference = try SessionReference("subscribe-race-host")
        let racedReference = try SessionReference("subscribe-race-target")
        let records = [
            WireSessionRecord(reference: firstReference, name: "host", workingDirectory: "/fixture", state: .working, rows: 24, columns: 80, provider: "pi", activity: "working", health: "normal"),
            WireSessionRecord(reference: racedReference, name: "race-target", workingDirectory: "/fixture", state: .idle, rows: 24, columns: 80, provider: "codex", activity: "idle", health: "normal")
        ]
        try await link.emit(.control(.listing(SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(workingDirectory: "/fixture", sessionCount: records.count, aggregateState: .working, sessions: records)
        ]))))
        let listed = await waitUntil {
            coordinator.sessionCount == records.count &&
                coordinator.subscribedSessionIDs.contains(firstReference.rawValue)
        }
        XCTAssertTrue(listed)
        await coordinator.createWorkspaceTab()
        let targetTabID = coordinator.workspaceState.activeTabID
        let targetAgent = try XCTUnwrap(coordinator.workspaceView.sidebar.agents.first { $0.name == "race-target" })
        await link.suspendNextSubscribe()
        coordinator.workspaceView.onOpenSession?(targetAgent.id, targetTabID, false)

        let sendIsPending = await waitUntil { await link.isSubscribeSuspended(for: racedReference) }
        XCTAssertTrue(sendIsPending, "the fake link must pause after the subscribe request begins")
        try await link.emit(.frame(.snapshot(
            reference: racedReference,
            ansi: Data("EARLY-SNAPSHOT-CONTENT\r\n".utf8)
        )))
        let renderedBeforeReceipt = await waitUntil(timeout: .seconds(8)) {
            self.terminalText(coordinator, reference: racedReference).contains("EARLY-SNAPSHOT-CONTENT")
        }
        await link.releaseSuspendedSubscribe()
        XCTAssertTrue(renderedBeforeReceipt, "the first frame must be accepted while subscribe's send receipt is pending")
        let subscribed = await waitUntil {
            coordinator.subscribedSessionIDs.contains(racedReference.rawValue) &&
                coordinator.activeTerminalSessionKey?.reference == racedReference
        }
        XCTAssertTrue(subscribed)
        await coordinator.stop()
        window.close()
    }

    func testFullCoordinatorReplacesSnapshotsAndKeepsRemoteHistoryOutOfLiveBuffer() async throws {
        let reference = try SessionReference("snapshot-boundary")
        let link = RecordingSessionLink()
        let coordinator = try await makeCoordinator(link: link, atlas: .shared, environment: [
            "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
            "CORRAL_NATIVE_TOKEN": "fixture-only-token",
            "CORRAL_NATIVE_BACKGROUND": "1"
        ])
        await coordinator.start()
        let record = WireSessionRecord(
            reference: reference, name: "snapshot-boundary", workingDirectory: "/fixture/snapshot",
            state: .working, rows: 24, columns: 80, provider: "pi", activity: "working", health: "normal"
        )
        try await link.emit(.control(.listing(SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(workingDirectory: "/fixture/snapshot", sessionCount: 1, aggregateState: .working, sessions: [record])
        ]))))
        let subscribed = await waitUntil {
            coordinator.activeTerminalSessionKey?.reference == reference &&
                coordinator.subscribedSessionIDs.contains(reference.rawValue)
        }
        XCTAssertTrue(subscribed)
        guard subscribed, let view = coordinator.terminalView(for: reference) else {
            await coordinator.stop()
            return
        }

        try await link.emit(.frame(.snapshot(reference: reference, ansi: Data("STALE-SNAPSHOT\r\n".utf8))))
        let staleSnapshotApplied = await waitUntil { self.terminalText(coordinator, reference: reference).contains("STALE-SNAPSHOT") }
        XCTAssertTrue(staleSnapshotApplied)
        try await link.emit(.frame(.snapshot(reference: reference, ansi: Data("FIRST-ROW\nSECOND-ROW".utf8))))
        let replacementApplied = await waitUntil {
            let text = self.terminalText(coordinator, reference: reference)
            return text.contains("FIRST-ROW") && text.contains("SECOND-ROW") && !text.contains("STALE-SNAPSHOT")
        }
        XCTAssertTrue(replacementApplied, "a fresh complete snapshot replaces, rather than appends to, the prior screen")
        XCTAssertTrue(view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true).hasPrefix("FIRST-ROW") == true)
        XCTAssertTrue(view.getTerminal().getLine(row: 1)?.translateToString(trimRight: true).hasPrefix("SECOND-ROW") == true)

        let metadata = try ScrollbackMetadata(requestID: 1, fromLine: 0, lineCount: 1)
        try await link.emit(.frame(.scrollback(reference: reference, metadata: metadata, ansi: Data("REMOTE-HISTORY-MUST-STAY-ISOLATED".utf8))))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(self.terminalText(coordinator, reference: reference).contains("REMOTE-HISTORY-MUST-STAY-ISOLATED"))
        await coordinator.stop()
    }

    func testTabContextMenuSplitActionsMoveSessionIntoActiveTab() async throws {
        let cases: [(String, SplitDirection)] = [("splitRight", .horizontal), ("splitDown", .vertical)]
        for (action, expectedDirection) in cases {
            let firstReference = try SessionReference("context-split-first")
            let secondReference = try SessionReference("context-split-second")
            let deviceID = DeviceID("corral-native-development-endpoint")
            let firstSessionID = SessionID("\(deviceID.rawValue.utf8.count):\(deviceID.rawValue)\(firstReference.rawValue)")
            let secondSessionID = SessionID("\(deviceID.rawValue.utf8.count):\(deviceID.rawValue)\(secondReference.rawValue)")
            let link = RecordingSessionLink()
            let coordinator = try await makeCoordinator(link: link, atlas: .shared, environment: [
                "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
                "CORRAL_NATIVE_TOKEN": "fixture-only-token",
                "CORRAL_NATIVE_BACKGROUND": "1"
            ])
            await coordinator.start()
            let records = [
                WireSessionRecord(reference: firstReference, name: "First", workingDirectory: "/fixture/split", state: .working, rows: 24, columns: 80),
                WireSessionRecord(reference: secondReference, name: "Second", workingDirectory: "/fixture/split", state: .idle, rows: 24, columns: 80)
            ]
            try await link.emit(.control(.listing(SessionListing(requestID: 1, sequence: 1, workspaces: [
                WorkspaceRecord(workingDirectory: "/fixture/split", sessionCount: 2, aggregateState: .working, sessions: records)
            ]))))
            let firstReady = await waitUntil {
                coordinator.activeTerminalSessionKey?.reference == firstReference &&
                    coordinator.subscribedSessionIDs.contains(firstReference.rawValue)
            }
            XCTAssertTrue(firstReady)
            let firstTabID = coordinator.workspaceState.activeTabID
            await coordinator.createWorkspaceTab()
            let secondTabID = coordinator.workspaceState.activeTabID
            let secondKey = SessionKey(deviceID: DeviceID("corral-native-development-endpoint"), reference: secondReference)
            await coordinator.openSession(secondKey, gesture: .doubleClick, in: secondTabID)
            let secondReady = await waitUntil {
                coordinator.workspaceState.activeTabID == secondTabID &&
                    coordinator.activeTerminalSessionKey == secondKey &&
                    coordinator.subscribedSessionIDs.contains(secondReference.rawValue)
            }
            XCTAssertTrue(secondReady)

            coordinator.workspaceView.tabBar.onContextAction?(firstTabID, action)
            let splitApplied = await waitUntil {
                coordinator.workspaceState.activeTabID == secondTabID &&
                    Set(coordinator.workspaceState.visibleRoot?.leafIDs ?? []) == Set([firstSessionID, secondSessionID])
            }
            XCTAssertTrue(splitApplied, "\(action) must move the source Tab's session into the active Tab split")
            if case let .split(direction, _, _, _)? = coordinator.workspaceState.visibleRoot {
                XCTAssertEqual(direction, expectedDirection)
            } else {
                XCTFail("\(action) should produce a split layout")
            }
            await coordinator.stop()
        }
    }

    func testSavedSessionIdentityNameIsUsedBeforeWorkingDirectory() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("corral-native-saved-title-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let sessionID = SessionID("saved-session")
        let tab = WorkspaceTab(root: .session(sessionID), activeSessionID: sessionID)
        let state = try CorralWorkspaceState(
            tabs: [tab],
            activeTabID: tab.id,
            sessionBindings: [WorkspaceSessionBinding(
                sessionID: sessionID,
                identity: WorkspaceSessionIdentity(deviceID: DeviceID("saved-device"), workingDirectory: "/Users/fixture/Aaron", name: "Saved session name")
            )]
        )
        let stateDirectory = support.appendingPathComponent("com.corral.native.dev", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: stateDirectory.appendingPathComponent(CorralWorkspaceStore.storageFilename))

        let link = RecordingSessionLink()
        let coordinator = try await makeCoordinator(link: link, atlas: .shared, environment: [:], supportDirectory: support)
        await coordinator.start()
        XCTAssertEqual(coordinator.workspaceView.tabs.first?.title, "Saved session name")
        XCTAssertNotEqual(coordinator.workspaceView.tabs.first?.title, "Aaron")
        await coordinator.stop()
        coordinator.windowController.window?.close()
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

        coordinator.workspaceView.onDevices?()
        let devicesPanel = try XCTUnwrap(coordinator.devicesCardPanel)
        XCTAssertTrue(devicesPanel.contentViewController is DevicesPopoverViewController)
        XCTAssertEqual(devicesPanel.frame.width, CorralAnchoredCardPanel.cardWidth)
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

    func testInitialListingAutomaticallyOpensAndRendersFirstSession() async throws {
        let link = RecordingSessionLink()
        let coordinator = try await makeCoordinator(link: link, atlas: .shared, environment: [
            "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
            "CORRAL_NATIVE_TOKEN": "fixture-only-token",
            "CORRAL_NATIVE_BACKGROUND": "1"
        ])
        guard let window = coordinator.windowController.window else {
            return XCTFail("coordinator must own a real window")
        }
        window.orderBack(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        let initialWindowFrame = window.frame

        await coordinator.start()
        let listSent = await waitUntil { await link.commands().contains { if case .list = $0 { true } else { false } } }
        XCTAssertTrue(listSent)
        let firstReference = try SessionReference("auto-open-0")
        let records = try (0..<62).map { index in
            WireSessionRecord(
                reference: try SessionReference("auto-open-\(index)"),
                name: "agent-\(index)",
                workingDirectory: "/fixture/workspace",
                state: .working,
                rows: 24,
                columns: 80,
                provider: "pi",
                activity: "working",
                health: "normal"
            )
        }
        let listing = SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(
                workingDirectory: "/fixture/workspace",
                sessionCount: records.count,
                aggregateState: .working,
                sessions: records
            )
        ])
        try await link.emit(.control(.listing(listing)))

        let opened = await waitUntil(timeout: .seconds(8)) {
            coordinator.sessionCount == records.count
                && coordinator.activeTerminalSessionKey?.reference == firstReference
                && coordinator.subscribedSessionIDs.contains(firstReference.rawValue)
        }
        let commands = await link.commands()
        XCTAssertTrue(opened, "the first listed session should be selected and subscribed automatically")
        XCTAssertTrue(commands.contains {
            if case let .subscribe(reference, _) = $0 { return reference == firstReference }
            return false
        }, "opening the default session must issue a subscribe command")
        guard opened else {
            await coordinator.stop()
            window.close()
            return
        }

        try await link.emit(.frame(.snapshot(
            reference: firstReference,
            ansi: Data("AUTO-OPEN-TERMINAL-CONTENT\r\n".utf8)
        )))
        let rendered = await waitUntil(timeout: .seconds(8)) {
            self.terminalText(coordinator, reference: firstReference).contains("AUTO-OPEN-TERMINAL-CONTENT")
        }
        XCTAssertTrue(rendered, "the default session snapshot should render in the terminal stage")
        XCTAssertEqual(window.frame, initialWindowFrame, "automatic session opening must preserve window geometry")
        await coordinator.stop()
        window.close()
    }

    func testNoResizeInspectionSubscribesAtServerGridAndNeverSendsResize() async throws {
        let link = RecordingSessionLink()
        let coordinator = try await makeCoordinator(link: link, atlas: .shared, environment: [
            "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
            "CORRAL_NATIVE_TOKEN": "fixture-only-token",
            "CORRAL_NATIVE_BACKGROUND": "1",
            "CORRAL_NATIVE_NO_RESIZE": "1"
        ])
        let window = try XCTUnwrap(coordinator.windowController.window)
        window.orderBack(nil)
        window.displayIfNeeded()
        await coordinator.start()
        let listRequested = await waitUntil { await link.commands().contains { if case .list = $0 { true } else { false } } }
        XCTAssertTrue(listRequested)

        let reference = try SessionReference("no-resize-inspection")
        let serverGrid = GridSize(rows: 37, columns: 111)
        let listing = SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(
                workingDirectory: "/fixture/workspace",
                sessionCount: 1,
                aggregateState: .working,
                sessions: [WireSessionRecord(
                    reference: reference,
                    name: "inspection-agent",
                    workingDirectory: "/fixture/workspace",
                    state: .working,
                    rows: UInt16(serverGrid.rows),
                    columns: UInt16(serverGrid.columns),
                    provider: "pi",
                    activity: "working",
                    health: "normal"
                )]
            )
        ])
        try await link.emit(.control(.listing(listing)))
        let subscribed = await waitUntil {
            coordinator.sessionCount == 1 && coordinator.subscribedSessionIDs.contains(reference.rawValue)
        }
        XCTAssertTrue(subscribed)
        let terminal = try XCTUnwrap(descendants(of: window.contentView!).compactMap { $0 as? TerminalView }.first)
        coordinator.sizeChanged(source: terminal, newCols: 144, newRows: 50)
        let frame = window.frame
        window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: frame.width + 240, height: frame.height + 160), display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        let commands = await link.commands()
        let subscribe = try XCTUnwrap(commands.first {
            if case let .subscribe(candidate, _) = $0 { return candidate == reference }
            return false
        })
        guard case let .subscribe(_, size) = subscribe else { return XCTFail("expected subscription command") }
        XCTAssertEqual(size, serverGrid, "inspection subscribes with the server-advertised grid")
        XCTAssertFalse(commands.contains { if case .resize = $0 { true } else { false } })

        await coordinator.stop()
        window.close()
    }

    func testColdStartRestoresListedSessionIntoDarkStageWhenActiveTabIsBlank() async throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-native-cold-start-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let workspaceStore = try CorralWorkspaceStore(applicationSupportDirectory: supportDirectory)
        let preferencesStore = try UserPreferencesStore(applicationSupportDirectory: supportDirectory)
        _ = try await preferencesStore.update(UserPreferences(theme: .light))

        let reference = try SessionReference("persisted-leader")
        let deviceID = DeviceID("corral-native-development-endpoint")
        let sessionID = SessionID("\(deviceID.rawValue.utf8.count):\(deviceID.rawValue)\(reference.rawValue)")
        _ = try await workspaceStore.smartOpenSession(sessionID, gesture: .doubleClick)
        let restoredTabID = (await workspaceStore.snapshot()).activeTabID
        _ = try await workspaceStore.createTab()
        let initialWorkspaceState = await workspaceStore.snapshot()
        XCTAssertNotEqual(initialWorkspaceState.activeTabID, restoredTabID)
        XCTAssertTrue(initialWorkspaceState.activeTab?.isBlank == true)
        XCTAssertFalse(initialWorkspaceState.activeTab?.isImplicitBlank ?? true)

        let link = RecordingSessionLink()
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: EmptyDeviceRepository(),
            credentialVault: TestDeviceCredentialVault(),
            sessionLink: link,
            deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: link),
            workspaceStore: workspaceStore,
            userPreferencesStore: preferencesStore,
            initialWorkspaceState: initialWorkspaceState,
            initialUserPreferences: await preferencesStore.snapshot(),
            environment: [
                "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
                "CORRAL_NATIVE_TOKEN": "fixture-only-token",
                "CORRAL_NATIVE_BACKGROUND": "1"
            ]
        )
        let window = try XCTUnwrap(coordinator.windowController.window)
        window.orderBack(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        await coordinator.start()
        let listSent = await waitUntil { await link.commands().contains { if case .list = $0 { true } else { false } } }
        XCTAssertTrue(listSent)

        let record = WireSessionRecord(
            reference: reference,
            name: "leader",
            workingDirectory: "/fixture/workspace",
            state: .working,
            rows: 24,
            columns: 80,
            provider: "pi",
            activity: "working",
            health: "normal"
        )
        try await link.emit(.control(.listing(SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(workingDirectory: "/fixture/workspace", sessionCount: 1, aggregateState: .working, sessions: [record])
        ]))))
        let opened = await waitUntil {
            coordinator.workspaceState.activeTabID == restoredTabID &&
                coordinator.workspaceState.visibleSessionID == sessionID &&
                coordinator.activeTerminalSessionKey?.reference == reference &&
                coordinator.subscribedSessionIDs.contains(reference.rawValue)
        }
        XCTAssertTrue(opened, "a blank active Tab must restore the first listed Agent even when another persisted Tab owns it")

        let terminalView = try XCTUnwrap(coordinator.terminalView(for: SessionKey(deviceID: deviceID, reference: reference)))
        try await link.emit(.frame(.snapshot(reference: reference, ansi: Data("COLD-START-CONTENT\r\n".utf8))))
        let rendered = await waitUntil { self.visibleText(in: terminalView).contains("COLD-START-CONTENT") }
        XCTAssertTrue(rendered, "the restored session snapshot must mount and render in its SwiftTerm view")

        let stageColor = try XCTUnwrap(coordinator.workspaceView.stageContainer.layer?.backgroundColor)
        let stageNSColor = try XCTUnwrap(NSColor(cgColor: stageColor))
        let stageRGB = try XCTUnwrap(stageNSColor.usingColorSpace(.deviceRGB))
        XCTAssertEqual(Int((stageRGB.redComponent * 255).rounded()), 16)
        XCTAssertEqual(Int((stageRGB.greenComponent * 255).rounded()), 17)
        XCTAssertEqual(Int((stageRGB.blueComponent * 255).rounded()), 21)
        let stageHost = try XCTUnwrap(coordinator.workspaceView.stageContainer.subviews.first { $0 is NativeTerminalStageView })
        let stageHostColor = try XCTUnwrap(stageHost.layer?.backgroundColor)
        let stageHostRGB = try XCTUnwrap(NSColor(cgColor: stageHostColor)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(Int((stageHostRGB.redComponent * 255).rounded()), 16)
        XCTAssertEqual(Int((stageHostRGB.greenComponent * 255).rounded()), 17)
        XCTAssertEqual(Int((stageHostRGB.blueComponent * 255).rounded()), 21)
        XCTAssertEqual(coordinator.workspaceView.stageContainer.appearance?.name, .darkAqua)

        await coordinator.stop()
        window.close()
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
            coordinator.subscribedSessionIDs.count == 1 && coordinator.activeTerminalSessionKey != nil
        }
        XCTAssertTrue(subscribed, "opening a listed sidebar session must persist the tab and subscribe")
        XCTAssertEqual(window.frame, initialWindowFrame, "selecting an Agent must preserve native window geometry")
        guard subscribed, let session = coordinator.activeTerminalSessionKey,
              let inputView = coordinator.terminalView(for: session) else {
            await coordinator.stop()
            window.close()
            return
        }

        let renderedSnapshot = await waitUntil(timeout: .seconds(12)) {
            self.terminalText(coordinator, reference: session.reference).contains("STATIC-LINE-")
        }
        XCTAssertTrue(renderedSnapshot, "the real SNAPSHOT must feed SwiftTerm in the full-app stage")
        let snapshotReceived = await waitUntil(timeout: .seconds(4)) {
            await link.observedEvents().contains { envelope in
                if case let .frame(.snapshot(reference, _)) = envelope.event { return reference == session.reference }
                return false
            }
        }
        XCTAssertTrue(snapshotReceived)

        let marker = "NATIVE-E2E-\(UUID().uuidString)"
        inputView.send(data: Array(marker.utf8)[...])
        inputView.send(data: [0x0d][...])

        let inputSent = await waitUntil(timeout: .seconds(8)) {
            let payloads = await link.sentCommands().compactMap { command -> ClientInputPayload? in
                guard case let .input(request) = command, request.reference == session.reference else { return nil }
                return request.payload
            }
            return payloads.contains(.bytes(Data(marker.utf8))) && payloads.contains(.bytes(Data([0x0d])))
        }
        XCTAssertTrue(inputSent, "SwiftTerm bytes must become real ClientCommand.input messages")
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
            self.terminalText(coordinator, reference: session.reference).contains(marker)
        }
        XCTAssertTrue(echoed, "the DELTA must update SwiftTerm's visible terminal buffer")

        await coordinator.stop()
        window.close()
    }

    /// Restored split panes retain separate SwiftTerm buffers and publish their own viewport grids.
    func testRestoredSplitKeepsIndependentSwiftTermPanesAcrossLayoutChanges() async throws {
        let references = [try SessionReference("split-left"), try SessionReference("split-right")]
        let records = references.enumerated().map { index, reference in
            WireSessionRecord(reference: reference, name: "Split \(index)", workingDirectory: "/fixture/split", state: .idle, rows: 1, columns: 69)
        }
        let link = RecordingSessionLink()
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
            workspaceStore: workspaceStore,
            userPreferencesStore: userPreferencesStore,
            initialWorkspaceState: await workspaceStore.snapshot(),
            initialUserPreferences: await userPreferencesStore.snapshot(),
            environment: ["CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws", "CORRAL_NATIVE_TOKEN": "fixture-only-token", "CORRAL_NATIVE_BACKGROUND": "1"]
        )
        let window = try XCTUnwrap(coordinator.windowController.window)
        window.orderBack(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        coordinator.workspaceView.stageContainer.layoutSubtreeIfNeeded()
        await coordinator.start()
        try await link.emit(.control(.listing(SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(workingDirectory: "/fixture/split", sessionCount: 2, aggregateState: .idle, sessions: records)
        ]))))

        let panesReady = await waitUntil {
            guard let left = coordinator.terminalView(for: references[0]),
                  let right = coordinator.terminalView(for: references[1]) else { return false }
            return coordinator.subscribedSessionIDs.count == 2 && left.terminal.rows > 1 && right.terminal.rows > 1
                && left.terminal.cols > 20 && right.terminal.cols > 20
        }
        let leftMetrics = coordinator.terminalView(for: references[0]).map { "frame=\($0.frame), grid=\($0.terminal.cols)x\($0.terminal.rows), hidden=\($0.isHidden)" } ?? "missing"
        let rightMetrics = coordinator.terminalView(for: references[1]).map { "frame=\($0.frame), grid=\($0.terminal.cols)x\($0.terminal.rows), hidden=\($0.isHidden)" } ?? "missing"
        let paneCommands = await link.commands().filter { command in if case .subscribe = command { true } else if case .resize = command { true } else { false } }
        XCTAssertTrue(panesReady, "both split terminals must size from their own visible viewport; stage=\(coordinator.workspaceView.stageContainer.bounds), visible=\(coordinator.telemetry.visiblePaneCount), subscribed=\(coordinator.subscribedSessionIDs), left=\(leftMetrics), right=\(rightMetrics), commands=\(paneCommands)")
        guard let left = coordinator.terminalView(for: references[0]),
              let right = coordinator.terminalView(for: references[1]) else {
            await coordinator.stop()
            window.close()
            return XCTFail("restored split must create two independent SwiftTerm views")
        }
        XCTAssertFalse(left === right)
        let initialLeftWidth = left.frame.width
        let initialRightWidth = right.frame.width
        let initialLeftGrid = GridSize(rows: left.terminal.rows, columns: left.terminal.cols)
        let initialRightGrid = GridSize(rows: right.terminal.rows, columns: right.terminal.cols)
        let initialResizeCommands = await link.commands().filter { if case .resize = $0 { true } else { false } }.count
        XCTAssertGreaterThan(initialResizeCommands, 0, "actual SwiftTerm geometry must publish viewport resize commands")

        try await link.emit(.frame(.snapshot(reference: references[0], ansi: Data("LEFT-SWIFTTERM".utf8))))
        try await link.emit(.frame(.snapshot(reference: references[1], ansi: Data("RIGHT-SWIFTTERM".utf8))))
        let leftRendered = await waitUntil { self.terminalText(coordinator, reference: references[0]).contains("LEFT-SWIFTTERM") }
        let rightRendered = await waitUntil { self.terminalText(coordinator, reference: references[1]).contains("RIGHT-SWIFTTERM") }
        XCTAssertTrue(leftRendered)
        XCTAssertTrue(rightRendered)

        await coordinator.updateWorkspaceSplitRatio(path: "root", ratio: 0.3)
        let ratioApplied = await waitUntil {
            left.frame.width != initialLeftWidth && right.frame.width != initialRightWidth
        }
        XCTAssertTrue(ratioApplied, "changing the split ratio must lay out the persistent SwiftTerm views")
        let resizedLeft = GridSize(rows: left.terminal.rows, columns: left.terminal.cols)
        let resizedRight = GridSize(rows: right.terminal.rows, columns: right.terminal.cols)
        XCTAssertNotEqual(resizedLeft, initialLeftGrid)
        XCTAssertNotEqual(resizedRight, initialRightGrid)
        await coordinator.closeWorkspacePane(ids[1])
        let remoteCloses = await link.commands().filter { if case .closeSession = $0 { true } else { false } }.count
        XCTAssertEqual(remoteCloses, 0, "closing a pane never terminates its Agent")
        await coordinator.stop()
        window.close()
    }

    func testGoldenFramesDriveThreeSwiftTermPanesAndInputRouting() async throws {
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
            workspaceStore: workspaceStore,
            userPreferencesStore: userPreferencesStore,
            initialWorkspaceState: initialWorkspaceState,
            initialUserPreferences: initialUserPreferences,
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
        coordinator.workspaceView.stageContainer.layoutSubtreeIfNeeded()

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
            coordinator.telemetry.visiblePaneCount == 3 && coordinator.telemetry.nonEmptyLineCount >= 3
                && references.allSatisfy { !self.terminalText(coordinator, reference: $0).isEmpty }
        }
        XCTAssertTrue(rendered, "each pane's SwiftTerm instance must retain its live terminal buffer")

        let paneKey = SessionKey(deviceID: fixtureDeviceID, reference: references[1])
        let commandsBeforeSwitch = await link.commands()
        let subscribedBeforeSwitch = commandsBeforeSwitch.filter { if case .subscribe = $0 { true } else { false } }.count
        let resizeBeforeSwitch = commandsBeforeSwitch.filter { if case .resize = $0 { true } else { false } }.count
        let targetSidebarID = try XCTUnwrap(
            coordinator.workspaceView.sidebar.devices.flatMap(\.sessions).first(where: { $0.name == "Fixture 2" })?.id
        )
        coordinator.selectSidebarSession(id: targetSidebarID)
        let paneFocused = await waitUntil {
            coordinator.activeTerminalSessionKey == paneKey &&
                coordinator.workspaceState.visibleSessionID == workspaceSessionIDs[1]
        }
        XCTAssertTrue(paneFocused, "a sidebar selection must focus its pane in the current workspace Tab")
        let commandsAfterSwitch = await link.commands()
        XCTAssertEqual(commandsAfterSwitch.filter { if case .subscribe = $0 { true } else { false } }.count, subscribedBeforeSwitch)
        XCTAssertEqual(commandsAfterSwitch.filter { if case .resize = $0 { true } else { false } }.count, resizeBeforeSwitch)

        let inputView = try XCTUnwrap(coordinator.terminalView(for: paneKey))
        inputView.send(data: Array("typed".utf8)[...])
        let inputSent = await waitUntil {
            await link.commands().contains { command in
                guard case let .input(request) = command else { return false }
                return request.reference == paneKey.reference && request.payload == .bytes(Data("typed".utf8))
            }
        }
        let commandsAtInput = await link.commands()
        XCTAssertTrue(inputSent, "expected byte input for \(paneKey.reference); payloads=\(commandsAtInput.compactMap { command -> ClientInputPayload? in if case let .input(request) = command { request.payload } else { nil } })")
        let userInputCount = commandsAtInput.filter { if case .input = $0 { true } else { false } }.count
        let terminalReply = Array("\u{1b}[5n".utf8)
        inputView.send(source: inputView.terminal, data: terminalReply[...])
        XCTAssertEqual(coordinator.discardedAutoReplyByteCount, terminalReply.count)
        let inputCountAfterTerminalReply = await link.commands().filter { if case .input = $0 { true } else { false } }.count
        XCTAssertEqual(inputCountAfterTerminalReply, userInputCount, "SwiftTerm protocol responses must not be sent back as user input")

        inputView.feed(byteArray: Array("\u{1b}[?1000h\u{1b}[?1006h".utf8)[...])
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        coordinator.workspaceView.stageContainer.layoutSubtreeIfNeeded()
        let clickLocation = inputView.convert(
            CGPoint(x: inputView.bounds.midX, y: inputView.bounds.midY),
            to: nil
        )
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: clickLocation,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        inputView.mouseDown(with: click)
        let mouseInputSent = await waitUntil {
            await link.commands().contains { command in
                guard case let .input(request) = command,
                      request.reference == paneKey.reference,
                      case let .bytes(bytes) = request.payload else { return false }
                return bytes.starts(with: Data("\u{1b}[<".utf8))
            }
        }
        XCTAssertTrue(mouseInputSent, "SwiftTerm mouse reports must traverse the bound TerminalViewDelegate to the session link")

        inputView.feed(byteArray: Array("\u{1b}[?1006l".utf8)[...])
        let legacyClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: clickLocation,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        ))
        inputView.mouseDown(with: legacyClick)
        let legacyMouseInputSent = await waitUntil {
            await link.commands().contains { command in
                guard case let .input(request) = command,
                      request.reference == paneKey.reference,
                      case let .bytes(bytes) = request.payload else { return false }
                return bytes.starts(with: Data("\u{1b}[M".utf8))
            }
        }
        XCTAssertTrue(legacyMouseInputSent, "SwiftTerm legacy X10 mouse reports must also reach the session link")

        let stillPresented = await waitUntil {
            coordinator.telemetry.visiblePaneCount == 3 && coordinator.telemetry.nonEmptyLineCount >= 3
        }
        XCTAssertTrue(stillPresented)

        await coordinator.flushTelemetry()
        let receiptData = try Data(contentsOf: telemetryURL)
        let receipt = try JSONDecoder().decode(CorralApplicationTelemetry.self, from: receiptData)
        XCTAssertEqual(receipt.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(receipt.connected)
        XCTAssertEqual(receipt.sessionCount, 3)
        XCTAssertEqual(receipt.subscribedSessionIDs.count, 3)
        XCTAssertEqual(receipt.visiblePaneCount, 3)
        XCTAssertGreaterThanOrEqual(receipt.nonEmptyLineCount, 3)
        XCTAssertEqual(receipt.terminalViewCount, 3)
        let stableBufferLineCount = coordinator.telemetry.nonEmptyLineCount
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(coordinator.telemetry.nonEmptyLineCount, stableBufferLineCount)

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
                coordinator.activeTerminalSessionKey?.reference == (try? SessionReference("created-agent")) &&
                commands.contains(.unsubscribe(reference: references[1]))
        }
        XCTAssertTrue(deltaRemovalApplied)
        XCTAssertEqual(coordinator.activeTerminalSessionKey?.reference, try SessionReference("created-agent"))
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
            workspaceStore: workspaceStore,
            userPreferencesStore: userPreferencesStore,
            initialWorkspaceState: await workspaceStore.snapshot(),
            initialUserPreferences: await userPreferencesStore.snapshot(),
            environment: environment
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
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
    private var shouldSuspendNextSubscribe = false
    private var suspendedSubscribeReference: SessionReference?
    private var subscribeRelease: CheckedContinuation<Void, Never>?
    private var shouldSuspendNextResize = false
    private var suspendedResizeGrid: GridSize?
    private var resizeRelease: CheckedContinuation<Void, Never>?

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
        if case let .subscribe(reference, _) = command, shouldSuspendNextSubscribe {
            shouldSuspendNextSubscribe = false
            suspendedSubscribeReference = reference
            await withCheckedContinuation { subscribeRelease = $0 }
            suspendedSubscribeReference = nil
        }
        if case let .resize(_, size) = command, shouldSuspendNextResize {
            shouldSuspendNextResize = false
            suspendedResizeGrid = size
            await withCheckedContinuation { resizeRelease = $0 }
            suspendedResizeGrid = nil
        }
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
    func suspendNextSubscribe() { shouldSuspendNextSubscribe = true }
    func isSubscribeSuspended(for reference: SessionReference) -> Bool {
        suspendedSubscribeReference == reference && subscribeRelease != nil
    }
    func releaseSuspendedSubscribe() {
        subscribeRelease?.resume()
        subscribeRelease = nil
    }
    func suspendNextResize() { shouldSuspendNextResize = true }
    func isResizeSuspended(at grid: GridSize) -> Bool { suspendedResizeGrid == grid && resizeRelease != nil }
    func releaseSuspendedResize() {
        resizeRelease?.resume()
        resizeRelease = nil
    }

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
