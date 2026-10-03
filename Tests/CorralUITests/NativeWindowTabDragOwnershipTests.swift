import AppKit
import XCTest
@testable import CorralUI

@MainActor
final class NativeWindowTabDragOwnershipTests: XCTestCase {
    func testFullSizeTitlebarCannotAutomaticallyMoveTheWindow() {
        _ = NSApplication.shared
        let window = CorralWindow(contentRect: NSRect(x: 200, y: 200, width: 1000, height: 640))
        defer { window.close() }
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(window.isMovable, "Tab capsules overlap the native titlebar: disable server-side automatic dragging, not just background dragging")
        XCTAssertFalse(window.isMovableByWindowBackground)
        window.setFrame(NSRect(x: 240, y: 260, width: 1100, height: 700), display: false)
        XCTAssertEqual(window.frame, NSRect(x: 240, y: 260, width: 1100, height: 700), "Disabling automatic dragging must not prevent resizing or explicit frame changes")
        XCTAssertFalse(window.isVisible)
    }

    func testBlankChromeStillRequestsExplicitWindowDrag() {
        _ = NSApplication.shared
        let window = ExplicitDragSpyWindow(contentRect: NSRect(x: 200, y: 200, width: 1000, height: 640), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.isMovable = false
        defer { window.close() }
        let region = CorralWindowDragRegion(frame: NSRect(x: 700, y: 600, width: 250, height: 38))
        window.contentView?.addSubview(region)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 720, y: 621), modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        region.mouseDown(with: event)
        XCTAssertTrue(window.requestedDragEvent === event)
        XCTAssertFalse(window.isMovable, "Explicit blank-chrome drag must not re-enable automatic titlebar dragging")
        XCTAssertFalse(window.isVisible)
    }
}

// Records the public API handoff without entering the host OS drag manager.
@MainActor
private final class ExplicitDragSpyWindow: NSWindow {
    var requestedDragEvent: NSEvent?
    override func performDrag(with event: NSEvent) { requestedDragEvent = event }
}
