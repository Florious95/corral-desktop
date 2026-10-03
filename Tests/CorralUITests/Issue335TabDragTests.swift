import AppKit
@testable import CorralUI
import XCTest

/// Issue #335 on the shipped window chrome: a drag that starts on a Tab must reorder Tabs and must
/// never be claimed by the WindowServer as a window move.
@MainActor
final class Issue335TabDragTests: XCTestCase {
    private var controller: CorralWindowController?

    override func tearDown() {
        controller?.window?.orderOut(nil)
        controller = nil
        super.tearDown()
    }

    func testTabsAreOutsideTheServerSideWindowDragRegion() throws {
        let (window, workspace, tabs) = try makeWorkspace()
        let tabPoint = center(of: try tabItem(tabs[1], in: workspace.tabBar))
        let blankPoint = try blankDragPoint(in: workspace.tabBar)

        // Control: a movable full-size-content titlebar hands the whole 32pt strip, including the
        // Tab lane, to the WindowServer. If the instrument cannot see that, its "empty" proves nothing.
        window.isMovable = true
        XCTAssertTrue(try serverDragRects(window).contains { $0.contains(tabPoint) },
                      "Instrument control: a movable titlebar must report the Tab lane as server-draggable")

        window.isMovable = false
        XCTAssertFalse(try serverDragRects(window).contains { $0.contains(tabPoint) },
                       "Pressing a Tab must not let the WindowServer move the window")
        window.isMovable = (CorralWindow() as NSWindow).isMovable
        XCTAssertFalse(window.isMovable, "CorralWindow must ship with server-side titlebar dragging disabled")
        XCTAssertFalse(try serverDragRects(window).contains { $0.contains(tabPoint) })
        XCTAssertFalse(try serverDragRects(window).contains { $0.contains(blankPoint) }, "Blank chrome moves the window from the app, not the server region")
    }

    /// The user's boundary: a press on a Tab never moves the window; a press anywhere else in the top bar does.
    func testEveryNonTabPointOfTheTopBarMovesTheWindowAndTabsNever() throws {
        for collapsed in [false, true] {
            _ = NSApplication.shared
            let tabs = ["Alpha", "Beta", "Gamma"].map { CorralTab(title: $0, isBlankWorkspace: false, provider: "codex") }
            let workspace = CorralWorkspaceView(tabs: tabs)
            let window = MoveRecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                             backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovable = false
            window.alphaValue = 0
            window.contentView = workspace
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            workspace.setSidebarCollapsed(collapsed)
            settle(window)
            workspace.tabBar.needsLayout = true
            settle(window)

            let bar = workspace.tabBar
            let items = try tabs.map { tab -> NSRect in let item = try tabItem(tab, in: bar); return item.convert(item.bounds, to: nil) }
            let plus = bar.createButton.convert(bar.createButton.bounds, to: nil)
            let barFrame = bar.convert(bar.bounds, to: nil)
            var moving: [(String, NSPoint)] = [
                ("left margin of the Tab lane", NSPoint(x: barFrame.minX + (collapsed ? 76 : 4), y: barFrame.midY)),
                ("above a Tab", NSPoint(x: items[1].midX, y: items[1].maxY + 3)),
                ("below a Tab", NSPoint(x: items[1].midX, y: items[1].minY - 3)),
                ("between two Tabs", NSPoint(x: items[0].maxX + 1, y: items[0].midY)),
                ("between the last Tab and +", NSPoint(x: plus.minX - 4, y: plus.midY)),
                ("right of +", NSPoint(x: plus.maxX + 20, y: plus.midY)),
                ("far right of the bar", NSPoint(x: barFrame.maxX - 12, y: barFrame.midY)) // the outermost points are the native resize edge
            ]
            if !collapsed {
                let title = workspace.titleBar.convert(workspace.titleBar.bounds, to: nil)
                let collapse = workspace.titleBar.collapseButton.convert(workspace.titleBar.collapseButton.bounds, to: nil)
                moving += [("between traffic lights and the sidebar toggle", NSPoint(x: (title.minX + 80 + collapse.minX) / 2, y: title.midY)),
                           ("right of the sidebar toggle", NSPoint(x: collapse.maxX + 4, y: collapse.midY)),
                           ("beside the traffic lights", NSPoint(x: title.minX + 76, y: title.midY))]
            }
            for (name, point) in moving {
                window.moves = 0
                send(.leftMouseDown, at: point, in: window)
                send(.leftMouseUp, at: point, in: window)
                XCTAssertEqual(window.moves, 1, "\(collapsed ? "collapsed" : "expanded"): pressing \(name) at \(point) must move the window")
            }
            for (index, item) in items.enumerated() {
                window.moves = 0
                let center = NSPoint(x: item.midX, y: item.midY)
                send(.leftMouseDown, at: center, in: window)
                send(.leftMouseDragged, at: NSPoint(x: center.x + 1, y: center.y + 1), in: window)
                send(.leftMouseUp, at: NSPoint(x: center.x + 1, y: center.y + 1), in: window)
                XCTAssertEqual(window.moves, 0, "Pressing Tab \(index) must never move the window")
            }
            // Pressing a real button would enter its tracking loop; hit-testing proves it keeps its own clicks.
            let content = try XCTUnwrap(window.contentView)
            XCTAssertTrue(content.hitTest(content.convert(NSPoint(x: plus.midX, y: plus.midY), from: nil)) === bar.createButton, "+ stays a button")
        }
    }

