import AppKit
import CorralContracts
import CorralServices
@testable import CorralUI
import XCTest

@MainActor
final class SplitWorkspaceViewTests: XCTestCase {
    private let a = SessionID("dev::A"), b = SessionID("dev::B"), c = SessionID("dev::C"), d = SessionID("dev::D"), s = SessionID("dev::S")
    private var grid: WorkspaceLayoutNode {
        .split(direction: .horizontal, ratio: 0.5,
               first: .split(direction: .vertical, ratio: 0.5, first: .session(a), second: .session(c)),
               second: .split(direction: .vertical, ratio: 0.5, first: .session(b), second: .session(d)))
    }
    private var pair: WorkspaceLayoutNode { .split(direction: .horizontal, ratio: 0.5, first: .session(a), second: .session(b)) }

    private func hosted(_ root: WorkspaceLayoutNode?, focused: SessionID?, size: NSSize) -> (NSWindow, NSView, SplitWorkspaceView) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        let overlay = SplitWorkspaceView()
        overlay.frame = container.bounds
        container.addSubview(overlay)
        overlay.update(root: root, focusedSessionID: focused)
        return (window, container, overlay)
    }

    private func completeAgentClick(on sidebar: CorralSidebarView, row: Int, gesture: SessionOpenGesture = .singleClick) throws {
        let table = try XCTUnwrap(sidebar.agentsTable as? CorralAgentTableView)
        let sessionID = try XCTUnwrap(sidebar.agents[row].sessionID)
        table.dispatchClickIfCompleted(from: sessionID, to: sessionID, wasDragged: false, gesture: gesture)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in overlay: SplitWorkspaceView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: overlay.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: overlay.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testFourPaneOverlayDrawsLegacyCardsGapsAndFocusOverATransparentStage() throws {
        CorralAestheticTokens.themeMode = .dark
        let (_, _, overlay) = hosted(grid, focused: a, size: NSSize(width: 1206, height: 806))
        XCTAssertTrue(overlay.isFlipped)
        XCTAssertEqual(overlay.splitterCount, 3)
        XCTAssertEqual(overlay.projection.panes.map(\.frame), [
            CGRect(x: 0, y: 0, width: 600, height: 400), CGRect(x: 0, y: 406, width: 600, height: 400),
            CGRect(x: 606, y: 0, width: 600, height: 400), CGRect(x: 606, y: 406, width: 600, height: 400)
        ])
        XCTAssertEqual(Set(overlay.closeButtons.keys), [a, b, c, d])
        let close = try XCTUnwrap(overlay.closeButtons[b])
        XCTAssertEqual(close.frame, CGRect(x: 1178, y: 6, width: 22, height: 22), "`.pane-close-btn`: 22×22 at top 6 / right 6")
        XCTAssertEqual(close.alphaValue, 0, "revealed only while its pane is hovered")
        XCTAssertEqual(close.accessibilityIdentifier(), "corral.pane.close")
        XCTAssertEqual(close.accessibilityLabel(), "关闭窗格")

        let bitmap = try XCTUnwrap(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
        overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / overlay.bounds.width
        func pixel(_ x: CGFloat, _ y: CGFloat) -> NSColor { bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))! }
        func assertColor(_ color: NSColor, _ hex: UInt32, _ message: String, line: UInt = #line) {
            let expected = CorralAestheticTokens.color(hex).usingColorSpace(bitmap.colorSpace)!
            XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01, message, line: line)
            for (actual, wanted) in zip([color.redComponent, color.greenComponent, color.blueComponent], [expected.redComponent, expected.greenComponent, expected.blueComponent]) {
                XCTAssertEqual(actual * 255, wanted * 255, accuracy: 2, "\(message): #\(String(hex, radix: 16))", line: line)
            }
        }
        XCTAssertEqual(pixel(300, 200).alphaComponent, 0, accuracy: 0.01, "pane interiors stay transparent so the Metal stage shows through")
        assertColor(pixel(603, 200), 0x0F1115, "the 6pt gap shows the stage background")
        assertColor(pixel(0.5, 0.5), 0x0F1115, "8pt card corners are masked with the stage background")
        assertColor(pixel(300, 0.5), 0x5C79A3, "the focused pane has the 1px pane-active-border outline")
        assertColor(pixel(900, 399.5), 0x2A323E, "other panes keep the 1px border-subtle card edge")

        overlay.update(root: .session(a), focusedSessionID: a)
        XCTAssertEqual(overlay.splitterCount, 0)
        XCTAssertTrue(overlay.closeButtons.isEmpty, "a lone pane has no card chrome and cannot be closed")
    }

    func testTerminalClicksFallThroughEveryPaneAndInvisibleCloseButton() throws {
        let (_, container, overlay) = hosted(grid, focused: a, size: NSSize(width: 1206, height: 806))
        func hit(_ x: CGFloat, _ y: CGFloat) -> NSView? { overlay.hitTest(container.convert(CGPoint(x: x, y: y), from: overlay)) }
        XCTAssertNil(hit(300, 200), "the focused pane belongs to the terminal input below")
        XCTAssertTrue(hit(603, 200) === overlay, "the 6pt gap is the resize handle")
        XCTAssertNil(hit(900, 600), "the terminal focuses and receives the same first click")
        XCTAssertNil(hit(1189, 17), "invisible controls must not swallow terminal input")
        overlay.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 1189, y: 17), in: overlay))
        XCTAssertTrue(hit(1189, 17) === overlay.closeButtons[b])

        var focused: SessionID?, closed: SessionID?
        overlay.onFocusPane = { focused = $0 }
        overlay.onClosePane = { closed = $0 }
        overlay.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 900, y: 600), in: overlay))
        XCTAssertEqual(focused, d)
        overlay.closeButtons[b]?.performClick(nil)
        XCTAssertEqual(closed, b)
        XCTAssertEqual(overlay.root, grid, "closing is reported, never applied locally")
    }

    func testDividerDragPreviewsLiveAndCommitsOnceFromTheFinalPointerPosition() throws {
        let (_, _, overlay) = hosted(pair, focused: a, size: NSSize(width: 1000, height: 600))
        var previews: [WorkspaceLayoutNode?] = [], commits: [(String, Double)] = []
        overlay.onLayoutPreview = { previews.append($0) }
        overlay.onRatioChange = { commits.append(($0, $1)) }

        overlay.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 500, y: 300), in: overlay))
        XCTAssertEqual(overlay.activeDividerPath, "root")
        overlay.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 600, y: 340), in: overlay))
        XCTAssertEqual(overlay.projection.panes.first?.frame.width, 597, "panes follow the pointer while dragging")
        XCTAssertEqual(previews.last??.leafIDs, [a, b])
        XCTAssertTrue(commits.isEmpty, "nothing persists mid-drag")
        overlay.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 650, y: 300), in: overlay))
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.0, "root")
        XCTAssertEqual(commits.first?.1, 0.6514, "the release coordinate counts: round4(647.5 / 994), floor(994 × 0.6514) = 647")
        XCTAssertEqual(overlay.projection.panes.first?.frame.width, 647)
        XCTAssertNil(overlay.activeDividerPath)

        // Returning to the start writes nothing and ends the live preview.
        commits.removeAll(); previews.removeAll()
        overlay.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 650, y: 300), in: overlay))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 700, y: 300), in: overlay))
        overlay.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 650, y: 300), in: overlay))
        XCTAssertTrue(commits.isEmpty)
        XCTAssertEqual(previews.count, 2)
        XCTAssertNil(previews.last ?? nil)

        // A topology change mid-drag cancels the stale gesture instead of writing into the new tree.
        overlay.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 650, y: 300), in: overlay))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 400, y: 300), in: overlay))
        overlay.update(root: .split(direction: .vertical, ratio: 0.5, first: .session(a), second: .session(b)), focusedSessionID: a)
        overlay.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 400, y: 300), in: overlay))
        XCTAssertTrue(commits.isEmpty)
        XCTAssertNil(previews.last ?? nil)
    }

    func testDividersAreAccessibleSplittersForHeadlessResizing() throws {
        let (_, _, overlay) = hosted(pair, focused: a, size: NSSize(width: 1000, height: 600))
        var commits: [(String, Double)] = []
        overlay.onRatioChange = { commits.append(($0, $1)) }
        let splitter = try XCTUnwrap(overlay.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.first { $0.accessibilityRole() == .splitter })
        XCTAssertEqual(splitter.accessibilityIdentifier(), "corral.split.divider")
        XCTAssertEqual((splitter.accessibilityValue() as? NSNumber)?.doubleValue, 497)
        splitter.setAccessibilityValue(NSNumber(value: 600))
        XCTAssertEqual(commits.first?.0, "root")
        XCTAssertEqual(commits.first?.1, 0.6041)
        XCTAssertEqual(overlay.projection.panes.first?.frame.width, 600)
    }

    func testStageDropHighlightsTheCandidateSlotAndDeliversRealSessionIDs() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        let stage = CorralWorkspaceStageView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        window.contentView = stage
        stage.layoutSubtreeIfNeeded()
        XCTAssertEqual(stage.splitView.frame, stage.bounds)
        XCTAssertEqual(stage.subviews.last, stage.dropZone, "the drop highlight floats above the pane chrome")
        stage.splitView.update(root: pair, focusedSessionID: a)
        var dropped: (SessionID, SessionID?, SplitDropZoneView.Edge)?
        stage.onDropSession = { dropped = ($0, $1, $2) }

        // Flipped overlay point (248, 10) is the top band of A.
        let session = FakeDraggingInfo(location: stage.convert(CGPoint(x: 248, y: 590), to: nil), strings: [CorralWorkspaceStageView.sessionPasteboardType: s.rawValue])
        defer { session.pasteboard.releaseGlobally() }
        XCTAssertEqual(stage.draggingEntered(session), .move)
        XCTAssertFalse(stage.dropZone.isHidden)
        XCTAssertEqual(stage.dropZone.edge, .top)
        XCTAssertEqual(stage.dropZone.frame, CGRect(x: 0, y: 303, width: 497, height: 297), "the highlight is the new pane's exact slot")
        XCTAssertTrue(stage.performDragOperation(session))
        XCTAssertEqual(dropped?.0, s)
        XCTAssertEqual(dropped?.1, a)
        XCTAssertEqual(dropped?.2, .top)
        XCTAssertTrue(stage.dropZone.isHidden)

        // A Tab dragged onto the pane midline splits it to the pointer's side; the active Tab cannot drop on itself.
        let activeTab = UUID(), otherTab = UUID()
        stage.activeTabID = activeTab
        var droppedTab: (UUID, SessionID?, SplitDropZoneView.Edge)?
        stage.onDropTab = { droppedTab = ($0, $1, $2) }
        let tab = FakeDraggingInfo(location: stage.convert(CGPoint(x: 750, y: 300), to: nil), strings: [.string: otherTab.uuidString])
        defer { tab.pasteboard.releaseGlobally() }
        XCTAssertEqual(stage.draggingUpdated(tab), .move)
        XCTAssertEqual(stage.dropZone.edge, .left)
        XCTAssertEqual(stage.dropZone.frame.width, 328, accuracy: 0.5, "a midline drop highlights only the newly split pane")
        XCTAssertTrue(stage.performDragOperation(tab))
        XCTAssertEqual(droppedTab?.0, otherTab)
        XCTAssertEqual(droppedTab?.1, b)
        XCTAssertEqual(droppedTab?.2, .left)
        let selfTab = FakeDraggingInfo(location: stage.convert(CGPoint(x: 750, y: 300), to: nil), strings: [.string: activeTab.uuidString])
        defer { selfTab.pasteboard.releaseGlobally() }
        XCTAssertEqual(stage.draggingUpdated(selfTab), [])

        // An empty stage takes the dropped session as its whole layout.
        stage.splitView.update(root: nil, focusedSessionID: nil)
        XCTAssertEqual(stage.draggingUpdated(session), .move)
        XCTAssertEqual(stage.dropZone.frame, stage.bounds)
        XCTAssertTrue(stage.performDragOperation(session))
        XCTAssertNil(dropped?.1)
    }

    func testStageRefusesDropsThatWouldSqueezeAnyPaneBelowTheMinimum() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        let stage = CorralWorkspaceStageView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        window.contentView = stage
        stage.layoutSubtreeIfNeeded()
        stage.splitView.update(root: pair, focusedSessionID: a)
        var dropped = false
        stage.onDropSession = { _, _, _ in dropped = true }
        let squeeze = FakeDraggingInfo(location: stage.convert(CGPoint(x: 5, y: 300), to: nil), strings: [CorralWorkspaceStageView.sessionPasteboardType: s.rawValue])
        defer { squeeze.pasteboard.releaseGlobally() }
        XCTAssertEqual(stage.draggingEntered(squeeze), [], "a third 96pt column would break the 120pt floor")
        XCTAssertTrue(stage.dropZone.isHidden, "no highlight for a refused split")
        XCTAssertFalse(stage.performDragOperation(squeeze))
        XCTAssertFalse(dropped)
    }

    func testAgentHighlightIsCoordinatorOwnedAndRowsDoNotSelectLocally() throws {
        let firstKey = SessionID("dev::active"), secondKey = SessionID("dev::inactive")
        let sidebar = CorralSidebarView()
        sidebar.setAgents([
            CorralSidebarAgent(name: "active", isActive: true, sessionID: firstKey),
            CorralSidebarAgent(name: "inactive", sessionID: secondKey)
        ])
        let table = try XCTUnwrap(sidebar.agentsTable as? CorralAgentTableView)
        XCTAssertEqual(table.selectedRow, -1)
        XCTAssertFalse(table.delegate?.tableView?(table, shouldSelectRow: 1) ?? true)
        let activeRow = try XCTUnwrap(table.rowView(atRow: 0, makeIfNecessary: true) as? CorralSidebarRowView)
        XCTAssertTrue(activeRow.isActive)

        table.dispatchClickIfCompleted(from: secondKey, to: secondKey, wasDragged: false)
        XCTAssertEqual(table.selectedRow, -1)
        XCTAssertTrue(activeRow.isActive, "a click cannot speculate coordinator-owned active state")
        sidebar.setAgents([
            CorralSidebarAgent(name: "active", sessionID: firstKey),
            CorralSidebarAgent(name: "inactive", isActive: true, sessionID: secondKey)
        ])
        let updatedRow = try XCTUnwrap(table.rowView(atRow: 1, makeIfNecessary: true) as? CorralSidebarRowView)
        XCTAssertTrue(updatedRow.isActive)
    }

    func testSidebarAgentClicksDispatchTypedIntentAndSuppressDragOrMismatchedRelease() throws {
        let firstID = UUID(), secondID = UUID()
        let sidebar = CorralSidebarView()
        let secondSessionID = SessionID("dev::B")
        sidebar.setAgents([
            CorralSidebarAgent(id: firstID, name: "first", sessionID: s),
            CorralSidebarAgent(id: secondID, name: "second", sessionID: secondSessionID)
        ])
        let writer = try XCTUnwrap(sidebar.agentsTable.dataSource?.tableView?(sidebar.agentsTable, pasteboardWriterForRow: 0) as? NSPasteboardItem)
        XCTAssertEqual(writer.string(forType: CorralWorkspaceStageView.sessionPasteboardType), s.rawValue)
        let secondWriter = try XCTUnwrap(sidebar.agentsTable.dataSource?.tableView?(sidebar.agentsTable, pasteboardWriterForRow: 1) as? NSPasteboardItem)
        XCTAssertEqual(secondWriter.string(forType: CorralWorkspaceStageView.sessionPasteboardType), secondSessionID.rawValue)
        XCTAssertNil(sidebar.spacesTable.dataSource?.tableView?(sidebar.spacesTable, pasteboardWriterForRow: 0))

        var opened: [(SessionID, SessionOpenGesture)] = []
        sidebar.onSelectAgent = { opened.append(($0, $1)) }
        let table = try XCTUnwrap(sidebar.agentsTable as? CorralAgentTableView)
        XCTAssertEqual(table.selectedRow, -1, "Agent highlight is driven only by coordinator state")
        table.dispatchClickIfCompleted(from: s, to: s, wasDragged: true)
        table.dispatchClickIfCompleted(from: s, to: secondSessionID, wasDragged: false)
        XCTAssertTrue(opened.isEmpty, "dragging or releasing on a different session must not dispatch")

        try completeAgentClick(on: sidebar, row: 0)
        try completeAgentClick(on: sidebar, row: 1)
        try completeAgentClick(on: sidebar, row: 0, gesture: .doubleClick)
        XCTAssertEqual(opened.map(\.0), [s, secondSessionID, s])
        XCTAssertEqual(opened.map(\.1), [.singleClick, .singleClick, .doubleClick])
    }

    func testSidebarAgentClickOnlyEmitsTypedIntentAndLeavesWorkspaceStateToCoordinator() throws {
        let sessionID = SessionID("dev::target")
        let blank = CorralTab(title: "New Tab", isBlankWorkspace: true)
        let workspace = CorralWorkspaceView(tabs: [blank])
        workspace.sidebar.setAgents([CorralSidebarAgent(name: "next agent", sessionID: sessionID)])
        var opened: [(SessionID, SessionOpenGesture)] = []
        workspace.onSelectAgent = { opened.append(($0, $1)) }

        try completeAgentClick(on: workspace.sidebar, row: 0, gesture: .doubleClick)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.0, sessionID)
        XCTAssertEqual(opened.first?.1, .doubleClick)
        XCTAssertEqual(workspace.activeTabID, blank.id)
        XCTAssertTrue(blank.isBlankWorkspace)
        XCTAssertTrue(blank.sessionIDs.isEmpty)
        XCTAssertNil(blank.activeSessionID)
    }

    func testSidebarWindowGestureRejectsLargeMotionAndCrossRowRelease() throws {
        _ = NSApplication.shared
        let sidebar = CorralSidebarView()
        sidebar.setAgents([CorralSidebarAgent(name: "A", sessionID: a), CorralSidebarAgent(name: "B", sessionID: b)])
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 280, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        window.orderBack(nil)
        defer { window.close() }
        sidebar.layoutSubtreeIfNeeded()
        let table = sidebar.agentsTable
        var opened: [SessionID] = []
        sidebar.onSelectAgent = { id, _ in opened.append(id) }
        let rect = table.rect(ofRow: 0), second = table.rect(ofRow: 1)
        let start = CGPoint(x: rect.midX, y: rect.midY)
        for end in [CGPoint(x: start.x + 5, y: start.y), CGPoint(x: start.x, y: second.midY), start] {
            for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp].enumerated() {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: table.convert(index == 0 ? start : end, to: nil),
                    modifierFlags: [], timestamp: 1 + Double(index) * 0.01, windowNumber: window.windowNumber,
                    context: nil, eventNumber: index, clickCount: 1, pressure: index == 2 ? 0 : 1))
                window.sendEvent(event)
            }
        }
        XCTAssertEqual(opened, [a], "only the final click dispatches, exactly once")
    }

    func testFourPaneSplitNeverWidensOrPinsTheWindow() throws {
        let tab = CorralTab(title: "Grid", contentView: NSView(), isBlankWorkspace: false)
        let workspace = CorralWorkspaceView(tabs: [tab])
        let controller = CorralWindowController(workspaceView: workspace)
        let window = try XCTUnwrap(controller.window)
        let initialFrame = window.frame
        workspace.stageContainer.splitView.update(root: grid, focusedSessionID: a)
        window.layoutIfNeeded()
        XCTAssertEqual(window.frame, initialFrame)
        XCTAssertEqual(workspace.stageContainer.splitView.frame, workspace.stageContainer.bounds)
        let stageSubviews = workspace.stageContainer.subviews
        XCTAssertLessThan(try XCTUnwrap(stageSubviews.firstIndex(of: tab.contentView)), try XCTUnwrap(stageSubviews.firstIndex(of: workspace.stageContainer.splitView)),
                          "Tab content (and its Metal stage) stays beneath the pane chrome")

        let minimumFrame = NSRect(origin: initialFrame.origin, size: window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 1100, height: 700)).size)
        window.setFrame(minimumFrame, display: false)
        window.layoutIfNeeded()
        XCTAssertEqual(window.frame, minimumFrame, "pane chrome has no constraints that could hold the window open")
        XCTAssertEqual(workspace.stageContainer.splitView.projection.panes.count, 4)
        XCTAssertTrue(workspace.stageContainer.splitView.projection.panes.allSatisfy { $0.frame.width >= 120 && $0.frame.height >= 60 })
    }
}

/// A drag in flight without synthesizing host input: AppKit's destination methods are driven directly.
@MainActor
private final class FakeDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("corral-split-test-\(UUID().uuidString)"))
    let draggingLocation: NSPoint
    init(location: NSPoint, strings: [NSPasteboard.PasteboardType: String]) {
        draggingLocation = location
        super.init()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        for (type, value) in strings { item.setString(value, forType: type) }
        pasteboard.writeObjects([item])
    }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
