import AppKit
import XCTest
@preconcurrency import SwiftTerm
@testable import CorralApp

@MainActor
final class CorralNativeTerminalContextMenuTests: XCTestCase {
    func testContextMenuProvidesNativeTerminalActions() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.corral.native-menu-tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let view = CorralNativeTerminalView(frame: .zero, pasteboard: pasteboard)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        let menu = try XCTUnwrap(view.menu(for: event))
        let items = menu.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(items.map(\.title), ["复制", "粘贴", "全选", "清屏"])
        XCTAssertEqual(items.map(\.action), [
            NSSelectorFromString("copySelection"),
            NSSelectorFromString("pasteClipboard"),
            NSSelectorFromString("selectAll:"),
            NSSelectorFromString("clearScreen")
        ])
        XCTAssertTrue(items[0].target === menu)
        XCTAssertTrue(items[1].target === menu)
        XCTAssertTrue(items[2].target === view)
        XCTAssertTrue(items[3].target === menu)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(items[1].action), to: menu, from: items[1]))

        view.getTerminal().feed(text: "COPY_ME")
        view.selectAll(view)
        XCTAssertTrue(view.selection.active)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(items[0].action), to: menu, from: items[0]), "Copy dispatches through the shared terminal context menu")
    }

    func testClearBufferActionClearsSwiftTermStateAndSelection() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.corral.native-menu-clear-tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let view = CorralNativeTerminalView(frame: .zero, pasteboard: pasteboard)
        view.getTerminal().feed(text: "CLEAR_ME")
        XCTAssertTrue(visibleText(in: view).contains("CLEAR_ME"))

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let menu = try XCTUnwrap(view.menu(for: event))
        let clearItem = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("clearScreen") })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(clearItem.action), to: menu, from: clearItem))
        XCTAssertFalse(visibleText(in: view).contains("CLEAR_ME"))
        XCTAssertFalse(view.selection.active)
    }

    private func visibleText(in view: TerminalView) -> String {
        (0..<view.getTerminal().rows)
            .compactMap { view.getTerminal().getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }
}