    func testDraggingATabLiftsItFollowsThePointerAndNeighboursMakeRoom() throws {
        let (window, workspace, tabs) = try makeWorkspace()
        let bar = workspace.tabBar
        var commits: [(UUID, Int)] = []
        let persist = bar.onReorderTabs
        bar.onReorderTabs = { id, index in commits.append((id, index)); persist?(id, index) }
        let source = try tabItem(tabs[0], in: bar)
        let neighbour = try tabItem(tabs[1], in: bar)
        let neighbourStart = neighbour.convert(neighbour.bounds, to: nil).minX
        let width = source.frame.width
        let start = center(of: source)

        send(.leftMouseDown, at: start, in: window)
        send(.leftMouseDragged, at: NSPoint(x: start.x + 2, y: start.y), in: window)
        XCTAssertNil(ghost(in: bar), "A 2pt tremor is still a click, not a drag")

        let firstMove = NSPoint(x: start.x + 20, y: start.y + 3)
        send(.leftMouseDragged, at: firstMove, in: window)
        let lifted = try XCTUnwrap(ghost(in: bar), "Crossing the drag threshold must lift the Tab card")
        XCTAssertEqual(lifted.alphaValue, 0.5, accuracy: 0.01, "The lifted card is translucent")
        XCTAssertEqual(lifted.convert(lifted.bounds, to: nil).midX, firstMove.x, accuracy: 0.5, "The card stays under the pointer")
        XCTAssertEqual(lifted.convert(lifted.bounds, to: nil).midY, start.y, accuracy: 0.5, "The card stays in the Tab lane")
        XCTAssertEqual(source.alphaValue, 0, "The source slot is left open while the card is lifted")
        XCTAssertEqual(neighbour.convert(neighbour.bounds, to: nil).minX, neighbourStart, accuracy: 0.5,
                       "A neighbour must not move before the card crosses its midline")

        let crossed = NSPoint(x: start.x + width * 0.75, y: start.y)
        send(.leftMouseDragged, at: crossed, in: window)
        bar.layoutSubtreeIfNeeded()
        XCTAssertLessThan(neighbour.convert(neighbour.bounds, to: nil).minX, neighbourStart - width / 2,
                          "Crossing the neighbour's midline must slide it into the vacated slot")
        XCTAssertEqual(try XCTUnwrap(ghost(in: bar)).convert(lifted.bounds, to: nil).midX, crossed.x, accuracy: 0.5)
        XCTAssertEqual(workspace.tabs.map(\.id), tabs.map(\.id), "Nothing is persisted while the card is still held")
        XCTAssertTrue(commits.isEmpty)

        send(.leftMouseUp, at: crossed, in: window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(ghost(in: bar), "Dropping must settle the card back into the lane")
        XCTAssertEqual(source.alphaValue, 1)
        XCTAssertEqual(commits.map(\.0), [tabs[0].id])
        XCTAssertEqual(commits.map(\.1), [1])
        XCTAssertEqual(workspace.tabs.map(\.id), [tabs[1].id, tabs[0].id, tabs[2].id], "The drop order is persisted")
        XCTAssertEqual(workspace.activeTabID, tabs[2].id, "Reordering must not change the selected Tab")
    }

    func testAnInstantDragWithoutHoldTimeStillReorders() throws {
        let (window, workspace, tabs) = try makeWorkspace()
        let source = try tabItem(tabs[0], in: workspace.tabBar)
        let target = try tabItem(tabs[2], in: workspace.tabBar)
        let start = center(of: source)
        let end = NSPoint(x: target.convert(target.bounds, to: nil).maxX - 4, y: start.y)
        let timestamp = ProcessInfo.processInfo.systemUptime

        send(.leftMouseDown, at: start, in: window, timestamp: timestamp)
        send(.leftMouseDragged, at: end, in: window, timestamp: timestamp)
        send(.leftMouseUp, at: end, in: window, timestamp: timestamp)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(workspace.tabs.map(\.id), [tabs[1].id, tabs[2].id, tabs[0].id])

        // A press and a distant release with every intermediate drag event coalesced away.
        let moved = try tabItem(tabs[0], in: workspace.tabBar)
        let first = try tabItem(tabs[1], in: workspace.tabBar)
        send(.leftMouseDown, at: center(of: moved), in: window, timestamp: timestamp)
        send(.leftMouseUp, at: NSPoint(x: first.convert(first.bounds, to: nil).minX + 4, y: start.y), in: window, timestamp: timestamp)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(workspace.tabs.map(\.id), [tabs[0].id, tabs[1].id, tabs[2].id])
        XCTAssertNil(ghost(in: workspace.tabBar))
    }

    func testClickingATabStillSelectsItWithoutReordering() throws {
        let (window, workspace, tabs) = try makeWorkspace()
        let point = center(of: try tabItem(tabs[1], in: workspace.tabBar))
        var selected: [UUID] = []
        workspace.tabBar.onSelectTab = { selected.append($0) }

        send(.leftMouseDown, at: point, in: window)
        send(.leftMouseDragged, at: NSPoint(x: point.x + 3, y: point.y - 1), in: window)
        send(.leftMouseUp, at: NSPoint(x: point.x + 3, y: point.y - 1), in: window)

        XCTAssertEqual(selected, [tabs[1].id])
        XCTAssertEqual(workspace.tabs.map(\.id), tabs.map(\.id))
        XCTAssertNil(ghost(in: workspace.tabBar))
    }

    // MARK: - Fixture

    private func makeWorkspace() throws -> (NSWindow, CorralWorkspaceView, [CorralTab]) {
        _ = NSApplication.shared
        let tabs = ["Alpha", "Beta", "Gamma"].map { CorralTab(title: $0, isBlankWorkspace: false, provider: "codex") }
        let workspace = CorralWorkspaceView(tabs: tabs)
        let controller = CorralWindowController(workspaceView: workspace, contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700))
        self.controller = controller
        let window = try XCTUnwrap(controller.window)
        window.alphaValue = 0
        window.orderFrontRegardless()
        workspace.selectTab(id: tabs[2].id)
        settle(window)
        // Reach the steady lane geometry (full-width Tabs) the running app has before any drag.
        workspace.tabBar.needsLayout = true
        settle(window)
        return (window, workspace, tabs)
    }

