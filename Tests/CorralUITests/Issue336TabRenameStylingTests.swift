import AppKit
import XCTest
@testable import CorralUI

@MainActor
final class Issue336TabRenameStylingTests: XCTestCase {
    func testOffscreenDoubleClickEditorHasMinimalBorderAndFitsTabCapsule() throws {
        _ = NSApplication.shared
        let tab = CorralTab(title: "Rename me")
        let workspace = CorralWorkspaceView(tabs: [CorralTab(title: "Selected"), tab])
        workspace.frame = NSRect(x: 0, y: 0, width: 1400, height: 860)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1400, height: 860),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = workspace
        window.orderBack(nil)
        defer { window.close() }
        workspace.layoutSubtreeIfNeeded()
        workspace.tabBar.layoutSubtreeIfNeeded()

        XCTAssertLessThan(window.frame.minX, -1_000)
        XCTAssertLessThan(window.frame.minY, -1_000)
        XCTAssertFalse(window.isKeyWindow, "The offscreen test window must never take keyboard focus")

        let bar = workspace.tabBar
        let item = try XCTUnwrap(descendants(of: bar).first {
            $0.accessibilityIdentifier() == "corral.tab" && $0.accessibilityLabel() == tab.title
        }, "The test must locate the real rendered TabItem")
        let title = try XCTUnwrap(descendants(of: item).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "corral.tab.title" })
        let point = title.convert(NSPoint(x: title.bounds.midX, y: title.bounds.midY), to: nil)
        sendDoubleClick(at: point, in: window)

        let field = try XCTUnwrap(descendants(of: item).compactMap { $0 as? CorralInlineRenameField }.first,
                                  "Double-clicking the Tab title must open its inline editor")
        XCTAssertEqual(field.focusRingType, .none, "Inline rename must not draw AppKit's default focus ring")
        XCTAssertFalse(field.isBordered, "Inline rename must not display a heavy NSTextField border")
        XCTAssertGreaterThanOrEqual(field.frame.minX, 0, "The editor must fit inside the Tab capsule horizontally")
        XCTAssertLessThanOrEqual(field.frame.maxX, item.bounds.width, "The editor must not overflow the capsule horizontally")
        XCTAssertGreaterThanOrEqual(field.frame.minY, 0, "The editor must fit inside the Tab capsule vertically")
        XCTAssertLessThanOrEqual(field.frame.maxY, item.bounds.height, "The editor must not overflow the capsule vertically")
        XCTAssertLessThanOrEqual(field.frame.height, item.bounds.height, "The editor must be no taller than its Tab capsule")
    }

    private func sendDoubleClick(at point: NSPoint, in window: NSWindow) {
        let start = ProcessInfo.processInfo.systemUptime
        let events: [(NSEvent.EventType, Int, TimeInterval)] = [
            (.leftMouseDown, 1, start), (.leftMouseUp, 1, start + 0.05),
            (.leftMouseDown, 2, start + 0.15), (.leftMouseUp, 2, start + 0.20)
        ]
        for (index, event) in events.enumerated() {
            guard let event = NSEvent.mouseEvent(with: event.0, location: point, modifierFlags: [], timestamp: event.2,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: index,
                                                 clickCount: event.1, pressure: event.0 == .leftMouseUp ? 0 : 1) else { continue }
            window.sendEvent(event)
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
