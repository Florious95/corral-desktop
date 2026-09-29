import AppKit
import XCTest
@preconcurrency import SwiftTerm
@testable import CorralApp

@MainActor
final class Issue1TerminalContextMenuTests: XCTestCase {
    func testRightClickMenuContainsWorkspaceAndTerminalActions() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.corral.issue1-context-menu.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let terminal = CorralNativeTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480), pasteboard: pasteboard)
        var actions: [String] = []
        terminal.workspaceContextMenuActions = {
            .init(onAdapt: { actions.append("adapt") },
                  onClosePane: { actions.append("close") })
        }
        let rightClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 32, y: 32),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        let menu = try XCTUnwrap(terminal.menu(for: rightClick), "Right-clicking the terminal must produce its context menu")
        let actual = menu.items.map { $0.isSeparatorItem ? "<separator>" : $0.title }
        XCTAssertEqual(actual, [
            "适应当前窗口",
            "关闭此分屏",
            "<separator>",
            "复制",
            "粘贴",
            "全选",
            "<separator>",
            "清屏",
        ], "Terminal menu must retain its required workspace and terminal actions without sidebar-only favorites")
        XCTAssertFalse(actual.contains("收藏"), "Favorite belongs to the sidebar session row, not the terminal context menu")
        XCTAssertFalse(actual.contains("取消收藏"), "Unfavorite belongs to the sidebar session row, not the terminal context menu")
        for item in menu.items where ["适应当前窗口", "关闭此分屏"].contains(item.title) {
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        XCTAssertEqual(actions, ["adapt", "close"])
    }
}
