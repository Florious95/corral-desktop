import AppKit
import XCTest
@testable import CorralUI

/// Legacy `.chr-dialog` cards (chrome.css §4.3/§4.4). Golden captures: `20-close-session-confirm.png`
/// (420 × 160.8pt) and `pair-02-newagent-old.png` (420 × 393pt), laid out on WebKit's 1.4em line boxes.
@MainActor
final class GoldenDialogBaselineTests: XCTestCase {
    func testCloseAgentIsACompactCardWithMutedWarningAndSolidDangerButton() throws {
        let dialog = CloseAgentDialogViewController(agentName: "fixture-split-right")
        let window = present(dialog)
        defer { window.close() }
        let card = dialog.view

        XCTAssertEqual(card.frame.width, 420, accuracy: 0.5)
        // 20 + 21 title + 2 + 16.8 subtitle + 14 + 17.4 warning + 18 + 32.2 actions + 20.
        XCTAssertEqual(card.frame.height, 161.4, accuracy: 1, "The card must hug its rows instead of leaving a vertical void")
        XCTAssertEqual(card.layer?.cornerRadius ?? 0, 14, accuracy: 0.1)

        let warning = try XCTUnwrap(descendants(of: card).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("这会终止") })
        XCTAssertEqual(foreground(of: warning), CorralAestheticTokens.textSecondary, "The warning is secondary body text, not a pink alert")
        XCTAssertEqual(warning.alignmentRect(forFrame: rect(of: warning, in: card)).minX, 20, accuracy: 0.5)

        let cancel = try button("取消", in: card), confirm = try button("关闭 Agent", in: card)
        for button in [cancel, confirm] {
            XCTAssertEqual(button.frame.height, 32.2, accuracy: 0.5, "`.chr-btn` is 7pt padding around a 13pt line")
        }
        let confirmRect = rect(of: confirm, in: card), cancelRect = rect(of: cancel, in: card)
        XCTAssertEqual(card.frame.width - confirmRect.maxX, 20, accuracy: 0.5)
        XCTAssertEqual(confirmRect.minY, 20, accuracy: 0.5)
        XCTAssertEqual(confirmRect.minX - cancelRect.maxX, 8, accuracy: 0.5)
        XCTAssertEqual(confirmRect.midY, cancelRect.midY, accuracy: 0.25)

