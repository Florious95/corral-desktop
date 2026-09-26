import AppKit
import CorralContracts
@testable import CorralUI
import XCTest

@MainActor
final class NativeWorkspaceTests: XCTestCase {
    func testLegacyThemeTokensAndSettingsButtons() throws {
        CorralAestheticTokens.themeMode = .dark
        XCTAssertEqual(rgb(CorralAestheticTokens.surface0), 0x171B22)
        XCTAssertEqual(rgb(CorralAestheticTokens.surface1), 0x1E242D)
        XCTAssertEqual(rgb(CorralAestheticTokens.surface2), 0x272F3A)
        XCTAssertEqual(rgb(CorralAestheticTokens.text), 0xE5E7EB)
        XCTAssertEqual(DesignTokens.Color.surface0, 0x171B22)

        let workspace = CorralWorkspaceView()
        for button in [workspace.tabBar.settingsButton, workspace.sidebar.settingsButton] {
            XCTAssertEqual(button.contentTintColor, CorralAestheticTokens.text)
            XCTAssertEqual(button.layer?.borderWidth, 1)
            XCTAssertEqual(button.layer?.borderColor, CorralAestheticTokens.border.cgColor)
            XCTAssertEqual(button.layer?.backgroundColor, CorralAestheticTokens.surface2.cgColor)
        }
        XCTAssertEqual(workspace.titleBar.layer?.backgroundColor, CorralAestheticTokens.surface0.cgColor)
        XCTAssertEqual(workspace.sidebar.layer?.backgroundColor, CorralAestheticTokens.surface0.cgColor)

        CorralAestheticTokens.themeMode = .light
        XCTAssertEqual(rgb(CorralAestheticTokens.surface0), 0xF5F3EF)
        XCTAssertEqual(rgb(CorralAestheticTokens.surface1), 0xFDFCFB)
        XCTAssertEqual(CorralAestheticTokens.providerIdleOpacity, 0.4)
        CorralAestheticTokens.themeMode = .dark
    }

    func testAllExtractedLegacyIconsLoadAsNativeAppKitImages() {
        XCTAssertEqual(CorralLegacyIcon.allCases.count, 25)
        for icon in CorralLegacyIcon.allCases {
            XCTAssertNotNil(CorralLegacyIcon.image(icon, size: 16), "Missing native icon: \\(icon.rawValue)")
        }
        XCTAssertNotNil(CorralProviderIconView(provider: "claude_code").image)
        XCTAssertNotNil(CorralProviderIconView(provider: "codex").image)
        XCTAssertNotNil(CorralProviderIconView(provider: "copilot").image)
        XCTAssertNotNil(CorralProviderIconView(provider: "grok").image)
        XCTAssertNotNil(CorralProviderIconView(provider: "cursor").image)
        XCTAssertNotNil(CorralProviderIconView(provider: "pi").image)
    }

