import AppKit
@testable import CorralUI
import XCTest

@MainActor
final class NativeCardPanelTests: XCTestCase {
    func testHostCardPanelUsesMeasuredWindowAndButtonOffsets() {
        let window = NSRect(x: 100, y: 200, width: 1400, height: 980)
        let source = NSRect(x: 112, y: 204, width: 222, height: 35)
        let frame = CorralAnchoredCardPanel.frame(
            contentSize: NSSize(width: 300, height: 255),
            sourceRectInScreen: source,
            windowFrame: window
        )
        XCTAssertEqual(CorralAnchoredCardPanel.cardWidth, 300)
        XCTAssertEqual(frame, NSRect(x: 110, y: 254, width: 300, height: 255))
    }

    func testHostCardStaysInsideTheVisibleScreenNearItsEdges() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        // Window pushed against the top-right: the card would otherwise leave the screen.
        let frame = CorralAnchoredCardPanel.frame(
            contentSize: NSSize(width: 300, height: 405),
            sourceRectInScreen: NSRect(x: 1300, y: 700, width: 222, height: 35),
            windowFrame: NSRect(x: 1288, y: 500, width: 600, height: 400),
            visibleFrame: visible
        )
        XCTAssertTrue(visible.insetBy(dx: 8, dy: 8).contains(frame), "\(frame) must stay on screen")
        XCTAssertEqual(frame.size, NSSize(width: 300, height: 405))
    }

    func testCardPanelIsBorderlessAndAnchorsToTheHostButton() throws {
        let anchorWindow = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 1400, height: 980), styleMask: [.borderless], backing: .buffered, defer: false)
        let source = NSButton(frame: NSRect(x: 12, y: 4.5, width: 222, height: 35))
        let contentView = try XCTUnwrap(anchorWindow.contentView)
        contentView.addSubview(source)
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 255))
        controller.preferredContentSize = NSSize(width: 300, height: 255)

        let panel = CorralAnchoredCardPanel(contentViewController: controller, anchoredTo: source)
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertFalse(panel.styleMask.contains(.titled))
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertEqual(panel.frame, NSRect(x: 110, y: 254, width: 300, height: 255))
    }
}
