import AppKit
@testable import CorralUI
import XCTest

@MainActor
final class NativeContextMenuTests: XCTestCase {
    func testTerminalContextMenuRoutesCopyPasteAndClearActions() throws {
        var actions: [String] = []
        let menu = CorralTerminalContextMenu(
            onCopy: { actions.append("copy") },
            onPaste: { actions.append("paste") },
            onClear: { actions.append("clear") }
        )
        XCTAssertEqual(menu.items.map(\.title), ["复制", "粘贴", "", "清屏"])
        for item in menu.items where !item.isSeparatorItem {
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        XCTAssertEqual(actions, ["copy", "paste", "clear"])
    }
}