    func testWorkspaceThemeChangeRefreshesAppKitSurfacesInPlace() {
        let tab = CorralTab(title: "Terminal", contentView: NSView())
        let workspace = CorralWorkspaceView(tabs: [tab])
        workspace.setTheme(.light)
        XCTAssertEqual(rgb(workspace.sidebar.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) ?? .clear), 0xF5F3EF)
        XCTAssertEqual(rgb(workspace.tabBar.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) ?? .clear), 0xF5F3EF)
        XCTAssertEqual(rgb(workspace.stageContainer.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) ?? .clear), 0xFBFAF8)
        XCTAssertEqual(rgb(workspace.sidebar.agentsTable.backgroundColor), 0xF5F3EF)
        XCTAssertEqual(rgb(workspace.sidebar.settingsButton.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) ?? .clear), 0xFFFFFF)
        workspace.setTheme(.dark)
        XCTAssertEqual(rgb(workspace.sidebar.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) ?? .clear), 0x171B22)
    }

    func testWorkspaceHasLegacyLeftSidebarAndIndependentHeaders() {
        let workspace = CorralWorkspaceView()
        workspace.frame = NSRect(x: 0, y: 0, width: 1400, height: 860)
        workspace.layoutSubtreeIfNeeded()
        XCTAssertEqual(CorralWorkspaceView.sidebarWidth, 280)
        XCTAssertEqual(CorralWorkspaceView.headerHeight, 38)
        XCTAssertEqual(workspace.titleBar.frame.height, 38, accuracy: 0.1)
        XCTAssertEqual(workspace.tabBar.frame.height, 38, accuracy: 0.1)
        XCTAssertEqual(workspace.titleBar.frame.width, 280, accuracy: 0.1)
        XCTAssertEqual(workspace.sidebar.frame.width, 280, accuracy: 0.1)
        XCTAssertEqual(workspace.tabBar.frame.width, 1120, accuracy: 0.1)
    }

    func testSidebarHasSpacesAndAgentsAndExactAgentContextMenu() throws {
        let sidebar = CorralSidebarView()
        let favorite = CorralSidebarAgent(name: "Favorite", provider: "claude_code", isFavorite: true)
        let agent = CorralSidebarAgent(name: "Agent", status: .working, provider: "codex")
        let virtualID = CorralSidebarSpace.allSpacesID
        let spaceID = UUID()
        sidebar.setSpaces([
            CorralSidebarSpace(id: spaceID, name: "Project", workingCount: 1, agentCount: 2)
        ])
        sidebar.setAgents([agent, favorite])

        XCTAssertEqual(sidebar.spacesTable.dataSource?.numberOfRows?(in: sidebar.spacesTable), 3)
        XCTAssertEqual(sidebar.agentsTable.dataSource?.numberOfRows?(in: sidebar.agentsTable), 2)
        XCTAssertEqual(sidebar.agents.first?.id, favorite.id)
        XCTAssertNil(sidebar.spaceContextMenu(for: virtualID))
        XCTAssertEqual(sidebar.spaceContextMenu(for: spaceID)?.items.map(\.title), ["新建 Agent"])

        var favoriteChange: (UUID, Bool)?
        var closed: UUID?
        sidebar.onToggleFavorite = { favoriteChange = ($0, $1) }
        sidebar.onCloseAgent = { closed = $0 }
        let menu = try XCTUnwrap(sidebar.agentContextMenu(for: agent.id))
        XCTAssertEqual(menu.items.map(\.title), ["收藏", "", "关闭"])
        XCTAssertFalse(menu.items.contains { $0.title.localizedCaseInsensitiveContains("rename") || $0.title.localizedCaseInsensitiveContains("split") })
        XCTAssertTrue(menu.items.allSatisfy { $0.isSeparatorItem || $0.target != nil })
        let favoriteItem = try XCTUnwrap(menu.items.first)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(favoriteItem.action), to: favoriteItem.target, from: favoriteItem))
        XCTAssertEqual(favoriteChange?.0, agent.id)
        XCTAssertEqual(favoriteChange?.1, true)
        let closeItem = try XCTUnwrap(menu.items.last)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(closeItem.action), to: closeItem.target, from: closeItem))
        XCTAssertEqual(closed, agent.id)
        XCTAssertEqual(sidebar.agentContextMenu(for: favorite.id)?.items.first?.title, "取消收藏")
    }

    func testSpacesRowsFilterAgentsByFavoritesAndWorkspaceAndCanCollapse() {
        let spaceID = UUID()
        let favorite = CorralSidebarAgent(name: "Favorite", spaceID: spaceID, isFavorite: true)
        let regular = CorralSidebarAgent(name: "Regular", spaceID: spaceID)
        let other = CorralSidebarAgent(name: "Other", isFavorite: true)
        let sidebar = CorralSidebarView()
        sidebar.setSpaces([CorralSidebarSpace(id: spaceID, name: "Project")])
        sidebar.setAgents([favorite, regular, other])
        XCTAssertEqual(sidebar.agents.count, 3)
        sidebar.spacesTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(sidebar.agents.map(\.id), [favorite.id, other.id])
        sidebar.spacesTable.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertEqual(sidebar.agents.map(\.id), [favorite.id, regular.id])
        sidebar.setSpacesExpanded(false)
        sidebar.setAgentsExpanded(false)
        XCTAssertFalse(sidebar.spacesExpanded)
        XCTAssertFalse(sidebar.agentsExpanded)
        sidebar.setSpacesExpanded(true)
        sidebar.setAgentsExpanded(true)
        XCTAssertTrue(sidebar.spacesExpanded)
        XCTAssertTrue(sidebar.agentsExpanded)
    }

    func testOnlyRealSpaceRowsOfferInlineAgentCreation() throws {
        let sidebar = CorralSidebarView()
        let workspaceID = UUID()
        sidebar.setSpaces([CorralSidebarSpace(id: workspaceID, name: "Project")])
        var selectedSpace: UUID?
        sidebar.onCreateAgent = { selectedSpace = $0 }
        let virtualRow = try XCTUnwrap(sidebar.spacesTable.delegate?.tableView?(sidebar.spacesTable, viewFor: nil, row: 0))
        XCTAssertFalse(descendants(of: virtualRow).compactMap { $0 as? NSButton }.contains { $0.toolTip?.contains("新建") == true })
        XCTAssertNil(sidebar.spaceContextMenu(for: CorralSidebarSpace.allSpacesID))
        let workspaceRow = try XCTUnwrap(sidebar.spacesTable.delegate?.tableView?(sidebar.spacesTable, viewFor: nil, row: 2))
        try XCTUnwrap(descendants(of: workspaceRow).compactMap { $0 as? NSButton }.first { $0.toolTip?.contains("新建") == true }).performClick(nil)
        XCTAssertEqual(selectedSpace, workspaceID)
    }

    func testAgentBadgeHidesForSingleDeviceAndTruncatesMultiDeviceNames() throws {
        let badge = CorralDeviceBadgeView(frame: .zero)
        let longName = String(repeating: "Remote device ", count: 8)
        badge.update(deviceName: longName, deviceCount: 1)
        XCTAssertTrue(badge.isHidden)
        XCTAssertNil(badge.toolTip)
        badge.update(deviceName: longName, deviceCount: 2)
        badge.frame = NSRect(x: 0, y: 0, width: 64, height: 18)
        badge.layoutSubtreeIfNeeded()
        XCTAssertFalse(badge.isHidden)
        XCTAssertLessThanOrEqual(badge.maximumWidth, 64)
        XCTAssertEqual(badge.toolTip, longName)
        XCTAssertEqual(badge.titleLabel.toolTip, longName)
        XCTAssertEqual(badge.titleLabel.cell?.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(badge.layer?.cornerRadius, 9)

        let singleSidebar = CorralSidebarView(devices: [CorralSidebarDevice(name: longName, sessions: [CorralSidebarSession(name: "shell")])])
        let multiSidebar = CorralSidebarView(devices: [
            CorralSidebarDevice(name: longName, sessions: [CorralSidebarSession(name: "shell")]),
            CorralSidebarDevice(name: "Second")
        ])
        XCTAssertTrue(try XCTUnwrap(badgeInFirstAgentRow(singleSidebar)).isHidden)
        XCTAssertFalse(try XCTUnwrap(badgeInFirstAgentRow(multiSidebar)).isHidden)
        XCTAssertEqual(badgeInFirstAgentRow(multiSidebar)?.toolTip, longName)
    }

    func testWorkingIndicatorIsStaticAndUsesLegacyStateColors() {
        let indicator = CorralStatusIndicatorView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        indicator.status = .working
        XCTAssertEqual(indicator.layer?.animationKeys()?.count ?? 0, 0)
        XCTAssertEqual(indicator.layer?.shadowColor, CorralAestheticTokens.success.cgColor)
        XCTAssertEqual(indicator.layer?.shadowOpacity, 0.45)
        indicator.status = .blocked
        XCTAssertEqual(indicator.layer?.shadowColor, CorralAestheticTokens.warning.cgColor)
        indicator.status = .idle
        XCTAssertEqual(indicator.layer?.shadowOpacity, 0)
    }

    func testNestedSplitRetainsStageViewsAndHighlightsFocus() throws {
        let firstID = SessionID("first")
        let secondID = SessionID("second")
        let thirdID = SessionID("third")
        let first = NSView()
        let second = NSView()
        let third = NSView()
        let root = WorkspaceLayoutNode.split(direction: .horizontal, ratio: 0.6,
            first: .session(firstID),
            second: .split(direction: .vertical, ratio: 0.5, first: .session(secondID), second: .session(thirdID)))
        let workspace = SplitWorkspaceView(root: root, stageViews: [firstID: first, secondID: second, thirdID: third])
        XCTAssertEqual(workspace.splitterCount, 2)
        XCTAssertEqual(workspace.stageViews.count, 3)
        let rootSplit = try XCTUnwrap(workspace.subviews.first as? NSSplitView)
        XCTAssertTrue(rootSplit.isVertical)
        let nested = try XCTUnwrap(rootSplit.arrangedSubviews.compactMap { $0 as? NSSplitView }.first)
        XCTAssertFalse(nested.isVertical)
        XCTAssertTrue(first.superview != nil)
        XCTAssertTrue(second.superview != nil)
        XCTAssertTrue(third.superview != nil)
        workspace.focus(secondID)
        XCTAssertEqual(workspace.focusedSessionID, secondID)
        XCTAssertEqual(second.layer?.borderWidth, 2)
        XCTAssertEqual(first.layer?.borderWidth, 0)
    }

    func testDropZoneSelectsFiveLegacyDropRegions() {
        let stage = CorralWorkspaceStageView()
        XCTAssertEqual(stage.edge(at: NSPoint(x: 0.1, y: 0.5)), .left)
        XCTAssertEqual(stage.edge(at: NSPoint(x: 0.9, y: 0.5)), .right)
        XCTAssertEqual(stage.edge(at: NSPoint(x: 0.5, y: 0.9)), .top)
        XCTAssertEqual(stage.edge(at: NSPoint(x: 0.5, y: 0.1)), .bottom)
        XCTAssertEqual(stage.edge(at: NSPoint(x: 0.5, y: 0.5)), .center)
    }

    func testSmartOpenSessionFocusesExistingFillsBlankOrUsesPreviewWithoutDuplicateTab() {
        let existingSession = UUID()
        let existing = CorralTab(title: "Existing", contentView: NSView(), sessionIDs: [existingSession], isBlankWorkspace: false)
        let blank = CorralTab(title: "Blank", contentView: NSView(), isBlankWorkspace: true)
        let workspace = CorralWorkspaceView(tabs: [existing, blank])
        var focused: (UUID, UUID)?
        var opened: (UUID, UUID?, Bool)?
        workspace.onFocusSession = { focused = ($0, $1) }
        workspace.onOpenSession = { opened = ($0, $1, $2) }

        workspace.selectTab(id: blank.id)
        workspace.smartOpenSession(existingSession)
        XCTAssertEqual(workspace.activeTabID, existing.id)
        XCTAssertEqual(focused?.0, existingSession)
        XCTAssertEqual(focused?.1, existing.id)
        XCTAssertNil(opened)

        workspace.selectTab(id: blank.id)
        let filledSession = UUID()
        workspace.smartOpenSession(filledSession)
        XCTAssertFalse(blank.isBlankWorkspace)
        XCTAssertTrue(blank.sessionIDs.contains(filledSession))
        XCTAssertEqual(opened?.0, filledSession)
        XCTAssertEqual(opened?.1, blank.id)
        XCTAssertEqual(opened?.2, false)

        let previewSession = UUID()
        workspace.smartOpenSession(previewSession)
        XCTAssertEqual(workspace.previewSessionID, previewSession)
        XCTAssertEqual(opened?.0, previewSession)
        XCTAssertEqual(opened?.1, blank.id)
        XCTAssertEqual(opened?.2, true)
        XCTAssertEqual(workspace.tabs.count, 2)
    }

    func testPinnedTabsStayLeftAndRegularSelectionShowsActiveCapsule() throws {
        let pinned = CorralTab(title: "Pinned", isPinned: true, provider: "codex")
        let first = CorralTab(title: "First")
        let second = CorralTab(title: "Second")
        let workspace = CorralWorkspaceView(tabs: [first, pinned, second])
        workspace.frame = NSRect(x: 0, y: 0, width: 1400, height: 860)
        workspace.layoutSubtreeIfNeeded(); workspace.tabBar.layoutSubtreeIfNeeded()
        XCTAssertEqual(workspace.tabs.map(\.id), [pinned.id, first.id, second.id])
        XCTAssertNil(workspace.tabBar.activeCapsuleFrame)
        workspace.selectTab(id: first.id)
        workspace.layoutSubtreeIfNeeded(); workspace.tabBar.layoutSubtreeIfNeeded()
        let capsule = try XCTUnwrap(workspace.tabBar.activeCapsuleFrame)
        XCTAssertGreaterThan(capsule.width, 0)
        workspace.reorderTab(id: first.id, to: 2)
        XCTAssertEqual(workspace.tabs.map(\.id), [pinned.id, second.id, first.id])
    }

    func testTabSwitchPreserves45RowSnapshotAndRecordsNoTerminalWork() throws {
        let snapshot = makeSnapshot(rows: 45, columns: 12)
        XCTAssertTrue(snapshot.isValid)
        let first = CorralTab(title: "History", contentView: NSView(), terminalSnapshot: snapshot)
        let second = CorralTab(title: "Other", contentView: NSView())
        let workspace = CorralWorkspaceView(tabs: [first, second])
        let originalParent = first.contentView.superview
        for _ in 0..<3 {
            workspace.selectTab(id: second.id)
            workspace.selectTab(id: first.id)
            XCTAssertTrue(workspace.tabSwitchTelemetry.allCountsAreZero)
            XCTAssertFalse(workspace.tabSwitchTelemetry.isRecordingSwitch)
        }
        XCTAssertEqual(first.terminalSnapshot, snapshot)
        XCTAssertEqual(first.terminalSnapshot?.size.rows, 45)
        XCTAssertEqual(first.terminalSnapshot?.cells.count, 45 * 12)
        XCTAssertTrue(first.contentView.superview === originalParent)
        XCTAssertEqual(workspace.stageContainer.subviews.filter { $0 === first.contentView || $0 === second.contentView }.count, 2)
    }

    func testWindowDoubleClickZoomStaysInVisibleFrameAndRestoresExactFrame() throws {
        let initial = NSRect(x: 41.25, y: 72.5, width: 780.5, height: 510.25)
        let controller = CorralWindowController(workspaceView: CorralWorkspaceView(), contentRect: initial)
        let window = try XCTUnwrap(controller.window as? CorralWindow)
        let original = window.frame
        let visibleFrame = NSRect(x: 70, y: 40, width: 1220, height: 820)
        controller.toggleZoom(to: visibleFrame)
        XCTAssertEqual(window.frame, visibleFrame)
        XCTAssertGreaterThanOrEqual(window.frame.minX, visibleFrame.minX)
        XCTAssertGreaterThanOrEqual(window.frame.minY, visibleFrame.minY)
        XCTAssertLessThanOrEqual(window.frame.maxX, visibleFrame.maxX)
        XCTAssertLessThanOrEqual(window.frame.maxY, visibleFrame.maxY)
        XCTAssertEqual(controller.savedFrameBeforeZoom, original)
        controller.toggleZoom(to: visibleFrame)
        XCTAssertEqual(window.frame, original)
        XCTAssertNil(controller.savedFrameBeforeZoom)
    }

    func testWindowUsesTransparentFullSizeNativeTitlebar() {
        let window = CorralWindow(title: "Test")
        XCTAssertTrue(window.backgroundColor.isEqual(CorralAestheticTokens.surface0))
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
    }

    func testNewAgentDialogUsesAdvertisedLaunchersAndValidatesName() throws {
        let dialog = NewAgentDialogViewController(spaceName: "Project")
        dialog.loadViewIfNeeded()
        XCTAssertEqual(dialog.launchers.count, 5)
        XCTAssertEqual(dialog.selectedProvider, "claude_code")
        XCTAssertFalse(dialog.isCreateEnabled)
        dialog.nameField.stringValue = "  Fix parser  "
        dialog.controlTextDidChange(Notification(name: Notification.Name("NameChanged"), object: dialog.nameField))
        XCTAssertTrue(dialog.isCreateEnabled)
        var request: CorralNewAgentRequest?
        dialog.onCreate = { request = $0 }
        dialog.submit()
        XCTAssertEqual(request, CorralNewAgentRequest(name: "Fix parser", provider: "claude_code", bypass: false))
        dialog.nameField.stringValue = String(repeating: "a", count: 65)
        dialog.submit()
        XCTAssertEqual(dialog.validationMessage, "名称不能超过 64 个字符")
        XCTAssertEqual(request?.name, "Fix parser")
    }

    func testSettingsDialogPersistsThemeFontSizeAndTrackingChanges() throws {
        var changes: [CorralSettingsValues] = []
        let dialog = SettingsDialogViewController(onChange: { changes.append($0) })
        dialog.loadViewIfNeeded()
        dialog.setTheme(.light)
        dialog.setFontFamily("Courier New")
        dialog.setFontSize(99)
        dialog.setDirectoryTracking(true)
        XCTAssertEqual(dialog.values.theme, .light)
        XCTAssertEqual(dialog.values.fontFamily, "Courier New")
        XCTAssertEqual(dialog.values.fontSize, 24)
        XCTAssertTrue(dialog.values.directoryTracking)
        XCTAssertEqual(dialog.themeControl.selectedSegment, 0)
        XCTAssertEqual(dialog.fontSizeSlider.doubleValue, 24)
        XCTAssertEqual(dialog.fontSizeStepper.doubleValue, 24)
        XCTAssertEqual(changes.count, 4)
        XCTAssertEqual(dialog.fontPreviewLabel?.font?.pointSize, 24)
        XCTAssertEqual(dialog.fontFamilyPopup.numberOfItems, 6)
    }

    func testToastUsesSingleReplaceableSlotAnd2500MillisecondDefault() throws {
        let manager = ToastManager.shared
        manager.dismissCurrent()
        XCTAssertEqual(manager.duration, 2.5)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        manager.show("Saved", kind: .success, in: host)
        let first = try XCTUnwrap(manager.currentToast)
        XCTAssertEqual(first.messageLabel.stringValue, "Saved")
        XCTAssertTrue(host.subviews.contains { $0 === first })
        manager.show("Replaced", kind: .warning, in: host)
        let second = try XCTUnwrap(manager.currentToast)
        XCTAssertFalse(first === second)
        XCTAssertFalse(host.subviews.contains { $0 === first })
        XCTAssertEqual(second.messageLabel.stringValue, "Replaced")
        manager.dismissCurrent()
        XCTAssertNil(manager.currentToast)
    }

    func testAddDeviceAcceptsPairingJSONAndValidatesEndpoint() throws {
        let dialog = AddDeviceDialogViewController()
        dialog.loadViewIfNeeded()
        XCTAssertFalse(dialog.acceptPairingJSON("not-json"))
        XCTAssertTrue(dialog.acceptPairingJSON("""
        {"url":"wss://device.example/ws","token":"secret","name":"Studio","candidates":["wss://device.example/ws"]}
        """))
        XCTAssertEqual(dialog.tokenField.isBezeled, true)
        var request: CorralAddDeviceRequest?
        dialog.onSubmit = { request = $0 }
        dialog.submit()
        XCTAssertEqual(request?.name, "Studio")
        XCTAssertEqual(request?.url, "wss://device.example/ws")
        XCTAssertEqual(request?.token, "secret")
        XCTAssertEqual(request?.candidates, ["wss://device.example/ws"])
        dialog.addressField.stringValue = "http://invalid.example"
        dialog.submit()
        XCTAssertEqual(dialog.validationMessage, "地址必须以 ws:// 或 wss:// 开头")
        XCTAssertEqual(request?.url, "wss://device.example/ws")
    }

    func testPairingDialogCreatesQRForProvidedCredential() throws {
        let payload = CorralPairingPayload(url: "wss://device.example/ws", token: "secret", name: "Studio", candidates: ["wss://device.example/ws"], hostID: "host-id")
        let dialog = PairingDialogViewController(payload: payload)
        dialog.loadViewIfNeeded()
        XCTAssertNotNil(dialog.qrImage)
        XCTAssertTrue(try XCTUnwrap(dialog.pairingText).contains("\"token\":\"secret\""))
        XCTAssertTrue(try XCTUnwrap(dialog.pairingText).contains("\"host_id\":\"host-id\""))
    }

    func testCloseAgentDialogRequiresExplicitConfirmAndHasLegacyCopy() throws {
        var confirms = 0
        var cancels = 0
        let dialog = CloseAgentDialogViewController(agentName: "My Agent", onConfirm: { confirms += 1 }, onCancel: { cancels += 1 })
        dialog.loadViewIfNeeded()
        let labels = descendants(of: dialog.view).compactMap { ($0 as? NSButton)?.title }
        XCTAssertTrue(labels.contains("关闭 Agent"))
        XCTAssertTrue(descendants(of: dialog.view).compactMap { ($0 as? NSTextField)?.stringValue }.contains("这会终止当前 Agent 会话，未保存的工作可能会丢失。"))
        dialog.handleEscape()
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(confirms, 0)
        dialog.confirmAction()
        XCTAssertEqual(confirms, 1)
    }

    func testDevicePopoverRenameHonorsIMEAndPersistsToRepository() async throws {
        let record = try makeDeviceRecord()
        let repository = TestDeviceRepository(records: [record])
        let controller = DevicesPopoverViewController(repository: repository)
        controller.loadViewIfNeeded()
        try await controller.reloadDevices()
        controller.beginRenaming(record.id)
        XCTAssertEqual(controller.editingDeviceID, record.id)
        XCTAssertFalse(DevicesPopoverViewController.shouldCommitReturn(hasMarkedText: true))
        let imeCommit = try await controller.commitRenaming(record.id, to: "名称", hasMarkedText: true)
        XCTAssertFalse(imeCommit)
        let savedDuringComposition = await repository.savedDevices()
        XCTAssertEqual(savedDuringComposition.count, 0)
        controller.cancelRenaming(record.id)
        XCTAssertNil(controller.editingDeviceID)
        XCTAssertEqual(controller.devices.first?.name, record.name)
        controller.beginRenaming(record.id)
        let committed = try await controller.commitRenaming(record.id, to: "Renamed Device")
        XCTAssertTrue(committed)
        XCTAssertEqual(controller.devices.first?.name, "Renamed Device")
        let savedAfterRename = await repository.savedDevices()
        XCTAssertEqual(savedAfterRename.first?.name, "Renamed Device")
    }

    func testDevicePopoverRequiresSecondConfirmationBeforeCascadeDelete() async throws {
        let record = try makeDeviceRecord()
        let repository = TestDeviceRepository(records: [record])
        let controller = DevicesPopoverViewController(repository: repository)
        controller.loadViewIfNeeded()
        try await controller.reloadDevices()
        let prematureDelete = try await controller.confirmDeletion(of: record.id)
        XCTAssertFalse(prematureDelete)
        let deletionsBeforeConfirmation = await repository.deletedIDs()
        XCTAssertTrue(deletionsBeforeConfirmation.isEmpty)
        controller.requestDeletion(of: record.id)
        XCTAssertEqual(controller.deletionConfirmationDeviceID, record.id)
        let row = try XCTUnwrap(controller.tableView(controller.tableView, viewFor: nil, row: 0))
        XCTAssertTrue(buttonTitles(in: row).contains { $0.contains("删除") || $0.contains("确认") })
        let confirmedDelete = try await controller.confirmDeletion(of: record.id)
        XCTAssertTrue(confirmedDelete)
        let deletionsAfterConfirmation = await repository.deletedIDs()
        XCTAssertEqual(deletionsAfterConfirmation, [record.id])
        XCTAssertTrue(controller.devices.isEmpty)
    }

    private func rgb(_ color: NSColor) -> UInt32 {
        let color = color.usingColorSpace(.sRGB)!
        return UInt32(color.redComponent * 255 + 0.5) << 16
            | UInt32(color.greenComponent * 255 + 0.5) << 8
            | UInt32(color.blueComponent * 255 + 0.5)
    }

    private func badgeInFirstAgentRow(_ sidebar: CorralSidebarView) -> CorralDeviceBadgeView? {
        guard let row = sidebar.agentsTable.delegate?.tableView?(sidebar.agentsTable, viewFor: nil, row: 0) else { return nil }
        return descendants(of: row).compactMap { $0 as? CorralDeviceBadgeView }.first
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func buttonTitles(in view: NSView) -> [String] {
        var titles = (view as? NSButton).map { [$0.title] } ?? []
        for subview in view.subviews { titles += buttonTitles(in: subview) }
        return titles
    }

    private func makeSnapshot(rows: Int, columns: Int) -> TerminalGridSnapshot {
        let foreground = TerminalColor.rgba(RGBAColor(red: 230, green: 231, blue: 235))
        let background = TerminalColor.rgba(RGBAColor(red: 23, green: 27, blue: 34))
        let cells = (0..<(rows * columns)).map { index in
            TerminalCell(content: .cluster(String(UnicodeScalar(33 + index % 80)!), columns: .one), foreground: foreground, background: background)
        }
        return TerminalGridSnapshot(size: GridSize(rows: rows, columns: columns), cells: cells, cursor: CursorDescriptor(row: rows - 1, column: columns - 1), generation: .initial)
    }

    private func makeDeviceRecord(id: String = "device-1", name: String = "Laptop") throws -> DeviceRecord {
        DeviceRecord(id: DeviceID(id), name: name, endpoint: try ApprovedEndpoint(host: "127.0.0.1", port: ApprovedEndpoint.developmentPort), credential: CredentialHandle("credential-\(id)"))
    }
}

private actor TestDeviceRepository: DeviceRepositoryProtocol {
    private var records: [DeviceRecord]
    private var saved: [DeviceRecord] = []
    private var deleted: [DeviceID] = []
    init(records: [DeviceRecord]) { self.records = records }
    func listDevices() async throws -> [DeviceRecord] { records }
    func save(_ device: DeviceRecord) async throws {
        saved.append(device)
        if let index = records.firstIndex(where: { $0.id == device.id }) { records[index] = device }
    }
    func delete(id: DeviceID) async throws { deleted.append(id); records.removeAll { $0.id == id } }
    func savedDevices() -> [DeviceRecord] { saved }
    func deletedIDs() -> [DeviceID] { deleted }
}