        let fill = try XCTUnwrap(pixel(of: confirm, at: CGPoint(x: 4, y: confirm.bounds.midY)))
        XCTAssertTrue(matches(fill, CorralAestheticTokens.dangerFill), "关闭 Agent is a solid red rounded rect, got \(fill)")
        let plain = try XCTUnwrap(pixel(of: cancel, at: CGPoint(x: 4, y: cancel.bounds.midY)))
        XCTAssertEqual(plain.alphaComponent, 0, accuracy: 0.01, "取消 is a borderless `.chr-btn` until hovered")
        let enter = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        cancel.mouseEntered(with: enter)
        let hovered = try XCTUnwrap(pixel(of: cancel, at: CGPoint(x: 4, y: cancel.bounds.midY)))
        XCTAssertGreaterThan(hovered.alphaComponent, 0.05, "Hover paints the `--hover-4` fill")
    }

    func testNewAgentIsTheLegacyFourColumnCardWithCSSRhythm() throws {
        let launchers = [
            CorralAgentLauncher(provider: "pi", displayName: "Pi Coding Agent", supportsBypass: false),
            CorralAgentLauncher(provider: "codex", displayName: "Codex CLI", supportsBypass: true),
            CorralAgentLauncher(provider: "cursor", displayName: "Cursor Agent", supportsBypass: false),
            CorralAgentLauncher(provider: "grok", displayName: "Grok", supportsBypass: false)
        ]
        let dialog = NewAgentDialogViewController(spaceName: "corral-gw-test-home", launchers: launchers)
        let window = present(dialog)
        defer { window.close() }
        let card = dialog.view

        XCTAssertFalse(window.isKeyWindow, "The offscreen dialog must never take keyboard focus")
        XCTAssertEqual(card.frame.width, 420, accuracy: 0.5)
        // 20 + 21 + 2 + 16.8 + 14 + 16.1 + 6 + 36.2 + 14 + 16.1 + 8 + 58.7 + 14 + 53.9 + 16 + 16.1 + 12 + 32.2 + 20.
        XCTAssertEqual(card.frame.height, 393.1, accuracy: 1)

        let tiles = descendants(of: card).compactMap { $0 as? NSButton }.filter { launchers.map(\.provider).contains($0.identifier?.rawValue ?? "") }
        XCTAssertEqual(tiles.count, 4)
        let tileRects = tiles.map { $0.alignmentRect(forFrame: rect(of: $0, in: card)) }.sorted { $0.minX < $1.minX }
        XCTAssertEqual(Set(tileRects.map { ($0.minY * 2).rounded() }).count, 1, "All four providers share one grid row")
        XCTAssertEqual(tileRects.first?.minX ?? 0, 20, accuracy: 0.5)
        XCTAssertEqual(tileRects.last?.maxX ?? 0, 400, accuracy: 0.5)
        for (index, tile) in tileRects.enumerated() {
            XCTAssertEqual(tile.width, 89, accuracy: 0.5); XCTAssertEqual(tile.height, 58.7, accuracy: 0.5)
            if index > 0 { XCTAssertEqual(tile.minX - tileRects[index - 1].maxX, 8, accuracy: 0.5) }
        }
        for tile in tiles {
            let icon = try XCTUnwrap(tile.cell).imageRect(forBounds: tile.bounds)
            XCTAssertNotNil(tile.image, "\(tile.title) must show its provider mark")
            XCTAssertEqual(icon.size, NSSize(width: 20, height: 20))
            XCTAssertTrue(tile.bounds.contains(icon), "\(tile.title) icon must not be clipped")
            XCTAssertEqual(icon.midX, tile.bounds.midX, accuracy: 0.25)
        }
        XCTAssertEqual(tiles.first { $0.identifier?.rawValue == "pi" }?.state, .on, "The first advertised launcher is preselected")

        let field = dialog.nameField
        let box = try XCTUnwrap(field.superview)
        XCTAssertEqual(box.alignmentRect(forFrame: box.frame).height, 36.2, accuracy: 0.5)
        XCTAssertEqual(box.alignmentRect(forFrame: rect(of: box, in: card)).width, 380, accuracy: 0.5)
        XCTAssertEqual(field.placeholderAttributedString?.string, "任务名称")

        let cancel = try XCTUnwrap(dialog.cancelButton), create = try XCTUnwrap(dialog.createButton)
        let createRect = rect(of: create, in: card), cancelRect = rect(of: cancel, in: card)
        XCTAssertEqual(createRect.height, 32.2, accuracy: 0.5)
        XCTAssertEqual(card.frame.width - createRect.maxX, 20, accuracy: 0.5)
        XCTAssertEqual(createRect.minY, 20, accuracy: 0.5)
        XCTAssertEqual(createRect.minX - cancelRect.maxX, 8, accuracy: 0.5)
        XCTAssertEqual(createRect.midY, cancelRect.midY, accuracy: 0.25)
        XCTAssertFalse(create.isEnabled, "创建 waits for a task name")

        // `.nad-error` grows the card instead of overlapping the provider grid.
        let height = card.frame.height
        field.stringValue = String(repeating: "a", count: 65)
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(dialog.validationMessage, "名称不能超过 64 个字符")
        XCTAssertEqual(card.frame.height - height, 17.4, accuracy: 1)
    }

    private func present(_ dialog: CorralDialogViewController) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        window.orderBack(nil)
        dialog.present(over: window)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func button(_ title: String, in root: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(of: root).compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    private func rect(of view: NSView, in root: NSView) -> NSRect { root.convert(view.bounds, from: view) }

    private func foreground(of label: NSTextField) -> NSColor? {
        label.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    private func pixel(of view: NSView, at point: CGPoint) -> NSColor? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        // The cached bitmap holds display-space samples; tag them with that space before converting.
        guard let raw = rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale)) else { return nil }
        var components = [raw.redComponent, raw.greenComponent, raw.blueComponent, raw.alphaComponent]
        return NSColor(colorSpace: rep.colorSpace, components: &components, count: 4).usingColorSpace(.sRGB)
    }

    private func matches(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let lhs = lhs.usingColorSpace(.sRGB), let rhs = rhs.usingColorSpace(.sRGB) else { return false }
        return abs(lhs.redComponent - rhs.redComponent) < 0.02 && abs(lhs.greenComponent - rhs.greenComponent) < 0.02 && abs(lhs.blueComponent - rhs.blueComponent) < 0.02
    }

    private func descendants(of view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants(of: $0) } }
}
