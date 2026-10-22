import AppKit
import XCTest
@testable import CorralUI

@MainActor
final class ConversationComposerTests: XCTestCase {
    private func mount() -> (NSWindow, CorralConversationPaneView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        let pane = CorralConversationPaneView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        window.contentView = pane
        pane.layoutSubtreeIfNeeded()
        pane.composer.apply(.init(ready: true, running: false))
        window.makeFirstResponder(pane.composer.editor)
        return (window, pane)
    }

    private func enter(_ window: NSWindow, shift: Bool = false, repeatKey: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                        isARepeat: repeatKey, keyCode: 36)!
    }

    func testReturnSendsShiftReturnInsertsNewlineAndRepeatDoesNotResend() {
        let (window, pane) = mount()
        let composer = pane.composer
        var submitted: [String] = []
        composer.onSubmit = { submitted.append(composer.draft) }
        composer.editor.insertText("第一行", replacementRange: NSRange(location: NSNotFound, length: 0))
        composer.editor.keyDown(with: enter(window, shift: true))
        composer.editor.insertText("second line", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(composer.draft, "第一行\nsecond line")
        XCTAssertTrue(submitted.isEmpty)
        composer.editor.keyDown(with: enter(window))
        composer.editor.keyDown(with: enter(window, repeatKey: true))
        XCTAssertEqual(submitted, ["第一行\nsecond line"])
    }

    func testMarkedTextNeverSendsAndStreamPresentationNeverReplacesComposition() {
        let (window, pane) = mount()
        let composer = pane.composer
        var sends = 0
        composer.onSubmit = { sends += 1 }
        composer.editor.setMarkedText("ni hao", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = composer.editor.markedRange()
        let selected = composer.editor.selectedRange()
        composer.apply(.init(ready: true, running: false))
        pane.apply(.init(title: "stream", phase: .ready, rows: [.init(id: "a", revision: 1, kind: .assistant, text: "chunk")]))
        XCTAssertTrue(composer.editor.hasMarkedText())
        XCTAssertEqual(composer.editor.markedRange(), marked)
        XCTAssertEqual(composer.editor.selectedRange(), selected)
        composer.actionButton.performClick(nil)
        XCTAssertEqual(sends, 0)
        composer.editor.keyDown(with: enter(window))
        XCTAssertEqual(sends, 0, "IME commit Return must not become send")
        composer.editor.setSelectedRange(NSRange(location: 0, length: (composer.draft as NSString).length))
        composer.editor.insertText("你好", replacementRange: NSRange(location: 0, length: (composer.draft as NSString).length))
        XCTAssertFalse(composer.editor.hasMarkedText())
        composer.editor.keyDown(with: enter(window))
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(composer.draft, "你好")
    }

    func testRunningEnterIsNotAbortAndStopButtonKeepsDraft() {
        let (window, pane) = mount()
        let composer = pane.composer
        var sends = 0, aborts = 0
        composer.onSubmit = { sends += 1 }; composer.onAbort = { aborts += 1 }
        composer.restoreDraft("next turn")
        composer.apply(.init(ready: true, running: true))
        XCTAssertEqual(composer.actionButton.accessibilityLabel(), "停止生成")
        composer.editor.keyDown(with: enter(window))
        XCTAssertEqual(sends, 0); XCTAssertEqual(aborts, 0)
        composer.actionButton.performClick(nil)
        XCTAssertEqual(aborts, 1); XCTAssertEqual(composer.draft, "next turn")
        composer.apply(.init(ready: true, running: true, stopping: true))
        composer.actionButton.performClick(nil)
        XCTAssertEqual(aborts, 1)
        composer.apply(.init(ready: true, running: false))
        XCTAssertEqual(composer.actionButton.accessibilityLabel(), "发送消息")
    }

    func testUnknownDisconnectedWhitespaceAndPendingInputsAreGated() {
        let (window, pane) = mount()
        let composer = pane.composer
        var sends = 0
        composer.onSubmit = { sends += 1 }
        for text in ["", " \n\t "] {
            composer.restoreDraft(text)
            XCTAssertFalse(composer.actionButton.isEnabled)
            composer.editor.keyDown(with: enter(window))
        }
        composer.restoreDraft("retained")
        for state in [CorralComposerState(), .init(ready: true, running: nil), .init(ready: true, running: false, sending: true)] {
            composer.apply(state)
            XCTAssertFalse(composer.actionButton.isEnabled)
            composer.editor.keyDown(with: enter(window))
            XCTAssertEqual(composer.draft, "retained")
        }
        XCTAssertEqual(sends, 0)
    }

    func testMultilineHeightIsBoundedAndTranscriptDoesNotOverlapComposer() {
        let (_, pane) = mount()
        let composer = pane.composer
        let emptyHeight = composer.preferredHeight
        composer.restoreDraft("one\ntwo\nthree\nfour")
        pane.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(composer.preferredHeight, emptyHeight)
        composer.restoreDraft(Array(repeating: "line", count: 60).joined(separator: "\n"))
        pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(composer.preferredHeight, 206)
        XCTAssertLessThanOrEqual(pane.transcript.frame.maxY, composer.frame.minY)
        XCTAssertGreaterThan(composer.editor.bounds.height, composer.scrollView.contentView.bounds.height)
        XCTAssertTrue(composer.bounds.contains(composer.actionButton.frame))
        composer.restoreDraft("")
        pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(composer.preferredHeight, emptyHeight)
    }

    func testNativeEditingReportsDraftAndStateUpdatesPreserveUndoSelection() {
        let (_, pane) = mount()
        let composer = pane.composer
        var edits: [String] = []
        composer.onDraftChange = { edits.append($0) }
        composer.editor.insertText("draft A", replacementRange: NSRange(location: NSNotFound, length: 0))
        composer.editor.setSelectedRange(NSRange(location: 2, length: 3))
        composer.apply(.init(ready: true, running: true))
        XCTAssertEqual(edits.last, "draft A")
        XCTAssertEqual(composer.editor.selectedRange(), NSRange(location: 2, length: 3))
        XCTAssertEqual(composer.draft, "draft A")
        XCTAssertTrue(composer.editor.undoManager?.canUndo == true)
    }
}