    private final class MoveRecordingWindow: NSWindow {
        var moves = 0
        override func performDrag(with event: NSEvent) { moves += 1 }
    }

    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// The drag region AppKit last handed to the WindowServer, in window coordinates.
    private func serverDragRects(_ window: NSWindow) throws -> [NSRect] {
        settle(window)
        let selector = NSSelectorFromString("_lastDragRegionDataDescription")
        guard window.responds(to: selector),
              let text = window.perform(selector)?.takeUnretainedValue() as? String else {
            throw XCTSkip("This macOS does not expose AppKit's WindowServer drag-region diagnostic")
        }
        if text.contains("empty drag region") { return [] }
        let rects = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("{{") }.map { NSRectFromString($0) }
        guard !rects.isEmpty else { throw XCTSkip("Unrecognised drag-region diagnostic: \(text)") }
        return rects
    }

    private func blankDragPoint(in bar: CorralTabBarView) throws -> NSPoint {
        let plus = bar.createButton.convert(bar.createButton.bounds, to: nil)
        let barFrame = bar.convert(bar.bounds, to: nil)
        XCTAssertGreaterThan(barFrame.maxX - plus.maxX, 40)
        return NSPoint(x: (plus.maxX + barFrame.maxX) / 2, y: plus.midY)
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: timestamp,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
            return XCTFail("Could not build \(type)")
        }
        window.sendEvent(event)
    }

    private func center(of view: NSView) -> NSPoint {
        let frame = view.convert(view.bounds, to: nil)
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    private func tabItem(_ tab: CorralTab, in bar: NSView) throws -> NSView {
        try XCTUnwrap(descendants(of: bar).first {
            $0.accessibilityIdentifier() == "corral.tab" && $0.accessibilityLabel() == tab.title && !$0.isDescendant(of: ghost(in: bar) ?? NSView())
        }, "Missing Tab \(tab.title)")
    }

    private func ghost(in bar: NSView) -> NSView? {
        descendants(of: bar).first { $0.accessibilityIdentifier() == "corral.tab.dragCard" }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
