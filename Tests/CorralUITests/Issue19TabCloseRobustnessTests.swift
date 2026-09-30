import AppKit
@testable import CorralUI
import XCTest

@MainActor
final class Issue19TabCloseRobustnessTests: XCTestCase {
    func testInsideMouseExitedAfterCloseMustNotUnlockWidths() throws {
        _ = NSApplication.shared
        let tabs = makeTabs(6, provider: "codex")
        let bar = CorralTabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: 38))
        let window = NSWindow(contentRect: bar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = bar
        bar.setTabs(tabs, selectedTabID: tabs[0].id)
        settle(bar, window)
        let before = try XCTUnwrap(tabItem(tabs[0], in: bar)).frame.width
        let closeButton = try XCTUnwrap(closeButton(for: tabs[0], in: bar))
        let clickInBar = bar.convert(NSPoint(x: closeButton.bounds.midX, y: closeButton.bounds.midY), from: closeButton)
        let clickInWindow = bar.convert(clickInBar, to: nil)
        bar.mouseEntered(with: try event(.mouseEntered, at: clickInWindow, in: window))

        var remaining = tabs
        bar.onCloseTab = { id in
            remaining.removeAll { $0.id == id }
            bar.setTabs(remaining, selectedTabID: remaining.first?.id)
        }
        closeButton.performClick(nil)
        settle(bar, window)
        let afterClose = tabItems(in: bar).map(\.frame.width)
        let lockedWidth = reflectedWidthLock(in: bar)

        XCTAssertEqual(remaining.count, 5)
        XCTAssertTrue(afterClose.allSatisfy { abs($0 - before) < 0.5 }, "The close action must hold every surviving Tab at its pre-close width: \(afterClose)")
        XCTAssertEqual(lockedWidth ?? -1, before, accuracy: 0.5, "The close action should establish the physical-width lock")

        // Model a stale tracking-area exit delivered while the pointer's actual
        // event location is still over this TabBar (e.g. the closed child vanished).
        let falseExit = try event(.mouseExited, at: clickInWindow, in: window)
        XCTAssertTrue(bar.bounds.contains(bar.convert(falseExit.locationInWindow, from: nil)), "The synthetic exit must report an in-bounds physical location")
        bar.mouseExited(with: falseExit)
        settle(bar, window)

        let widthAfterFalseExit = tabItems(in: bar).map(\.frame.width)
        XCTAssertEqual(reflectedWidthLock(in: bar) ?? -1, before, accuracy: 0.5,
                       "An exit event whose physical location is still inside the TabBar must not clear lockedTabWidth")
        XCTAssertTrue(widthAfterFalseExit.allSatisfy { abs($0 - before) < 0.5 },
                      "A false mouseExited must not animate surviving Tabs open: \(widthAfterFalseExit)")
    }

    func testVisibleTabItemElementsNeverOverlapAt44To60PointWidths() throws {
        _ = NSApplication.shared
        for (count, expectedRange) in [(20, 44.0...44.0), (9, 59.0...60.0)] {
            let tabs = makeTabs(count, provider: "codex")
            let bar = CorralTabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: 38))
            bar.setTabs(tabs, selectedTabID: tabs[0].id)
            bar.layoutSubtreeIfNeeded()
            let items = tabItems(in: bar)
            XCTAssertEqual(items.count, count)

            for (index, item) in items.enumerated() {
                XCTAssertTrue(expectedRange.contains(item.frame.width), "Tab \(index) expected width \(expectedRange), got \(item.frame.width)")
                let collisions = visibleElementOverlaps(in: item)
                XCTAssertTrue(collisions.isEmpty,
                              "Tab \(index) at \(item.frame.width)pt has overlapping status/provider/title/close frames: \(collisions)")
            }
        }
    }

    func testCompactToRegularUnlockTransitionKeepsVisibleElementsDisjoint() throws {
        _ = NSApplication.shared
        let tabs = makeTabs(20, provider: "codex")
        let bar = CorralTabBarView(frame: NSRect(x: 0, y: 0, width: 950, height: 38))
        let window = NSWindow(contentRect: bar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = bar
        bar.setTabs(tabs, selectedTabID: tabs[0].id)
        settle(bar, window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25)) // let initial 160→44 adaptation finish
        bar.layoutSubtreeIfNeeded()
        bar.mouseEntered(with: try event(.mouseEntered, at: NSPoint(x: 30, y: 19), in: window))
        XCTAssertTrue(tabItems(in: bar).allSatisfy { abs($0.frame.width - 44) < 0.5 })

        var remaining = tabs
        bar.onCloseTab = { id in
            remaining.removeAll { $0.id == id }
            bar.setTabs(remaining, selectedTabID: remaining.first?.id)
        }
        for _ in 0..<11 {
            let first = try XCTUnwrap(bar.tabs.first)
            try XCTUnwrap(closeButton(for: first, in: bar)).performClick(nil)
            bar.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(bar.tabs.count, 9)
        XCTAssertTrue(tabItems(in: bar).allSatisfy { abs($0.frame.width - 44) < 0.5 }, "Widths should remain locked at 44pt until the pointer exits")

        let outside = try event(.mouseExited, at: NSPoint(x: -1, y: 19), in: window)
        bar.mouseExited(with: outside)
        let start = Date()
        let samples: [TimeInterval] = [0, 0.005, 0.02, 0.05, 0.1, 0.18, 0.25]
        for delay in samples {
            let target = start.addingTimeInterval(delay)
            if target > Date() { RunLoop.main.run(until: target) }
            bar.layoutSubtreeIfNeeded()
            let currentItems = tabItems(in: bar)
            let overlaps = currentItems.enumerated().flatMap { index, item in
                visibleElementOverlaps(in: item, presentation: true).map { "Tab \(index): \($0)" }
            }
            XCTAssertTrue(overlaps.isEmpty, "At unlock animation sample +\(delay)s, visible Tab elements overlap: \(overlaps)")
        }
    }

    private func makeTabs(_ count: Int, provider: String? = nil) -> [CorralTab] {
        (0..<count).map { CorralTab(title: "Tab \($0)", provider: provider) }
    }

    private func tabItems(in bar: CorralTabBarView) -> [NSView] {
        bar.tabs.compactMap { tab in
            descendants(of: bar).first { $0.accessibilityIdentifier() == "corral.tab" && $0.accessibilityLabel() == tab.title }
        }
    }

    private func tabItem(_ tab: CorralTab, in bar: NSView) -> NSView? {
        descendants(of: bar).first { $0.accessibilityIdentifier() == "corral.tab" && $0.accessibilityLabel() == tab.title }
    }

    private func closeButton(for tab: CorralTab, in bar: NSView) -> NSButton? {
        guard let item = tabItem(tab, in: bar) else { return nil }
        return descendants(of: item).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "corral.tab.close" }
    }

    private func visibleElementOverlaps(in item: NSView, presentation: Bool = false) -> [String] {
        let elements = item.subviews.filter { view in
            guard !view.isHidden, view.frame.width > 0, view.frame.height > 0 else { return false }
            return view.accessibilityIdentifier() == "corral.tab.title"
                || view.accessibilityIdentifier() == "corral.tab.close"
                || view is CorralStatusIndicatorView
                || view is NSImageView
        }
        var collisions: [String] = []
        for i in elements.indices {
            for j in elements.indices where j > i {
                let firstFrame = presentation ? elements[i].layer?.presentation()?.frame ?? elements[i].frame : elements[i].frame
                let secondFrame = presentation ? elements[j].layer?.presentation()?.frame ?? elements[j].frame : elements[j].frame
                let intersection = firstFrame.intersection(secondFrame)
                if !intersection.isNull && intersection.width > 0.01 && intersection.height > 0.01 {
                    collisions.append("\(role(elements[i]))×\(role(elements[j])) area=\(intersection.width * intersection.height) frames=\(NSStringFromRect(firstFrame))/\(NSStringFromRect(secondFrame))")
                }
            }
        }
        return collisions
    }

    private func role(_ view: NSView) -> String {
        if view.accessibilityIdentifier() == "corral.tab.title" { return "title" }
        if view.accessibilityIdentifier() == "corral.tab.close" { return "close" }
        if view is CorralStatusIndicatorView { return "status" }
        return "provider-icon"
    }

    private func reflectedWidthLock(in bar: CorralTabBarView) -> CGFloat? {
        guard let value = Mirror(reflecting: bar).children.first(where: { $0.label == "lockedTabWidth" })?.value,
              let wrapped = Mirror(reflecting: value).children.first?.value as? CGFloat else { return nil }
        return wrapped
    }

    private func settle(_ bar: CorralTabBarView, _ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        bar.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        bar.layoutSubtreeIfNeeded()
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             trackingNumber: 0, userData: nil))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
