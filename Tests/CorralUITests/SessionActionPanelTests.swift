import AppKit
import XCTest
@testable import CorralUI

@MainActor
final class SessionActionPanelTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    func testEveryIndependentPanelFitsSmallWindowAndHasExplicitControls() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        for action in [CorralActionID.history, .fork, .newSession, .clone, .compact, .export] {
            let panel = CorralSessionActionPanel(action: action, sessionTitle: "Native")
            panel.present(over: window)
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(panel.view.frame.width, 448)
            XCTAssertLessThanOrEqual(panel.view.frame.height, 328)
            for id in ["corral.action.submit", "corral.action.cancel", "corral.action.status"] {
                let control = try XCTUnwrap(descendants(panel.view).first { $0.accessibilityIdentifier() == id })
                XCTAssertTrue(panel.view.bounds.insetBy(dx: -1, dy: -1).contains(control.convert(control.bounds, to: panel.view)), "\(action): clipped \(id)")
            }
            panel.handleEscape()
            XCTAssertNil(panel.presentedWindow)
        }
    }

    func testSelectingCurrentRowIsRejectedAndBusyMutationCannotDismiss() {
        let panel = CorralSessionActionPanel(action: .history, sessionTitle: "Session")
        panel.setChoices([.init(id: "a", title: "A", detail: "now", current: true), .init(id: "b", title: "B", detail: "past")])
        XCTAssertFalse(panel.selectChoice("a")); XCTAssertTrue(panel.selectChoice("b"))
        panel.setStatus("停止任务？", requiresForce: true)
        XCTAssertTrue(panel.requiresForce)
        panel.setStatus("处理中", busy: true, allowsClose: false)
        var closed = false; panel.onClose = { closed = true }
        panel.handleEscape()
        XCTAssertFalse(closed)
        XCTAssertFalse(panel.selectChoice("b"))
        panel.setStatus("完成", completed: true)
        panel.handleEscape(); XCTAssertTrue(closed)
    }

    func testInlineRenameUsesRealHeaderFieldAndEscapeCancelsWithoutSubmission() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let header = CorralViewportHeaderView(frame: NSRect(x: 0, y: 0, width: 640, height: 40))
        window.contentView?.addSubview(header)
        let previous = NSTextView(frame: NSRect(x: 0, y: 40, width: 300, height: 40))
        window.contentView?.addSubview(previous); window.makeFirstResponder(previous)
        header.apply(.init(title: "Native", phase: .ready, canSwitch: true, hasActions: true))
        var submitted: [String] = []
        header.onRenameSubmit = { submitted.append($0) }
        header.beginRename("Native")
        XCTAssertTrue(header.isRenaming)
        XCTAssertGreaterThan(header.renameField.frame.width, 100)
        header.renameField.stringValue = "New name"
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(header.renameField.action), to: header.renameField.target, from: header.renameField))
        XCTAssertEqual(submitted, ["New name"])
        header.setRenamePending(true)
        XCTAssertFalse(header.renameField.isEnabled)
        header.setRenamePending(false)
        let editor = try XCTUnwrap(header.renameField.currentEditor() as? NSTextView ?? window.fieldEditor(true, for: header.renameField) as? NSTextView)
        XCTAssertTrue(header.control(header.renameField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(header.isRenaming)
        XCTAssertTrue(window.firstResponder === previous)
        XCTAssertEqual(submitted, ["New name"])
    }
}
