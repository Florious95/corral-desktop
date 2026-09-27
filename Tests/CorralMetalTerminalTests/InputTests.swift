import AppKit
import CorralContracts
import CorralMetalTerminal
import XCTest

final class InputTests: XCTestCase {
    @MainActor
    func testMarkedTextTransitionsToCommittedUTF8Text() async {
        let router = RecordingInputRouter()
        let view = TerminalTextInputView(frame: .zero, sessionKey: sessionKey("ime"), inputRouting: router)

        view.setMarkedText(NSAttributedString(string: "にほん"), selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 3))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 0))
        XCTAssertEqual(view.attributedSubstring(forProposedRange: NSRange(location: 1, length: 2), actualRange: nil)?.string, "ほん")
        XCTAssertEqual(view.attributedSubstring(forProposedRange: NSRange(location: 100, length: 10), actualRange: nil)?.string, "")

        view.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
        let committed = await waitForInputs(router, count: 1)
        XCTAssertEqual(committed, [Data("日本".utf8)])
    }

    @MainActor
    func testCompositionEnterCannotSubmitCR() async {
        let router = RecordingInputRouter()
        let view = TerminalTextInputView(frame: .zero, sessionKey: sessionKey("ime"), inputRouting: router)
        view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

        let enter = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )!
        view.keyDown(with: enter)
        view.doCommand(by: NSSelectorFromString("insertNewline:"))
        for _ in 0..<20 { await Task.yield() }
        let beforeCommit = await router.inputs()
        XCTAssertTrue(beforeCommit.isEmpty)
        XCTAssertTrue(view.hasMarkedText())

        view.insertText("仮名", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.keyDown(with: enter)
        let committedAndSubmitted = await waitForInputs(router, count: 2)
        XCTAssertEqual(committedAndSubmitted, [Data("仮名".utf8), Data("\r".utf8)])
    }

    @MainActor
    func testControlVPastesClipboardImageAsTemporaryPNGPath() async throws {
        let pasteboard = makeIsolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(samplePNG(), forType: .png)

        let router = RecordingInputRouter()
        let view = TerminalTextInputView(frame: .zero, sessionKey: sessionKey("image-paste"), inputRouting: router, pasteboard: pasteboard)
        view.keyDown(with: keyEvent(9, modifiers: .control, characters: "v"))
        let inputs = await waitForInputs(router, count: 1)
        let pasted = try XCTUnwrap(inputs.first.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(pasted.hasPrefix("'") && pasted.hasSuffix("'"))
        let path = String(pasted.dropFirst().dropLast())
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertTrue(path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertTrue(URL(fileURLWithPath: path).lastPathComponent.hasPrefix("corral-clipboard-"))
        XCTAssertNotNil(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))))
    }

    @MainActor
    func testCommandVPastesQuotedFileURLPath() async throws {
        let pasteboard = makeIsolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let path = "/tmp/Agent's folder/code file.swift"
        let secondPath = "/tmp/second input.txt"
        pasteboard.writeObjects([NSURL(fileURLWithPath: path), NSURL(fileURLWithPath: secondPath)])

        let router = RecordingInputRouter()
        let view = TerminalTextInputView(frame: .zero, sessionKey: sessionKey("file-paste"), inputRouting: router, pasteboard: pasteboard)
        view.keyDown(with: keyEvent(9, modifiers: .command, characters: "v"))
        let inputs = await waitForInputs(router, count: 1)

        XCTAssertEqual(inputs.first.flatMap { String(data: $0, encoding: .utf8) }, "'/tmp/Agent'\\''s folder/code file.swift' '/tmp/second input.txt'")
    }

    @MainActor
    func testCommandVFallsBackToPlainText() async {
        let pasteboard = makeIsolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("ordinary clipboard text", forType: .string)

        let router = RecordingInputRouter()
        let view = TerminalTextInputView(frame: .zero, sessionKey: sessionKey("text-paste"), inputRouting: router, pasteboard: pasteboard)
        view.keyDown(with: keyEvent(9, modifiers: .command, characters: "v"))

        let inputs = await waitForInputs(router, count: 1)
        XCTAssertEqual(inputs.first, Data("ordinary clipboard text".utf8))
    }

    @MainActor
    func testControlVFallsBackToPlainTextWhenClipboardHasNoImage() async {
        let pasteboard = makeIsolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("ordinary clipboard text", forType: .string)

        let router = RecordingInputRouter()
        let view = TerminalTextInputView(frame: .zero, sessionKey: sessionKey("control-v-text"), inputRouting: router, pasteboard: pasteboard)
        view.keyDown(with: keyEvent(9, modifiers: .control, characters: "v"))

        let inputs = await waitForInputs(router, count: 1)
        XCTAssertEqual(inputs.first, Data("ordinary clipboard text".utf8))
    }

    @MainActor
    func testControlAndNavigationKeysProduceTerminalBytes() async {
        let router = RecordingInputRouter()
        let view = TerminalTextInputView(frame: .zero, sessionKey: sessionKey("keys"), inputRouting: router)
        let character: (UInt32) -> String = { String(UnicodeScalar($0)!) }
        let keys: [(UInt16, NSEvent.ModifierFlags, String, [UInt8])] = [
            (8, .control, "c", [0x03]),
            (2, .control, "d", [0x04]),
            (6, .control, "z", [0x1a]),
            (48, [], character(9), [0x09]),
            (53, [], character(0x1b), [0x1b]),
            (126, [], character(0xf700), [0x1b, 0x5b, 0x41]),
            (125, [], character(0xf701), [0x1b, 0x5b, 0x42]),
            (124, [], character(0xf703), [0x1b, 0x5b, 0x43]),
            (123, [], character(0xf702), [0x1b, 0x5b, 0x44]),
            (115, [], character(0xf729), [0x1b, 0x5b, 0x48]),
            (119, [], character(0xf72b), [0x1b, 0x5b, 0x46]),
            (116, [], character(0xf72c), [0x1b, 0x5b, 0x35, 0x7e]),
            (121, [], character(0xf72d), [0x1b, 0x5b, 0x36, 0x7e]),
            (114, [], character(0xf727), [0x1b, 0x5b, 0x32, 0x7e]),
            (117, [], character(0xf728), [0x1b, 0x5b, 0x33, 0x7e]),
            (122, [], character(0xf704), [0x1b, 0x4f, 0x50]),
            (111, [], character(0xf70f), [0x1b, 0x5b, 0x32, 0x34, 0x7e]),
            (51, [], character(0x7f), [0x7f]),
            (36, [], character(0x0d), [0x0d])
        ]
        for (keyCode, modifiers, characters, _) in keys {
            view.keyDown(with: keyEvent(keyCode, modifiers: modifiers, characters: characters))
        }
        let inputs = await waitForInputs(router, count: keys.count)

        XCTAssertEqual(inputs, keys.map { Data($0.3) })
    }

    @MainActor
    func testUserTextRoutesInSubmissionOrder() async {
        let router = RecordingInputRouter()
        let view = TerminalTextInputView(frame: .zero, sessionKey: sessionKey("ordering"), inputRouting: router)
        view.insertText("あ", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("い", replacementRange: NSRange(location: NSNotFound, length: 0))

        let inputs = await waitForInputs(router, count: 2)
        XCTAssertEqual(inputs, [Data("あ".utf8), Data("い".utf8)])
    }

    @MainActor
    func testCandidateCaretAndCharacterIndexUseTerminalCellGeometry() {
        let view = TerminalTextInputView(frame: NSRect(x: 0, y: 0, width: 40, height: 60), sessionKey: sessionKey("geometry"), inputRouting: RecordingInputRouter())
        view.configure(grid: GridSize(rows: 3, columns: 4), cellSize: NSSize(width: 10, height: 20), cursor: CursorDescriptor(row: 1, column: 2))

        XCTAssertEqual(view.caretRectInView, NSRect(x: 20, y: 20, width: 10, height: 20))
        XCTAssertEqual(view.characterIndex(for: NSPoint(x: 25, y: 25)), 6)
        view.setSelection(TerminalCellSelection(anchor: TerminalCellPosition(row: 0, column: 1), focus: TerminalCellPosition(row: 1, column: 2)))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 6))
    }

    @MainActor
    func testMouseButtonAndDragUseAdapterBytesInInputFIFO() async {
        let router = RecordingInputRouter()
        let encoder = RecordingMouseEventEncoder(returnsBytes: true)
        let view = TerminalTextInputView(
            frame: NSRect(x: 0, y: 0, width: 40, height: 60),
            sessionKey: sessionKey("mouse"),
            inputRouting: router,
            mouseEventEncoder: encoder
        )
        view.configure(grid: GridSize(rows: 3, columns: 4), cellSize: NSSize(width: 10, height: 20), cursor: CursorDescriptor(row: 0, column: 0))
        XCTAssertEqual(view.terminalCell(atViewPoint: NSPoint(x: 25, y: 25)), TerminalCellPosition(row: 1, column: 2))
        XCTAssertNil(view.terminalCell(atViewPoint: NSPoint(x: 40, y: 25)))

        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 25, y: 25), in: view))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 25, y: 25), in: view))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 25, y: 25), in: view))

        let inputs = await waitForInputs(router, count: 3)
        XCTAssertEqual(inputs, [
            Data("\u{1b}[<0;3;2M".utf8),
            Data("\u{1b}[<32;3;2M".utf8),
            Data("\u{1b}[<0;3;2m".utf8)
        ])
        let calls = await waitForMouseCalls(encoder, count: 3)
        XCTAssertEqual(calls.map(\.phase), [.buttonDown, .drag, .buttonUp])
        XCTAssertTrue(calls.allSatisfy { $0.button == 0 && $0.column == 2 && $0.row == 1 })
    }

    @MainActor
    func testNilMouseEncodingFallsBackToTextSelection() async {
        let router = RecordingInputRouter()
        let encoder = RecordingMouseEventEncoder(returnsBytes: false)
        let view = TerminalTextInputView(
            frame: NSRect(x: 0, y: 0, width: 40, height: 60),
            sessionKey: sessionKey("selection-fallback"),
            inputRouting: router,
            mouseEventEncoder: encoder
        )
        view.configure(grid: GridSize(rows: 2, columns: 4), cellSize: NSSize(width: 10, height: 20), cursor: CursorDescriptor(row: 0, column: 0))
        view.updateTerminalSnapshot(makeSnapshot(rows: ["ABCD", "EFGH"]))

        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 5, y: 55), in: view))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 25, y: 25), in: view))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 25, y: 25), in: view))
        _ = await waitForMouseCalls(encoder, count: 3)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(view.selectedText(), "ABCD\nEFG")
        let routedInputs = await router.inputs()
        XCTAssertTrue(routedInputs.isEmpty)
    }

    @MainActor
    func testRectangularSelectionCopyAndHighlightGeometry() {
        let snapshot = makeSnapshot(rows: ["ABCD", "EFGH"])
        let selection = TerminalCellSelection(
            anchor: TerminalCellPosition(row: 0, column: 1),
            focus: TerminalCellPosition(row: 1, column: 2),
            mode: .rectangular
        )

        XCTAssertEqual(selection.selectedText(in: snapshot), "BC\nFG")
        XCTAssertEqual(
            selection.highlightRects(grid: snapshot.size, cellSize: NSSize(width: 10, height: 10), in: NSRect(x: 10, y: 20, width: 40, height: 20)),
            [NSRect(x: 20, y: 30, width: 20, height: 10), NSRect(x: 20, y: 20, width: 20, height: 10)]
        )
    }

    @MainActor
    func testCopySkipsWideCharacterContinuationCells() {
        let snapshot = TerminalGridSnapshot(
            size: GridSize(rows: 1, columns: 3),
            cells: [
                TerminalCell(content: .cluster("界", columns: .two), foreground: .indexed(7), background: .indexed(0)),
                TerminalCell(content: .continuation, foreground: .indexed(7), background: .indexed(0)),
                TerminalCell(content: .cluster("x", columns: .one), foreground: .indexed(7), background: .indexed(0))
            ],
            cursor: CursorDescriptor(row: 0, column: 0),
            generation: .initial
        )
        let selection = TerminalCellSelection(anchor: TerminalCellPosition(row: 0, column: 0), focus: TerminalCellPosition(row: 0, column: 2))

        XCTAssertEqual(selection.selectedText(in: snapshot), "界x")
    }

    @MainActor
    func testCopyPreservesExtendedGraphemeClusters() {
        let grapheme = "👩🏽‍💻"
        let snapshot = TerminalGridSnapshot(
            size: GridSize(rows: 1, columns: 2),
            cells: [
                TerminalCell(content: .cluster(grapheme, columns: .two), foreground: .indexed(7), background: .indexed(0)),
                TerminalCell(content: .continuation, foreground: .indexed(7), background: .indexed(0))
            ],
            cursor: CursorDescriptor(row: 0, column: 0),
            generation: .initial
        )
        let selection = TerminalCellSelection(anchor: TerminalCellPosition(row: 0, column: 0), focus: TerminalCellPosition(row: 0, column: 1))

        XCTAssertEqual(selection.selectedText(in: snapshot), grapheme)
    }

    @MainActor
    func testAccessibilitySnapshotIsBounded() {
        let view = TerminalTextInputView(frame: .zero, sessionKey: sessionKey("accessibility"), inputRouting: RecordingInputRouter())
        view.updateTerminalSnapshot(makeSnapshot(rows: ["ABCD", "EFGH"]), accessibilityCharacterLimit: 6)

        XCTAssertEqual(view.accessibilityLabel(), "Terminal")
        XCTAssertEqual(view.accessibilityValue() as? String, "ABCD\nE")

        view.updateTerminalSnapshot(makeSnapshot(rows: [String(repeating: "A", count: 5000)]), accessibilityCharacterLimit: 5000)
        XCTAssertEqual((view.accessibilityValue() as? String)?.unicodeScalars.count, 4096)
    }

    @MainActor
    private func makeIsolatedPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.corral.native-input-tests.\(UUID().uuidString)"))
    }

    @MainActor
    private func samplePNG() -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        bitmap.setColor(NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1), atX: 0, y: 0)
        return bitmap.representation(using: .png, properties: [:])!
    }

    @MainActor
    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: view.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    @MainActor
    private func keyEvent(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], characters: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func sessionKey(_ reference: String) -> SessionKey {
        SessionKey(deviceID: DeviceID("test-device"), reference: try! SessionReference(reference))
    }

    private func makeSnapshot(rows: [String]) -> TerminalGridSnapshot {
        let columns = rows.first?.count ?? 0
        let cells = rows.flatMap { row in
            row.map { character in
                TerminalCell(
                    content: .cluster(String(character), columns: .one),
                    foreground: .indexed(7),
                    background: .indexed(0)
                )
            }
        }
        return TerminalGridSnapshot(
            size: GridSize(rows: rows.count, columns: columns),
            cells: cells,
            cursor: CursorDescriptor(row: 0, column: 0),
            generation: .initial
        )
    }

    @MainActor
    private func waitForMouseCalls(_ encoder: RecordingMouseEventEncoder, count: Int) async -> [MouseEncoderCall] {
        for _ in 0..<200 {
            let calls = await encoder.calls()
            if calls.count >= count { return calls }
            await Task.yield()
        }
        return await encoder.calls()
    }

    @MainActor
    private func waitForInputs(_ router: RecordingInputRouter, count: Int) async -> [Data] {
        for _ in 0..<200 {
            let inputs = await router.inputs()
            if inputs.count >= count { return inputs }
            await Task.yield()
        }
        return await router.inputs()
    }
}

