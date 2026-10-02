import AppKit
import XCTest
@testable import CorralUI

@MainActor
final class Issue337NewAgentDialogLayoutTests: XCTestCase {
    func testOffscreenNewAgentDialogIsCompactWithUnclippedProviderIcons() throws {
        _ = NSApplication.shared
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 800))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderBack(nil)
        defer { window.close() }

        let dialog = NewAgentDialogViewController(spaceName: "Test")
        dialog.present(over: window)
        content.layoutSubtreeIfNeeded()
        dialog.view.layoutSubtreeIfNeeded()
        for button in providerButtons(in: dialog.view) { button.layoutSubtreeIfNeeded() }

        XCTAssertLessThan(window.frame.minX, -1_000)
        XCTAssertLessThan(window.frame.minY, -1_000)
        XCTAssertFalse(window.isKeyWindow, "The offscreen dialog must never take keyboard focus")
        XCTAssertTrue(dialog.presentedWindow === window)
        XCTAssertLessThanOrEqual(dialog.view.frame.height, 360,
                                 "The New Agent dialog card must contract instead of retaining a large empty region")

        let expectedProviders = ["pi", "codex", "cursor", "grok"]
        let buttons = providerButtons(in: dialog.view)
        XCTAssertTrue(Set(expectedProviders).isSubset(of: Set(buttons.compactMap { $0.identifier?.rawValue })),
                      "The dialog must render Pi, Codex, Cursor, and Grok provider choices")
        for provider in expectedProviders {
            let button = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == provider }, "Missing provider button \(provider)")
            let bounds = button.bounds
            _ = try XCTUnwrap(button.image, "\(provider) must have a provider image")
            let imageRect = try XCTUnwrap(button.cell).imageRect(forBounds: bounds)
            XCTAssertTrue(imageRect.width >= 17.5 && imageRect.height >= 17.5,
                          "\(provider) icon must retain its intended 18pt frame")
            XCTAssertGreaterThanOrEqual(imageRect.minX, bounds.minX, "\(provider) icon must not overflow the button's left edge")
            XCTAssertLessThanOrEqual(imageRect.maxX, bounds.maxX, "\(provider) icon must not overflow the button's right edge")
            XCTAssertGreaterThanOrEqual(imageRect.minY, bounds.minY, "\(provider) icon must not be clipped at the button's top edge")
            XCTAssertLessThanOrEqual(imageRect.maxY, bounds.maxY, "\(provider) icon must not overflow the button's bottom edge")
        }

        let cancel = try XCTUnwrap(dialog.cancelButton)
        let create = try XCTUnwrap(dialog.createButton)
        XCTAssertEqual(cancel.frame.midY, create.frame.midY, accuracy: 0.5,
                       "Cancel and create actions must share a clean baseline")
        XCTAssertGreaterThanOrEqual(create.frame.minX, cancel.frame.maxX,
                                    "The action buttons must form an ordered horizontal group")
    }

    private func providerButtons(in root: NSView) -> [NSButton] {
        descendants(of: root).compactMap { $0 as? NSButton }.filter {
            ["pi", "codex", "cursor", "grok"].contains($0.identifier?.rawValue ?? "")
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
