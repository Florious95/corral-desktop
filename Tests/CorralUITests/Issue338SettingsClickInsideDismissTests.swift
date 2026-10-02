import AppKit
import XCTest
@testable import CorralUI

@MainActor
final class Issue338SettingsClickInsideDismissTests: XCTestCase {
    func testBlankClickInsideSettingsKeepsItOpen() throws {
        let (content, window, dialog) = makeFixture()
        defer { dialog.dismiss(); window.close() }
        assertOffscreen(window)
        XCTAssertTrue(dialog.presentedWindow === window, "Settings must start presented")

        let panelFrame = dialog.view.frame
        let blankPoint = NSPoint(x: panelFrame.minX + 6, y: panelFrame.midY)
        XCTAssertTrue(panelFrame.contains(blankPoint))
        let hit = try XCTUnwrap(content.hitTest(blankPoint), "The blank panel coordinate must have a real AppKit hit target")
        XCTAssertTrue(hit === dialog.view || hit.isDescendant(of: dialog.view),
                      "A click in the panel's blank margin must target the panel, not its outside-dismiss overlay")
        XCTAssertFalse(hit is NSControl, "The tested point must be non-interactive empty panel background")

        sendClick(at: blankPoint, in: window)
        XCTAssertTrue(dialog.presentedWindow === window,
                      "Clicking empty space inside Settings must not dismiss the panel")
        XCTAssertNotNil(dialog.view.window, "The settings content must remain attached after an internal click")
    }

    func testClickOutsideSettingsDismisses() throws {
        let (_, window, dialog) = makeFixture()
        defer { dialog.dismiss(); window.close() }
        assertOffscreen(window)
        XCTAssertTrue(dialog.presentedWindow === window)

        let panelFrame = dialog.view.frame
        let outsidePoint = NSPoint(x: 20, y: 20)
        XCTAssertFalse(panelFrame.contains(outsidePoint), "The outside click must be beyond the settings panel bounds")
        sendClick(at: outsidePoint, in: window)
        XCTAssertNil(dialog.presentedWindow, "Clicking outside the panel must dismiss Settings")
        XCTAssertNil(dialog.view.window, "Dismissal must detach Settings from the host window")
    }

    func testSettingsControlStillChangesValueAndKeepsPanelOpen() {
        let (_, window, dialog) = makeFixture()
        defer { dialog.dismiss(); window.close() }
        assertOffscreen(window)
        let before = dialog.values.fontSize
        dialog.fontSizeIncrementButton.performClick(nil)
        XCTAssertEqual(dialog.values.fontSize, before + 1)
        XCTAssertTrue(dialog.presentedWindow === window, "Interacting with a control must not dismiss Settings")
    }

    private func makeFixture() -> (content: NSView, window: NSWindow, dialog: SettingsDialogViewController) {
        _ = NSApplication.shared
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 800))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderBack(nil)
        let dialog = SettingsDialogViewController()
        dialog.present(over: window)
        content.layoutSubtreeIfNeeded()
        dialog.view.superview?.layoutSubtreeIfNeeded()
        return (content, window, dialog)
    }

    private func assertOffscreen(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(window.frame.minX, -1_000, file: file, line: line)
        XCTAssertLessThan(window.frame.minY, -1_000, file: file, line: line)
        XCTAssertFalse(window.isKeyWindow, "The offscreen settings test must not take keyboard focus", file: file, line: line)
    }

    private func sendClick(at point: NSPoint, in window: NSWindow) {
        let start = ProcessInfo.processInfo.systemUptime
        for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: start + Double(index) * 0.01,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: index,
                                                 clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { continue }
            window.sendEvent(event)
        }
    }
}
