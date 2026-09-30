import AppKit
@testable import CorralUI
import XCTest

@MainActor
final class Issue19TabBarAdaptiveCloseLockTests: XCTestCase {
    func testThreeTabsStayEqualAtThe160PointWidthCap() throws {
        _ = NSApplication.shared
        let tabs = makeTabs(3)
        let bar = makeBar(tabs: tabs, width: 600)
        let widths = tabItems(in: bar).map(\.frame.width)

        XCTAssertEqual(widths.count, 3)
        XCTAssertLessThanOrEqual((widths.max() ?? 0) - (widths.min() ?? 0), 1,
                                 "Three ordinary Tabs must remain equal-width: \(widths)")
        XCTAssertTrue(widths.allSatisfy { abs($0 - 160) < 1 },
                      "Three Tabs in a 600pt bar should use the 160pt cap: \(widths)")
    }

    func testSixTabsShrinkEquallyToFitWithoutHorizontalOverflow() throws {
        _ = NSApplication.shared
        let bar = makeBar(tabs: makeTabs(6), width: 600)
        let widths = tabItems(in: bar).map(\.frame.width)
        let lane = try XCTUnwrap(descendants(of: bar).compactMap { $0 as? NSScrollView }.first)
        let documentWidth = try XCTUnwrap(lane.documentView).frame.width

        XCTAssertLessThanOrEqual((widths.max() ?? 0) - (widths.min() ?? 0), 1,
                                 "Six ordinary Tabs must remain equal-width: \(widths)")
        XCTAssertTrue(widths.allSatisfy { (90...100).contains($0) },
                      "Six Tabs should shrink to about 90–100pt: \(widths)")
        XCTAssertLessThanOrEqual(documentWidth, lane.contentView.bounds.width + 1,
                                 "Six Tabs should fit without horizontal scrolling")
    }

    func testClosingWhilePointerIsInsideLocksWidthsUntilMouseExit() throws {
        _ = NSApplication.shared
        let tabs = makeTabs(6)
        let bar = makeBar(tabs: tabs, width: 600, selectedTabID: tabs[1].id)
        let beforeWidths = tabItems(in: bar).map(\.frame.width)
        let lockedWidth = try XCTUnwrap(beforeWidths.first)
        XCTAssertTrue(beforeWidths.allSatisfy { abs($0 - lockedWidth) < 1 },
                      "The six visible Tabs must start at one shared physical width: \(beforeWidths)")
        var liveTabs = tabs
        bar.onCloseTab = { id in
            liveTabs.removeAll { $0.id == id }
            bar.setTabs(liveTabs, selectedTabID: liveTabs.first?.id)
            bar.layoutSubtreeIfNeeded()
        }

        bar.mouseEntered(with: try mouseEnterExitEvent(.mouseEntered))
        let secondTab = try XCTUnwrap(tabItem(titled: tabs[1].title, in: bar))
        let closeButton = try XCTUnwrap(descendants(of: secondTab).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "corral.tab.close" })
        closeButton.performClick(nil)
        bar.layoutSubtreeIfNeeded()
        let afterClose = tabItems(in: bar).map(\.frame.width)

        XCTAssertTrue((90...100).contains(lockedWidth),
                      "Six Tabs should have adapted before closing: \(beforeWidths)")
        XCTAssertEqual(afterClose.count, 5)
        XCTAssertTrue(afterClose.allSatisfy { abs($0 - lockedWidth) < 1 },
                      "Closing under the pointer must lock each remaining Tab at \(lockedWidth)pt: \(afterClose)")

        bar.mouseExited(with: try mouseEnterExitEvent(.mouseExited))
        bar.layoutSubtreeIfNeeded()
        let afterExit = tabItems(in: bar).map(\.frame.width)
        XCTAssertLessThan(afterClose.first ?? 0, afterExit.first ?? 0,
                          "Mouse exit must release the close-width lock and expand the remaining Tabs: \(afterExit)")
        XCTAssertLessThanOrEqual((afterExit.max() ?? 0) - (afterExit.min() ?? 0), 1,
                                 "Expanded Tabs must remain equal-width: \(afterExit)")
    }

    func testTwentyTabsStopAt44PointsAndCanScrollHorizontally() throws {
        _ = NSApplication.shared
        let bar = makeBar(tabs: makeTabs(20), width: 600)
        let items = tabItems(in: bar)
        let widths = items.map(\.frame.width)
        let lane = try XCTUnwrap(descendants(of: bar).compactMap { $0 as? NSScrollView }.first)
        let documentView = try XCTUnwrap(lane.documentView)
        let clipView = lane.contentView
        let initialOffset = clipView.bounds.origin.x
        let maxOffset = max(0, documentView.frame.width - clipView.bounds.width)

        XCTAssertTrue(widths.allSatisfy { abs($0 - 44) < 1 },
                      "Twenty Tabs must stop shrinking at the 44pt minimum: \(widths)")
        XCTAssertGreaterThan(maxOffset, 0, "Twenty minimum-width Tabs must overflow the visible lane")
        XCTAssertNotEqual(lane.horizontalScrollElasticity, .none,
                          "The overflow lane must allow horizontal scrolling")
        clipView.scroll(to: NSPoint(x: maxOffset, y: initialOffset))
        lane.reflectScrolledClipView(clipView)
        bar.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(clipView.bounds.origin.x, initialOffset,
                             "The Tab lane must be able to scroll to its overflow")
        XCTAssertGreaterThan(items.last?.visibleRect.width ?? 0, 0,
                             "The last Tab must be reachable after horizontal scrolling")
    }

    private func makeBar(tabs: [CorralTab], width: CGFloat, selectedTabID: UUID? = nil) -> CorralTabBarView {
        let bar = CorralTabBarView(frame: NSRect(x: 0, y: 0, width: width, height: 38))
        bar.setTabs(tabs, selectedTabID: selectedTabID ?? tabs.first?.id)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    private func makeTabs(_ count: Int) -> [CorralTab] {
        (0..<count).map { CorralTab(title: "Tab \($0)") }
    }

    private func tabItems(in bar: CorralTabBarView) -> [NSView] {
        bar.tabs.compactMap { tab in tabItem(titled: tab.title, in: bar) }
    }

    private func tabItem(titled title: String, in bar: NSView) -> NSView? {
        descendants(of: bar).first {
            $0.accessibilityIdentifier() == "corral.tab" && $0.accessibilityLabel() == title
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func mouseEnterExitEvent(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
    }
}
