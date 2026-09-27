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
        XCTAssertEqual(items.map(\.title), ["Copy", "Paste", "Select All", "Clear Buffer"])
        XCTAssertEqual(items.map(\.action), [
            NSSelectorFromString("copy:"),
            NSSelectorFromString("paste:"),
            NSSelectorFromString("selectAll:"),
            NSSelectorFromString("clearTerminalBuffer:")
        ])
        XCTAssertTrue(items.allSatisfy { $0.target === view })
        XCTAssertFalse(view.validateUserInterfaceItem(items[0]), "Copy remains disabled without a selection")
        XCTAssertTrue(view.validateUserInterfaceItem(items[1]))
        XCTAssertTrue(view.validateUserInterfaceItem(items[2]))
        XCTAssertTrue(view.validateUserInterfaceItem(items[3]))

        view.getTerminal().feed(text: "COPY_ME")
        view.selectAll(view)
        XCTAssertTrue(view.selection.active)
        XCTAssertTrue(view.validateUserInterfaceItem(items[0]), "Copy is enabled once text is selected")
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
        let clearItem = try XCTUnwrap(view.menu(for: event)?.items.first { $0.action == NSSelectorFromString("clearTerminalBuffer:") })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(clearItem.action), to: view, from: clearItem))
        XCTAssertFalse(visibleText(in: view).contains("CLEAR_ME"))
        XCTAssertFalse(view.selection.active)
    }

    private func visibleText(in view: TerminalView) -> String {
        (0..<view.getTerminal().rows)
            .compactMap { view.getTerminal().getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }
}
