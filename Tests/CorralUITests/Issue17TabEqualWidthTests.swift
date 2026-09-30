import AppKit
import CorralContracts
@testable import CorralUI
import XCTest

@MainActor
final class Issue17TabEqualWidthTests: XCTestCase {
    func testShortAndLongTitlesKeepTabItemsTheSameWidth() throws {
        _ = NSApplication.shared
        let shortTitle = "全自动编排 leader"
        let longTitle = "排查新加坡 VPN 82 主机代理故障"
        let tabs = [CorralTab(title: shortTitle), CorralTab(title: longTitle)]
        let bar = CorralTabBarView(frame: NSRect(x: 0, y: 0, width: 1100, height: 38))
        bar.setTabs(tabs, selectedTabID: tabs[0].id)
        bar.layoutSubtreeIfNeeded()

        let shortTab = try XCTUnwrap(tabItem(titled: shortTitle, in: bar))
        let longTab = try XCTUnwrap(tabItem(titled: longTitle, in: bar))
        XCTAssertEqual(shortTab.frame.width, longTab.frame.width, accuracy: 1,
                       "Short and long titles must not change their TabItemView widths")
    }

    func testLongTitleTruncatesAndKeepsItsFullTitleAsTooltip() throws {
        _ = NSApplication.shared
        let longTitle = "排查新加坡 VPN 82 主机代理故障：再次检查所有主机的代理转发与 VPN DNS 路由状态"
        let bar = CorralTabBarView(frame: NSRect(x: 0, y: 0, width: 1100, height: 38))
        bar.setTabs([CorralTab(title: "全自动编排 leader"), CorralTab(title: longTitle)], selectedTabID: nil)
        bar.layoutSubtreeIfNeeded()

        let longTab = try XCTUnwrap(tabItem(titled: longTitle, in: bar))
        let titleLabel = try XCTUnwrap(descendants(of: longTab).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "corral.tab.title" })
        let naturalWidth = ceil((longTitle as NSString).size(withAttributes: [.font: try XCTUnwrap(titleLabel.font)]).width)

        XCTAssertEqual(titleLabel.lineBreakMode, .byTruncatingTail,
                       "A long Tab title must be rendered with tail truncation")
        XCTAssertLessThan(titleLabel.frame.width, naturalWidth,
                          "The title field must be narrower than its full, untruncated text")
        XCTAssertEqual(longTab.toolTip, longTitle,
                       "Hovering a truncated Tab must expose the complete title")
    }

    private func tabItem(titled title: String, in bar: NSView) -> NSView? {
        descendants(of: bar).first {
            $0.accessibilityIdentifier() == "corral.tab" && $0.accessibilityLabel() == title
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
