import AppKit
@testable import CorralUI
import XCTest

@MainActor
final class Issue23TabInactiveHoverTests: XCTestCase {
    func testUnselectedTabCloseAndHoverBackgroundFollowMouseEnteredAndExited() throws {
        _ = NSApplication.shared
        let selected = CorralTab(title: "Selected")
        let unselected = CorralTab(title: "Unselected")
        let bar = CorralTabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: 38))
        bar.setTabs([selected, unselected], selectedTabID: selected.id)
        bar.layoutSubtreeIfNeeded()

        let selectedItem = try XCTUnwrap(tabItem(selected, in: bar))
        let item = try XCTUnwrap(tabItem(unselected, in: bar))
        let selectedClose = try closeButton(in: selectedItem)
        let close = try closeButton(in: item)
        XCTAssertGreaterThanOrEqual(selectedClose.alphaValue, 0.7, "The selected Tab keeps its close control visible")
        XCTAssertEqual(close.alphaValue, 0, accuracy: 0.001)
        XCTAssertEqual(item.layer?.backgroundColor?.alpha ?? 0, 0, accuracy: 0.001)

        item.mouseEntered(with: try mouseEnteredExited(.mouseEntered))
        XCTAssertGreaterThanOrEqual(close.alphaValue, 0.7)
        XCTAssertFalse(close.layer?.animationKeys()?.isEmpty ?? true, "The close glyph should fade in, not pop in")
        XCTAssertEqual(item.layer?.backgroundColor, CorralAestheticTokens.hover.cgColor)

        item.mouseExited(with: try mouseEnteredExited(.mouseExited))
        XCTAssertEqual(close.alphaValue, 0, accuracy: 0.001)
        XCTAssertEqual(item.layer?.backgroundColor?.alpha ?? 0, 0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(selectedClose.alphaValue, 0.7)
    }

    private func tabItem(_ tab: CorralTab, in bar: NSView) -> NSView? {
        descendants(of: bar).first {
            $0.accessibilityIdentifier() == "corral.tab" && $0.accessibilityLabel() == tab.title
        }
    }

    private func closeButton(in item: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(of: item).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "corral.tab.close"
        })
    }

    private func mouseEnteredExited(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 1,
                                             windowNumber: 0, context: nil, eventNumber: 0,
                                             trackingNumber: 0, userData: nil))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
