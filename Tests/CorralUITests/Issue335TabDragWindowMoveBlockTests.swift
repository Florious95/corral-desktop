import AppKit
import XCTest
@testable import CorralUI

/// Verifies AppKit drag ownership and the real preview after the system drag payload is parsed.
/// Pasteboard IPC and the OS drag manager remain separate integration-test boundaries.
@MainActor
final class Issue335TabDragWindowMoveBlockTests: XCTestCase {
    func testTabDragIsOwnedByTabBarAndCannotMoveWindow() throws {
        _ = NSApplication.shared
        let tabA = CorralTab(title: "Tab A")
        let tabB = CorralTab(title: "Tab B")
        let tabC = CorralTab(title: "Tab C")
        let workspace = CorralWorkspaceView(tabs: [tabA, tabB, tabC])
        workspace.frame = NSRect(x: 0, y: 0, width: 1400, height: 860)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1400, height: 860),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = workspace
        defer { window.close() }
        workspace.layoutSubtreeIfNeeded()
        workspace.tabBar.layoutSubtreeIfNeeded()

        XCTAssertLessThan(window.frame.minX, -1_000)
        XCTAssertLessThan(window.frame.minY, -1_000)
        XCTAssertFalse(window.isKeyWindow, "The offscreen test window must never take keyboard focus")
        XCTAssertFalse(window.isVisible, "The geometry-only test window must never be shown")

        let bar = workspace.tabBar
        let source = try tabItem("Tab A", in: bar)
        let target = try tabItem("Tab B", in: bar)
        let originalWindowFrame = window.frame

        XCTAssertFalse(source.mouseDownCanMoveWindow,
                       "A TabItem must own its drag gesture instead of passing it to AppKit window dragging")
        XCTAssertFalse(bar.mouseDownCanMoveWindow,
                       "The TabBar must never be interpreted as a window-drag region")
        XCTAssertTrue(source is NSDraggingSource,
                      "The hit-tested TabItem must provide the internal tab drag source")

        // Use the same parsed-payload destination and preview path as Issue24, without pasteboard IPC.
        let dropPoint = target.convert(NSPoint(x: target.bounds.maxX - 1, y: target.bounds.midY), to: nil)
        XCTAssertEqual(bar.updateTabDragPreview(bar.dragDestination(at: dropPoint, tabID: tabA.id)), .move)
        XCTAssertLessThan(source.alphaValue, 0.75, "The internal tab drag preview should make its source translucent")
        XCTAssertEqual(window.frame, originalWindowFrame, "The tab drag preview must not move the window")
        XCTAssertFalse(window.isVisible, "The tab drag preview must not show the test window")
    }

    private func tabItem(_ title: String, in bar: NSView, file: StaticString = #filePath, line: UInt = #line) throws -> NSView {
        try XCTUnwrap(descendants(of: bar).first {
            $0.accessibilityIdentifier() == "corral.tab" && $0.accessibilityLabel() == title
        }, "Missing TabItem \(title)", file: file, line: line)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
