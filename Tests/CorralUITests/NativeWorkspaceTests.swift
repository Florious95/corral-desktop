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
        let settingsButton = workspace.sidebar.settingsButton
        // `.sidebar-settings-btn`: borderless 34px icon button, transparent until hover.
        XCTAssertEqual(settingsButton.contentTintColor, CorralAestheticTokens.icon)
        XCTAssertEqual(settingsButton.layer?.borderWidth, 0)
        XCTAssertEqual(settingsButton.layer?.cornerRadius, 6)
        XCTAssertEqual(settingsButton.layer?.backgroundColor?.alpha, 0)
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
        XCTAssertEqual(workspace.sidebar.settingsButton.layer?.backgroundColor?.alpha, 0)
        XCTAssertEqual(rgb(workspace.sidebar.settingsButton.contentTintColor ?? .clear), 0x8A867E)
        workspace.setTheme(.dark)
        XCTAssertEqual(rgb(workspace.sidebar.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) ?? .clear), 0x171B22)
    }

    func testWorkspaceHasLegacyLeftSidebarAndIndependentHeaders() {
        let workspace = CorralWorkspaceView()
        XCTAssertEqual(CorralWorkspaceView.sidebarWidth, 280)
        XCTAssertEqual(CorralWorkspaceView.headerHeight, 38)
        for size in [NSSize(width: 1100, height: 700), NSSize(width: 1400, height: 860), NSSize(width: 1920, height: 1080)] {
            workspace.frame = NSRect(origin: .zero, size: size)
            workspace.layoutSubtreeIfNeeded()
            XCTAssertEqual(workspace.titleBar.frame.height, 38, accuracy: 0.1)
            XCTAssertEqual(workspace.tabBar.frame.height, 38, accuracy: 0.1)
            XCTAssertEqual(workspace.titleBar.frame.width, 280, accuracy: 0.1)
            XCTAssertEqual(workspace.sidebar.frame.width, 280, accuracy: 0.1)
            XCTAssertEqual(workspace.tabBar.frame.width, size.width - 280, accuracy: 0.1)
            XCTAssertEqual(workspace.stageContainer.frame.height, size.height - 38, accuracy: 0.1)
        }
        workspace.setSidebarCollapsed(true)
        workspace.layoutSubtreeIfNeeded()
        XCTAssertEqual(workspace.sidebar.frame.width, 0, accuracy: 0.1)
        XCTAssertEqual(workspace.tabBar.frame.width, 1920, accuracy: 0.1)
        XCTAssertEqual(workspace.tabBar.frame.height, 38, accuracy: 0.1)
        XCTAssertEqual(workspace.stageContainer.frame.height, 1080 - 38, accuracy: 0.1)
    }

    func testHeaderActionSetMatchesLegacyChrome() throws {
        let workspace = CorralWorkspaceView()
        workspace.frame = NSRect(x: 0, y: 0, width: 1400, height: 860)
        workspace.layoutSubtreeIfNeeded()
        let rightButtons = descendants(of: workspace.tabBar).compactMap { $0 as? NSButton }.filter { !$0.isHidden }
        XCTAssertEqual(rightButtons.count, 1)
        XCTAssertTrue(rightButtons[0] === workspace.tabBar.createButton)
        XCTAssertEqual(workspace.tabBar.createButton.toolTip, "新建工作台标签页 (⌘T)")
        let leftButtons = descendants(of: workspace.titleBar).compactMap { $0 as? NSButton }
        XCTAssertEqual(leftButtons.count, 1)
        XCTAssertEqual(leftButtons[0].frame.minX, 88, accuracy: 0.1)
        XCTAssertEqual(leftButtons[0].frame.midY, 19, accuracy: 0.1)
        XCTAssertTrue(workspace.tabBar.sidebarToggleButton === leftButtons[0])
        XCTAssertTrue(workspace.tabBar.devicesButton === workspace.sidebar.devicesButton)

        workspace.tabBar.sidebarToggleButton.performClick(nil)
        workspace.layoutSubtreeIfNeeded()
        let collapsedButtons = descendants(of: workspace.tabBar).compactMap { $0 as? NSButton }.filter { !$0.isHidden }
        XCTAssertEqual(collapsedButtons.count, 2)
        let expandButton = try XCTUnwrap(collapsedButtons.first { $0.toolTip == "展开侧栏" })
        XCTAssertEqual(expandButton.frame.minX, 88, accuracy: 0.1)
        XCTAssertEqual(expandButton.frame.midY, 19, accuracy: 0.1)
        XCTAssertTrue(workspace.titleBar.isHidden)
        XCTAssertTrue(workspace.sidebar.isHidden)
        expandButton.performClick(nil)
        XCTAssertFalse(workspace.isSidebarCollapsed)
        XCTAssertFalse(workspace.titleBar.isHidden)
    }

    func testWindowOwnsFixedDefaultAndMinimumGeometryAcrossContentChanges() throws {
        let workspace = CorralWorkspaceView(tabs: [CorralTab(title: "Initial", contentView: NSView())])
        let controller = CorralWindowController(workspaceView: workspace)
        let window = try XCTUnwrap(controller.window as? CorralWindow)
        let initialFrame = window.frame
        let initialContentBounds = try XCTUnwrap(window.contentView).bounds
        XCTAssertEqual(initialContentBounds.size, NSSize(width: 1400, height: 860))
        XCTAssertEqual(window.minSize, NSSize(width: 1100, height: 700))
        XCTAssertEqual(window.contentMinSize, NSSize(width: 1100, height: 700))

        let spaces = (0..<12).map { CorralSidebarSpace(id: UUID(), name: "Space \($0) · \(String(repeating: "Long", count: 8))") }
        workspace.sidebar.setSpaces(spaces)
        workspace.sidebar.setAgents((0..<40).map { CorralSidebarAgent(name: "Agent \($0) · \(String(repeating: "X", count: 48))") })
        workspace.sidebar.spacesTable.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertEqual(workspace.sidebar.selectedSpaceID, spaces[0].id)
        for index in 0..<12 {
            workspace.addTab(CorralTab(title: "Long workspace title \(index) · \(String(repeating: "T", count: 24))", contentView: NSView()), select: false)
        }
        workspace.setSidebarCollapsed(true)
        workspace.setSidebarCollapsed(false)
        workspace.setTheme(.light)
        for index in 12..<40 {
            workspace.addTab(CorralTab(title: "Overflow \(index)", contentView: NSView()), select: false)
        }
        workspace.sidebar.selectSpace(id: spaces[3].id)
        window.layoutIfNeeded()
        workspace.tabBar.layoutSubtreeIfNeeded()
        let plusFrame = workspace.tabBar.convert(workspace.tabBar.createButton.bounds, from: workspace.tabBar.createButton)
        XCTAssertLessThanOrEqual(plusFrame.maxX, workspace.tabBar.bounds.maxX)
        XCTAssertEqual(window.frame, initialFrame)
        XCTAssertEqual(window.contentView?.bounds, initialContentBounds)

        // Content must never pin the window open: the controller can still shrink it to the minimum.
        let minimumFrame = NSRect(origin: initialFrame.origin, size: window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 1100, height: 700)).size)
        window.setFrame(minimumFrame, display: false)
        window.layoutIfNeeded()
        XCTAssertEqual(window.frame, minimumFrame)
        XCTAssertEqual(workspace.sidebar.frame.width, 280, accuracy: 0.1)
        let undersizedController = CorralWindowController(
            workspaceView: CorralWorkspaceView(),
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500)
        )
        XCTAssertEqual(undersizedController.window?.contentView?.bounds.size, NSSize(width: 1100, height: 700))
    }

    func testSelectingAgentDoesNotOpenSettingsOrChangeWindowAndStageBounds() throws {
        let sessionID = UUID()
        let tab = CorralTab(
            title: "Agent workspace",
            contentView: NSView(),
            sessionIDs: [sessionID],
            activeSessionID: sessionID,
            isBlankWorkspace: false
        )
        let workspace = CorralWorkspaceView(tabs: [tab])
        let controller = CorralWindowController(workspaceView: workspace)
        let window = try XCTUnwrap(controller.window as? CorralWindow)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        workspace.layoutSubtreeIfNeeded()
        workspace.sidebar.layoutSubtreeIfNeeded()
        let agent = CorralSidebarAgent(id: sessionID, name: "Agent")
        workspace.sidebar.setAgents([agent] + (0..<40).map { CorralSidebarAgent(name: "Agent \($0)") })
        workspace.sidebar.layoutSubtreeIfNeeded()
        let clipView = try XCTUnwrap(workspace.sidebar.agentsTable.enclosingScrollView?.contentView)
        let visibleAgentRect = clipView.convert(clipView.bounds, to: workspace.sidebar)
        let settingsRect = workspace.sidebar.settingsButton.convert(workspace.sidebar.settingsButton.bounds, to: workspace.sidebar)
        XCTAssertFalse(visibleAgentRect.intersects(settingsRect))
        let rowRect = workspace.sidebar.agentsTable.convert(workspace.sidebar.agentsTable.rect(ofRow: 0), to: workspace.sidebar)
        let rowHit = workspace.sidebar.hitTest(NSPoint(x: rowRect.midX, y: rowRect.midY))
        XCTAssertNotNil(rowHit)
        XCTAssertTrue(rowHit === workspace.sidebar.agentsTable || rowHit?.isDescendant(of: workspace.sidebar.agentsTable) == true)
        XCTAssertFalse(rowHit === workspace.sidebar.settingsButton)

        let frame = window.frame
        let contentBounds = try XCTUnwrap(window.contentView).bounds
        var settingsCount = 0
        var selectedAgent: UUID?
        var focusedSession: (UUID, UUID)?
        workspace.onSettings = { settingsCount += 1 }
        workspace.onSelectAgent = { selectedAgent = $0 }
        workspace.onFocusSession = { focusedSession = ($0, $1) }
        workspace.sidebar.agentsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertNil(selectedAgent, "selection alone is not a completed Agent click")
        let rowCell = try XCTUnwrap(workspace.sidebar.agentsTable.view(atColumn: 0, row: 0, makeIfNecessary: true))
        XCTAssertTrue(rowCell.accessibilityPerformPress())
        workspace.layoutSubtreeIfNeeded()
        workspace.stageContainer.layoutSubtreeIfNeeded()

        XCTAssertEqual(selectedAgent, sessionID)
        XCTAssertEqual(focusedSession?.0, sessionID)
        XCTAssertEqual(focusedSession?.1, tab.id)
        XCTAssertEqual(settingsCount, 0)
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(window.contentView?.bounds, contentBounds)
        XCTAssertEqual(workspace.stageContainer.frame.size, NSSize(width: 820, height: 662))
        XCTAssertEqual(tab.contentView.frame.size, workspace.stageContainer.bounds.size)

        let refusedResize = controller.windowWillResize(window, to: NSSize(width: 900, height: 500))
        XCTAssertGreaterThanOrEqual(refusedResize.width, window.minSize.width)
        XCTAssertGreaterThanOrEqual(refusedResize.height, window.minSize.height)

        workspace.sidebar.settingsButton.performClick(nil)
        XCTAssertEqual(settingsCount, 1)
        XCTAssertEqual(window.frame, frame)

        window.setContentSize(NSSize(width: 900, height: 500))
        XCTAssertGreaterThanOrEqual(window.contentView?.bounds.width ?? 0, 1100)
        XCTAssertGreaterThanOrEqual(window.contentView?.bounds.height ?? 0, 700)
        window.setFrame(NSRect(origin: frame.origin, size: NSSize(width: 900, height: 500)), display: false, animate: false)
        XCTAssertGreaterThanOrEqual(window.contentView?.bounds.width ?? 0, 1100)
        XCTAssertGreaterThanOrEqual(window.contentView?.bounds.height ?? 0, 700)
    }

    func testSidebarGeometryMatchesLegacySidebarCSS() throws {
        let workspace = CorralWorkspaceView()
        let controller = CorralWindowController(workspaceView: workspace)
        let spaceID = UUID()
        workspace.sidebar.setSpaces([CorralSidebarSpace(id: spaceID, name: "Project")])
        workspace.sidebar.setAgents([CorralSidebarAgent(name: "Agent", spaceID: spaceID)])
        controller.window?.layoutIfNeeded()
        let sidebar = workspace.sidebar
        let headers = sidebar.subviews.flatMap(\.subviews).compactMap { $0 as? CorralSidebarSectionHeader }
        XCTAssertEqual(headers.count, 2)
        for header in headers {
            XCTAssertEqual(header.frame.height, 38, accuracy: 0.1)
            // Glyphs start 2pt inside the label cell: 20px inset + 11px chevron + 4px gap = 35.
            XCTAssertEqual(header.titleFrame.minX + 2, 35, accuracy: 0.5, "Group title is left aligned after the 20px inset and chevron")
        }
        // Spaces list hugs its rows (3 × 32px) so Agents follows immediately; no dead gap.
        let spacesScroll = try XCTUnwrap(sidebar.spacesTable.enclosingScrollView)
        XCTAssertEqual(spacesScroll.frame.height, 96, accuracy: 0.1)
        XCTAssertEqual(spacesScroll.frame.minY, headers[1].frame.maxY, accuracy: 0.1)
        XCTAssertEqual(sidebar.spacesTable.rect(ofRow: 0).height, 32)
        XCTAssertEqual(sidebar.agentsTable.rect(ofRow: 0).height, 34)
        // Footer: 44px, settings is a 34px square 8px from the trailing edge.
        let footer = try XCTUnwrap(sidebar.settingsButton.superview)
        XCTAssertEqual(footer.frame.height, 44, accuracy: 0.1)
        XCTAssertEqual(footer.frame.minY, 0, accuracy: 0.1)
        XCTAssertEqual(sidebar.settingsButton.frame.size, NSSize(width: 34, height: 34))
        XCTAssertEqual(sidebar.settingsButton.frame.maxX, 272, accuracy: 0.1)
        XCTAssertEqual(sidebar.devicesButton.frame.minX, 20, accuracy: 0.1)
        // The selected Space row paints the legacy selection background.
        let selectedRow = try XCTUnwrap(sidebar.spacesTable.rowView(atRow: 0, makeIfNecessary: true) as? CorralSidebarRowView)
        XCTAssertTrue(selectedRow.isSelected)
        XCTAssertEqual(selectedRow.fillColor, CorralAestheticTokens.selectionBackground)
        XCTAssertNil((sidebar.spacesTable.rowView(atRow: 1, makeIfNecessary: true) as? CorralSidebarRowView)?.fillColor)
    }

    func testWorkspaceSpaceRowsCountTheirOwnAgents() throws {
        // Coordinator order: spaces arrive with zero counts, agents follow.
        let project = CorralSidebarSpace(name: "corral-gw-test-home")
        let other = CorralSidebarSpace(name: "other")
        let sidebar = CorralSidebarView()
        sidebar.setSpaces([project, other])
        sidebar.setAgents((0..<6).map { CorralSidebarAgent(name: "fixture-\($0)", status: $0 == 0 ? .working : .idle, spaceID: project.id) })
        XCTAssertEqual(sidebar.spaces.map(\.agentCount), [6, 0, 6, 0])
        XCTAssertEqual(sidebar.spaces.map(\.workingCount), [1, 0, 1, 0])
        let row = try XCTUnwrap(sidebar.spacesTable.delegate?.tableView?(sidebar.spacesTable, viewFor: nil, row: 2))
        XCTAssertEqual(descendants(of: row).compactMap { ($0 as? NSTextField)?.stringValue }.suffix(2), ["1", "6"])
        // Re-sending spaces after agents keeps the derived counts.
        sidebar.setSpaces([project, other])
        XCTAssertEqual(sidebar.spaces[2].agentCount, 6)
    }

    func testCollapsedSidebarLetsStageAndTabContentFillFullWidth() throws {
        let content = NSView()
        let workspace = CorralWorkspaceView(tabs: [CorralTab(title: "Stage", contentView: content)])
        let controller = CorralWindowController(workspaceView: workspace)
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        XCTAssertEqual(content.frame.width, 1400 - 280, accuracy: 0.1)
        workspace.setSidebarCollapsed(true)
        window.layoutIfNeeded()
        XCTAssertEqual(workspace.stageContainer.frame, NSRect(x: 0, y: 0, width: 1400, height: 860 - 38))
        XCTAssertEqual(content.convert(content.bounds, to: nil), NSRect(x: 0, y: 0, width: 1400, height: 860 - 38))
        workspace.setSidebarCollapsed(false)
        window.layoutIfNeeded()
        XCTAssertEqual(content.frame.width, 1400 - 280, accuracy: 0.1)
    }

    func testChromeExposesStableAccessibilityIdentifiersAndActions() throws {
        let first = CorralTab(title: "First")
        let second = CorralTab(title: "Second")
        let workspace = CorralWorkspaceView(tabs: [first, second])
        workspace.frame = NSRect(x: 0, y: 0, width: 1400, height: 860)
        workspace.layoutSubtreeIfNeeded()
        XCTAssertEqual(workspace.titleBar.collapseButton.accessibilityIdentifier(), "corral.sidebar.toggle")
        XCTAssertEqual(workspace.tabBar.createButton.accessibilityIdentifier(), "corral.tab.new")
        XCTAssertEqual(workspace.sidebar.devicesButton.accessibilityIdentifier(), "corral.sidebar.devices")
        XCTAssertEqual(workspace.sidebar.settingsButton.accessibilityIdentifier(), "corral.sidebar.settings")

        // Tabs are AX buttons: AXPress selects, custom actions mirror the context menu.
        let tabs = descendants(of: workspace.tabBar).filter { $0.accessibilityIdentifier() == "corral.tab" }
        XCTAssertEqual(tabs.map { $0.accessibilityLabel() }, ["First", "Second"])
        XCTAssertEqual(tabs[1].accessibilityRole(), .button)
        XCTAssertTrue(tabs[1].isAccessibilityElement())
        XCTAssertTrue(tabs[1].accessibilityPerformPress())
        XCTAssertEqual(workspace.activeTabID, second.id)
        let secondTab = try XCTUnwrap(descendants(of: workspace.tabBar).first { $0.accessibilityIdentifier() == "corral.tab" && $0.accessibilityLabel() == "Second" })
        let close = try XCTUnwrap(secondTab.accessibilityCustomActions()?.first { $0.name == "关闭工作台" })
        XCTAssertTrue(close.handler?() ?? false)
        XCTAssertEqual(workspace.tabs.map(\.id), [first.id])

        // Sidebar rows: AXPress opens / selects, custom actions mirror the row context menus.
        let space = CorralSidebarSpace(name: "Project")
        let agent = CorralSidebarAgent(name: "leader", spaceID: space.id)
        let sidebar = workspace.sidebar
        sidebar.setSpaces([space]); sidebar.setAgents([agent])
        var selectedAgent: UUID?; var favorite: (UUID, Bool)?; var closed: UUID?; var created: UUID??
        sidebar.onSelectAgent = { selectedAgent = $0 }
        sidebar.onToggleFavorite = { favorite = ($0, $1) }
        sidebar.onCloseAgent = { closed = $0 }
        sidebar.onCreateAgent = { created = $0 }
        let agentCell = try XCTUnwrap(sidebar.agentsTable.delegate?.tableView?(sidebar.agentsTable, viewFor: nil, row: 0))
        XCTAssertEqual(agentCell.accessibilityIdentifier(), "corral.sidebar.agent")
        XCTAssertEqual(agentCell.accessibilityLabel(), "leader")
        XCTAssertEqual(agentCell.accessibilityRole(), .button)
        XCTAssertTrue(agentCell.accessibilityPerformPress())
        XCTAssertEqual(selectedAgent, agent.id)
        XCTAssertEqual(agentCell.accessibilityCustomActions()?.map(\.name), ["收藏", "关闭"])
        XCTAssertTrue(agentCell.accessibilityCustomActions()?[0].handler?() ?? false)
        XCTAssertTrue(agentCell.accessibilityCustomActions()?[1].handler?() ?? false)
        XCTAssertEqual(favorite?.0, agent.id); XCTAssertEqual(favorite?.1, true); XCTAssertEqual(closed, agent.id)
        let spaceCell = try XCTUnwrap(sidebar.spacesTable.delegate?.tableView?(sidebar.spacesTable, viewFor: nil, row: 2))
        XCTAssertEqual(spaceCell.accessibilityIdentifier(), "corral.sidebar.space")
        XCTAssertTrue(spaceCell.accessibilityPerformPress())
        XCTAssertEqual(sidebar.selectedSpaceID, space.id)
        XCTAssertTrue(spaceCell.accessibilityCustomActions()?.first { $0.name == "新建 Agent" }?.handler?() ?? false)
        XCTAssertEqual(created, space.id)
    }

    func testTabPillsMatchLegacyChromeCSS() throws {
        let first = CorralTab(title: "全自动编排leader")
        let second = CorralTab(title: "Second")
        let workspace = CorralWorkspaceView(tabs: [first, second])
        workspace.frame = NSRect(x: 0, y: 0, width: 1400, height: 860)
        workspace.selectTab(id: first.id)
        workspace.layoutSubtreeIfNeeded(); workspace.tabBar.layoutSubtreeIfNeeded()
        let bar = workspace.tabBar
        let items = descendants(of: bar).filter { String(describing: type(of: $0)) == "CorralTabItemView" }
        XCTAssertEqual(items.count, 2)
        for item in items {
            let frame = bar.convert(item.bounds, from: item)
            XCTAssertEqual(frame.height, 26, accuracy: 0.1)
            XCTAssertGreaterThanOrEqual(frame.width, 144 - 0.1)
            XCTAssertLessThanOrEqual(frame.width, 260 + 0.1)
            XCTAssertEqual(frame.midY, 19, accuracy: 0.1, "Pills share the 38px header centerline with the sidebar toggle")
            XCTAssertEqual(item.layer?.cornerRadius, 6)
        }
        XCTAssertEqual(bar.convert(items[0].bounds, from: items[0]).minX, 9, accuracy: 0.1)
        let capsule = try XCTUnwrap(bar.activeCapsuleFrame)
        XCTAssertGreaterThanOrEqual(capsule.size.width, 144 - 0.1)
        XCTAssertLessThanOrEqual(capsule.size.width, 260 + 0.1)
        XCTAssertEqual(capsule.size.height, 26, accuracy: 0.1)
        let plus = bar.convert(bar.createButton.bounds, from: bar.createButton)
        XCTAssertEqual(plus.minX, bar.convert(items[1].bounds, from: items[1]).maxX + 9, accuracy: 0.5)
        XCTAssertEqual(plus.size, NSSize(width: 26, height: 26))

        CorralAestheticTokens.themeMode = .dark
        XCTAssertEqual(rgb(CorralAestheticTokens.tabActiveBackground), 0x272F3A)
        XCTAssertEqual(rgb(CorralAestheticTokens.tabActiveBorder), 0x3A4554)

        for index in 0..<30 { workspace.addTab(CorralTab(title: "Overflow \(index)"), select: false) }
        workspace.layoutSubtreeIfNeeded(); workspace.tabBar.layoutSubtreeIfNeeded()
        let crowded = descendants(of: bar).filter { String(describing: type(of: $0)) == "CorralTabItemView" }
        XCTAssertTrue(crowded.allSatisfy { $0.frame.width >= 144 - 0.1 && $0.frame.width <= 260 + 0.1 })
        XCTAssertLessThanOrEqual(bar.convert(bar.createButton.bounds, from: bar.createButton).maxX, bar.bounds.maxX - 10 + 0.1)
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

    func testSidebarSectionCollapseKeepsWindowChromePinnedToTop() throws {
        let workspace = CorralWorkspaceView(tabs: [CorralTab(title: "Agent", contentView: NSView())])
        let controller = CorralWindowController(workspaceView: workspace)
        let window = try XCTUnwrap(controller.window)
        let initialFrame = window.frame
        workspace.sidebar.setSpaces((0..<3).map { CorralSidebarSpace(name: "Project \($0)") })
        workspace.sidebar.setAgents((0..<62).map { CorralSidebarAgent(name: "Agent \($0)") })

        for (spacesExpanded, agentsExpanded) in [(true, true), (true, false), (false, false), (false, true), (true, true)] {
            workspace.sidebar.setSpacesExpanded(spacesExpanded)
            workspace.sidebar.setAgentsExpanded(agentsExpanded)
            window.layoutIfNeeded()
            workspace.layoutSubtreeIfNeeded()
            workspace.sidebar.layoutSubtreeIfNeeded()
            XCTAssertEqual(window.frame, initialFrame)
            XCTAssertEqual(workspace.frame, window.contentView?.bounds)
            XCTAssertEqual(workspace.titleBar.frame.maxY, workspace.bounds.maxY, accuracy: 0.1)
            XCTAssertEqual(workspace.tabBar.frame.maxY, workspace.bounds.maxY, accuracy: 0.1)
            XCTAssertEqual(workspace.sidebar.frame.minY, 0, accuracy: 0.1)
            XCTAssertEqual(workspace.sidebar.frame.maxY, workspace.bounds.maxY - CorralWorkspaceView.headerHeight, accuracy: 0.1)
            XCTAssertEqual(workspace.stageContainer.frame.minY, 0, accuracy: 0.1)
            XCTAssertEqual(workspace.stageContainer.frame.maxY, workspace.bounds.maxY - CorralWorkspaceView.headerHeight, accuracy: 0.1)
        }
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

    func testPinnedAndRegularTabsKeepReadableTitlesAndPreviewClosesOnlyItsPreview() throws {
        let pinned = CorralTab(title: "全自动编排leader", status: .working, isPinned: true, provider: "pi")
        let regular = CorralTab(title: "Workspace · Rust", provider: "codex")
        let workspace = CorralWorkspaceView(tabs: [pinned, regular])
        workspace.frame = NSRect(x: 0, y: 0, width: 1400, height: 860)
        workspace.layoutSubtreeIfNeeded(); workspace.tabBar.layoutSubtreeIfNeeded()

        func item(title: String) throws -> NSView {
            try XCTUnwrap(descendants(of: workspace.tabBar).first {
                $0.accessibilityIdentifier() == "corral.tab" && $0.accessibilityLabel() == title
            })
        }
        func titleLabel(in item: NSView) throws -> NSTextField {
            try XCTUnwrap(descendants(of: item).compactMap { $0 as? NSTextField }.first {
                $0.accessibilityIdentifier() == "corral.tab.title"
            })
        }

        let pinnedItem = try item(title: pinned.title)
        let pinnedLabel = try titleLabel(in: pinnedItem)
        XCTAssertFalse(pinnedLabel.isHidden)
        XCTAssertEqual(pinnedLabel.stringValue, "全自动编排leader")
        XCTAssertGreaterThan(pinnedLabel.frame.width, 0)
        XCTAssertEqual(pinnedLabel.cell?.lineBreakMode, .byTruncatingTail)
        XCTAssertGreaterThanOrEqual(pinnedItem.frame.width, 144)
        XCTAssertLessThanOrEqual(pinnedItem.frame.width, 260)
        XCTAssertTrue(descendants(of: pinnedItem).contains { $0 is CorralProviderIconView })
        XCTAssertFalse(descendants(of: pinnedItem).contains { $0.accessibilityIdentifier() == "corral.tab.close" })

        let regularItem = try item(title: regular.title)
        let regularLabel = try titleLabel(in: regularItem)
        XCTAssertFalse(regularLabel.isHidden)
        XCTAssertEqual(regularLabel.stringValue, regular.title)
        XCTAssertTrue(descendants(of: regularItem).contains { $0.accessibilityIdentifier() == "corral.tab.close" })

        var closedPreview = false
        workspace.onClosePreview = { closedPreview = true }
        let previewID = UUID()
        workspace.synchronizeWorkspaceTabs([pinned, regular], selectedTabID: pinned.id, previewSessionID: previewID)
        workspace.layoutSubtreeIfNeeded(); workspace.tabBar.layoutSubtreeIfNeeded()
        let previewItem = try item(title: pinned.title)
        let closePreview = try XCTUnwrap(descendants(of: previewItem).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "corral.tab.close"
        })
        XCTAssertEqual(closePreview.accessibilityLabel(), "关闭预览")
        closePreview.performClick(closePreview)
        XCTAssertTrue(closedPreview)
        XCTAssertEqual(workspace.tabs.count, 2, "closing preview must not remove the durable host Tab")
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
        let initial = NSRect(x: 41.25, y: 72.5, width: 1180.5, height: 710.25)
        let controller = CorralWindowController(workspaceView: CorralWorkspaceView(), contentRect: initial)
        let window = try XCTUnwrap(controller.window as? CorralWindow)
        let original = window.frame
        let visibleFrame = NSRect(x: 70, y: 40, width: 1220, height: 820)
        controller.toggleZoom(to: visibleFrame)
        XCTAssertEqual(window.frame, visibleFrame)
        XCTAssertEqual(window.minSize, CorralWindow.minimumContentSize)
        XCTAssertEqual(window.contentMinSize, CorralWindow.minimumContentSize)
        XCTAssertGreaterThanOrEqual(window.frame.minX, visibleFrame.minX)
        XCTAssertGreaterThanOrEqual(window.frame.minY, visibleFrame.minY)
        XCTAssertLessThanOrEqual(window.frame.maxX, visibleFrame.maxX)
        XCTAssertLessThanOrEqual(window.frame.maxY, visibleFrame.maxY)
        XCTAssertEqual(controller.savedFrameBeforeZoom, original)
        controller.toggleZoom(to: visibleFrame)
        XCTAssertEqual(window.frame, original)
        XCTAssertEqual(window.minSize, CorralWindow.minimumContentSize)
        XCTAssertNil(controller.savedFrameBeforeZoom)
    }

    func testSettingsOverlayDoesNotResizeWindowOrReplaceStage() throws {
        let workspace = CorralWorkspaceView(tabs: [CorralTab(title: "Agent", contentView: NSView())])
        let controller = CorralWindowController(workspaceView: workspace)
        let window = try XCTUnwrap(controller.window as? CorralWindow)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        workspace.layoutSubtreeIfNeeded()
        let initialFrame = window.frame
        let initialBounds = try XCTUnwrap(window.contentView).bounds
        let dialog = SettingsDialogViewController()

        dialog.present(over: window)
        window.contentView?.layoutSubtreeIfNeeded()
        workspace.layoutSubtreeIfNeeded()

        XCTAssertTrue(dialog.presentedWindow === window)
        XCTAssertEqual(window.frame, initialFrame)
        XCTAssertEqual(window.contentView?.bounds, initialBounds)
        XCTAssertEqual(workspace.stageContainer.frame.size, NSSize(width: 820, height: 662))
        let activeTabContent = try XCTUnwrap(workspace.activeTabID.flatMap(workspace.view(forTab:)))
        XCTAssertTrue(workspace.stageContainer.subviews.contains { $0 === activeTabContent })

        dialog.dismiss()
        XCTAssertEqual(window.frame, initialFrame)
        XCTAssertEqual(window.contentView?.bounds, initialBounds)
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
        XCTAssertEqual(dialog.view.frame.width, 420, accuracy: 0.1)
        XCTAssertEqual(dialog.view.layer?.cornerRadius ?? 0, 14, accuracy: 0.1)
        dialog.nameField.stringValue = "  Fix parser  "
        dialog.controlTextDidChange(Notification(name: Notification.Name("NameChanged"), object: dialog.nameField))
        XCTAssertTrue(dialog.isCreateEnabled)
        var cancelCalls = 0
        dialog.onCancel = { cancelCalls += 1 }
        dialog.isLoading = true
        XCTAssertFalse(dialog.cancelButton?.isEnabled ?? true)
        XCTAssertFalse(dialog.createButton?.isEnabled ?? true)
        XCTAssertEqual(dialog.createButton?.title, "创建中…")
        dialog.cancelButton?.performClick(nil)
        XCTAssertEqual(cancelCalls, 0)
        dialog.isLoading = false
        XCTAssertTrue(dialog.cancelButton?.isEnabled ?? false)
        XCTAssertTrue(dialog.createButton?.isEnabled ?? false)
        XCTAssertEqual(dialog.createButton?.title, "创建")
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
        let courier = try XCTUnwrap(dialog.fontPresetButtons.first { $0.title == "Courier New" })
        courier.performClick(nil)
        dialog.setFontSize(99)
        dialog.setDirectoryTracking(true)
        XCTAssertEqual(dialog.values.theme, .light)
        XCTAssertEqual(dialog.values.fontFamily, "Courier New")
        XCTAssertEqual(dialog.fontPreviewLabel?.font?.fontName, NSFont(name: "Courier New", size: 24)?.fontName)
        XCTAssertEqual(dialog.values.fontSize, 24)
        XCTAssertTrue(dialog.values.directoryTracking)
        XCTAssertEqual(dialog.themeButtons.filter { $0.state == .on }.map(\.title), ["浅色"])
        XCTAssertEqual(dialog.fontPresetButtons.filter { $0.state == .on }.map(\.title), ["Courier New"])
        XCTAssertEqual(dialog.fontSizeSlider.doubleValue, 24)
        XCTAssertEqual(dialog.fontSizeField.stringValue, "24")
        XCTAssertFalse(dialog.fontSizeIncrementButton.isEnabled)
        dialog.fontSizeDecrementButton.performClick(nil)
        XCTAssertEqual(dialog.values.fontSize, 23)
        XCTAssertEqual(dialog.fontSizeSlider.minValue, 10)
        XCTAssertEqual(dialog.fontSizeSlider.maxValue, 24)
        XCTAssertEqual(changes.count, 5)
        XCTAssertEqual(dialog.fontPreviewLabel?.font?.pointSize, 23)
        XCTAssertEqual(dialog.fontPresetButtons.map(\.title), ["Cascadia Code", "JetBrains Mono", "Fira Code", "Menlo", "Consolas", "Courier New"])
        dialog.fontFamilyField.stringValue = "Menlo, monospace"
        XCTAssertTrue(dialog.fontFamilyField.sendAction(dialog.fontFamilyField.action, to: dialog.fontFamilyField.target))
        XCTAssertEqual(dialog.values.fontFamily, "Menlo, monospace")
        XCTAssertEqual(dialog.fontPresetButtons.filter { $0.state == .on }.map(\.title), ["Menlo"])
    }

    func testSettingsDialogUsesLegacyCardLayout() throws {
        CorralAestheticTokens.themeMode = .light
        defer { CorralAestheticTokens.themeMode = .dark }
        let dialog = SettingsDialogViewController()
        dialog.loadViewIfNeeded()
        XCTAssertEqual(dialog.view.frame.width, 560)
        XCTAssertLessThanOrEqual(dialog.view.frame.height, 700 - 16, "Must fit the 1100×700 minimum window")
        XCTAssertEqual(dialog.view.layer?.cornerRadius, 18)
        XCTAssertEqual(dialog.view.accessibilityIdentifier(), "corral.settings.dialog")
        let labels = descendants(of: dialog.view).compactMap { ($0 as? NSTextField)?.stringValue }
        for title in ["界面外观", "终端外观", "工作区行为", "主题模式", "字体", "自定义字体栈", "字号", "即时预览", "目录跟踪", "修改即时保存"] {
            XCTAssertTrue(labels.contains(title), "Missing \(title)")
        }
        let cards = descendants(of: dialog.view).filter { $0.layer?.cornerRadius == 12 && $0.layer?.borderWidth == 1 }
        XCTAssertEqual(cards.count, 3)
        let preview = try XCTUnwrap(descendants(of: dialog.view).first { $0.accessibilityIdentifier() == "corral.settings.preview" })
        XCTAssertEqual(rgb(preview.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) ?? .clear), 0x3A3835)
        XCTAssertEqual(dialog.themeButtons.map(\.title), ["浅色", "深色", "跟随系统"])
        XCTAssertEqual(dialog.themeButtons.first { $0.state == .on }?.title, "跟随系统")
        XCTAssertEqual(dialog.fontPresetButtons.first { $0.state == .on }?.title, "Cascadia Code")
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

    func testDevicePopoverMatchesLegacyLayoutAndIsAXDrivable() async throws {
        let local = try makeDeviceRecord(id: "local", name: "Local")
        let remote = try makeDeviceRecord(id: "remote", name: "Remote")
        let controller = DevicesPopoverViewController(repository: TestDeviceRepository(records: [local, remote]))
        var added = 0, paired = 0
        var selection: Set<DeviceID> = []
        controller.onAddDevice = { added += 1 }; controller.onPairMobile = { paired += 1 }
        controller.onSelectionChanged = { selection = $0 }
        controller.loadViewIfNeeded()
        try await controller.reloadDevices()
        controller.setReadyDevices([local.id])
        XCTAssertEqual(controller.preferredContentSize.width, 300)
        XCTAssertEqual(controller.view.accessibilityIdentifier(), "corral.devices.popover")
        XCTAssertEqual(controller.selectionSummary.stringValue, "2 devices · 1 connected")
        XCTAssertTrue(controller.allDevicesRow.isChecked)
        XCTAssertEqual(controller.allDevicesRow.accessibilityIdentifier(), "corral.devices.all")

        let row = try XCTUnwrap(controller.tableView(controller.tableView, viewFor: nil, row: 0))
        XCTAssertEqual(row.accessibilityIdentifier(), "corral.devices.row")
        XCTAssertEqual(row.accessibilityLabel(), "Local")
        let texts = descendants(of: row).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(texts.contains("127.0.0.1:\(ApprovedEndpoint.developmentPort) · WebSocket"))
        XCTAssertEqual(descendants(of: row).compactMap { $0 as? CorralStatusIndicatorView }.first?.status, .working)
        XCTAssertEqual(row.accessibilityCustomActions()?.map(\.name), ["重命名", "删除"])
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(selection, [remote.id])
        XCTAssertFalse(controller.allDevicesRow.isChecked)
        XCTAssertTrue(controller.allDevicesRow.accessibilityPerformPress())
        XCTAssertEqual(selection, [local.id, remote.id])
        XCTAssertTrue(controller.pairRow.accessibilityPerformPress())
        XCTAssertTrue(controller.addRow.accessibilityPerformPress())
        XCTAssertEqual(added, 1); XCTAssertEqual(paired, 1)
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