private struct MouseEncoderCall: Equatable, Sendable {
    let button: Int
    let column: Int
    let row: Int
    let phase: TerminalMouseEventPhase
    let modifiers: TerminalMouseModifiers
}

private actor RecordingMouseEventEncoder: TerminalMouseEventEncoding {
    private let returnsBytes: Bool
    private var recorded: [MouseEncoderCall] = []

    init(returnsBytes: Bool) { self.returnsBytes = returnsBytes }

    func encodeMouseEvent(button: Int, column: Int, row: Int, phase: TerminalMouseEventPhase, modifiers: TerminalMouseModifiers) async -> Data? {
        recorded.append(MouseEncoderCall(button: button, column: column, row: row, phase: phase, modifiers: modifiers))
        guard returnsBytes else { return nil }
        let code = phase == .drag ? button | 32 : button
        let suffix = phase == .buttonUp ? "m" : "M"
        return Data("\u{1b}[<\(code);\(column + 1);\(row + 1)\(suffix)".utf8)
    }

    func calls() -> [MouseEncoderCall] { recorded }
}

private actor RecordingInputRouter: TerminalInputRouting {
    private var recorded: [Data] = []

    func route(_ input: TerminalInput, to session: SessionKey) async throws -> UInt32 {
        guard case let .userBytes(bytes) = input else { return 0 }
        recorded.append(bytes.data)
        return UInt32(recorded.count)
    }

    func inputs() -> [Data] { recorded }
}
