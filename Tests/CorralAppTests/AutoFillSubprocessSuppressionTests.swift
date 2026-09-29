import AppKit
import XCTest
@preconcurrency import SwiftTerm
@testable import CorralApp

@MainActor
final class AutoFillSubprocessSuppressionTests: XCTestCase {
    func testTerminalTextInputClientDeclaresNoAutofillContentType() throws {
        let terminal = CorralNativeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let textContent = terminal as? NSTextContent
        XCTAssertNotNil(textContent, "The terminal input client must explicitly expose NSTextContent.contentType for AutoFill suppression")
        XCTAssertNil(textContent?.contentType, "A terminal stream is not a password, credential, or form field")
    }

    func testTerminalRightClickMenuContainsNoAutoFillItems() throws {
        let terminal = CorralNativeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let event = try XCTUnwrap(NSEvent.mouseEvent(
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
        let menu = try XCTUnwrap(terminal.menu(for: event))
        let autoFillItems = allItems(in: menu).filter { item in
            item.title.localizedCaseInsensitiveContains("autofill")
                || (item.identifier?.rawValue.localizedCaseInsensitiveContains("autofill") ?? false)
        }
        XCTAssertTrue(autoFillItems.isEmpty, "Terminal menus must not expose system AutoFill actions: \(autoFillItems.map(\.title))")
    }

    private func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allItems) ?? [])
        }
    }
}
