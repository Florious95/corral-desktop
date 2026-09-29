import AppKit
@testable import CorralUI
import XCTest

@MainActor
final class Issue7TabMenuTests: XCTestCase {
    func testTabContextMenuOmitsSplitActionsAndKeepsWorkspaceActions() throws {
        _ = NSApplication.shared
        let first = CorralTab(title: "First")
        let second = CorralTab(title: "Second")
        let workspace = CorralWorkspaceView(tabs: [first, second])
        workspace.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        workspace.layoutSubtreeIfNeeded()
        workspace.tabBar.layoutSubtreeIfNeeded()

        let tabItem = try XCTUnwrap(descendants(of: workspace.tabBar).first {
            $0.accessibilityIdentifier() == "corral.tab" && $0.accessibilityLabel() == first.title
        })
        let titles = try XCTUnwrap(tabItem.accessibilityCustomActions()).map(\.name)

        XCTAssertFalse(titles.contains("向右拆分"), "The Tab context menu must not offer split-right")
        XCTAssertFalse(titles.contains("向下拆分"), "The Tab context menu must not offer split-down")
        for required in ["适应当前窗口", "固定到最左", "关闭工作台", "关闭其他工作台", "关闭右侧所有工作台"] {
            XCTAssertTrue(titles.contains(required), "The Tab context menu must retain \(required)")
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
