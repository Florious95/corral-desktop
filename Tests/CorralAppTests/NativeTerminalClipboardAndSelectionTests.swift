import AppKit
import CorralMetalTerminal
import CorralUI
import XCTest
@preconcurrency @testable import SwiftTerm
@testable import CorralApp

@MainActor
final class NativeTerminalClipboardAndSelectionTests: XCTestCase {
    func testCmdVPastesPlainText() throws {
        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        let text = "clipboard text · 中文"
        pasteboard.setString(text, forType: .string)
        let (_, window, capture) = makeTerminal(pasteboard: pasteboard)
        defer { closeAndDrain(window) }

        window.sendEvent(keyEvent("v", keyCode: 9, windowNumber: window.windowNumber))

        XCTAssertEqual(capture.payloads, [Data(text.utf8)])
    }

    func testCmdVPastesImageAsSavedTempFilePath() throws {
        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        let png = samplePNG()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        let image = try XCTUnwrap(NSImage(data: png))
        let (view, window, capture) = makeTerminal(pasteboard: pasteboard)
        defer { closeAndDrain(window) }

        pasteboard.setData(png, forType: .png)
        assertImagePasteReachedFile(pasteboard: pasteboard, window: window, capture: capture, view: view)
        pasteboard.clearContents()
        pasteboard.setData(try XCTUnwrap(bitmap.tiffRepresentation), forType: .tiff)
        assertImagePasteReachedFile(pasteboard: pasteboard, window: window, capture: capture, view: view)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([image]))
        assertImagePasteReachedFile(pasteboard: pasteboard, window: window, capture: capture, view: view)
    }

    func testCmdVPastesCopiedFilesAsAbsolutePOSIXPath() throws {
        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral clipboard files \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("source code.txt")
        try Data("clipboard file fixture".utf8).write(to: fileURL)
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))

        let (_, window, capture) = makeTerminal(pasteboard: pasteboard)
        defer { closeAndDrain(window) }
        window.sendEvent(keyEvent("v", keyCode: 9, windowNumber: window.windowNumber))

        XCTAssertEqual(capture.payloads, [Data("'\(fileURL.standardizedFileURL.path)'".utf8)])
        XCTAssertTrue(fileURL.standardizedFileURL.path.hasPrefix("/"))
        XCTAssertTrue(String(decoding: capture.payloads[0], as: UTF8.self).contains(" "))
    }

    func testMouseDragSelectsTerminalTextAndCmdCCopiesToPasteboard() throws {
        let systemPasteboard = NSPasteboard.general
        let savedPasteboard = PasteboardSnapshot(systemPasteboard)
        defer { savedPasteboard.restore(to: systemPasteboard) }
        systemPasteboard.clearContents()

        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        let (view, window, _) = makeTerminal(pasteboard: pasteboard)
        defer { closeAndDrain(window) }
        let text = "COPY_TARGET rest"
        view.getTerminal().feed(text: text)
        XCTAssertEqual(view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true), text)
        window.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.firstResponder === view)

        let cell = try XCTUnwrap(view.cellDimension)
        XCTAssertGreaterThan(cell.width, 0)
        XCTAssertGreaterThan(cell.height, 0)
        let start = CGPoint(x: cell.width * 0.5, y: view.bounds.height - cell.height * 0.5)
        let end = CGPoint(x: cell.width * 11.5, y: view.bounds.height - cell.height * 0.5)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: start, in: view, window: window, timestamp: 1))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: start, in: view, window: window, timestamp: 1.05))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: end, in: view, window: window, timestamp: 1.1))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: end, in: view, window: window, timestamp: 1.2))

        let selectedText = view.selection.getSelectedText()
        XCTAssertTrue(view.selection.active, "A left-button drag must create an active terminal selection")
        XCTAssertNotEqual(view.selection.start, view.selection.end, "Drag range collapsed: start=\(view.selection.start) end=\(view.selection.end), cell=\(cell)")
        XCTAssertTrue(selectedText.contains("COPY_TARGET"), "Selection should contain the dragged terminal text; got \(String(reflecting: selectedText))")
        let commandC = keyEvent("c", keyCode: 8, windowNumber: window.windowNumber)
        let handled = view.performKeyEquivalent(with: commandC)
        XCTAssertTrue(handled, "The terminal must handle Command+C without relying on a main-menu Edit item")
        XCTAssertEqual(systemPasteboard.string(forType: .string), selectedText, "Command+C must copy the active terminal selection")
    }

    private func assertImagePasteReachedFile(
        pasteboard: NSPasteboard,
        window: NSWindow,
        capture: ClipboardInputCapture,
        view: CorralNativeTerminalView
    ) {
        let payloadCount = capture.payloads.count
        window.sendEvent(keyEvent("v", keyCode: 9, windowNumber: window.windowNumber))
        guard let payload = capture.payloads.dropFirst(payloadCount).last,
              let quotedPath = String(data: payload, encoding: .utf8),
              quotedPath.first == "'", quotedPath.last == "'" else {
            XCTFail("Command+V must send the quoted path of a saved image")
            return
        }
        let path = String(quotedPath.dropFirst().dropLast())
        let url = URL(fileURLWithPath: path).standardizedFileURL
        defer { try? FileManager.default.removeItem(at: url) }
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL.path
        XCTAssertTrue(url.path.hasPrefix("\(temporaryDirectory)/corral-clipboard-"))
        XCTAssertEqual(url.pathExtension, "png")
        let data = try? Data(contentsOf: url)
        XCTAssertNotNil(data)
        XCTAssertNotNil(data.flatMap(NSBitmapImageRep.init(data:)))
    }

    private func isolatedPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.corral.clipboard-selection.\(UUID().uuidString)"))
    }

    private func makeTerminal(pasteboard: NSPasteboard) -> (CorralNativeTerminalView, NSWindow, ClipboardInputCapture) {
        _ = NSApplication.shared
        let view = CorralNativeTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), pasteboard: pasteboard)
        let capture = ClipboardInputCapture()
        view.terminalDelegate = capture
        let window = CorralWindow(contentRect: view.frame)
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        _ = window.makeFirstResponder(view)
        window.contentView?.layoutSubtreeIfNeeded()
        return (view, window, capture)
    }

    private func keyEvent(_ character: String, keyCode: UInt16, windowNumber: Int) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        in view: NSView,
        window: NSWindow,
        timestamp: TimeInterval
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: view.convert(point, to: nil),
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func closeAndDrain(_ window: NSWindow) {
        let wasVisible = window.isVisible
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        if wasVisible { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private func samplePNG() -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        return bitmap.representation(using: .png, properties: [:])!
    }
}

@MainActor
private final class ClipboardInputCapture: NSObject, @preconcurrency TerminalViewDelegate {
    private(set) var payloads: [Data] = []

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { payloads.append(Data(data)) }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

private struct PasteboardSnapshot {
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }.filter { !$0.isEmpty }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        if !restoredItems.isEmpty { pasteboard.writeObjects(restoredItems) }
    }
}
