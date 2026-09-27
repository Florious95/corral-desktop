import AppKit
import CorralMetalTerminal
import XCTest
@preconcurrency import SwiftTerm
@testable import CorralApp

@MainActor
final class CorralNativeTerminalPasteTests: XCTestCase {
    func testControlVPastesTextOrQuotedImagePathWithoutSendingControlV() throws {
        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        let sink = PasteCapture()
        let view = CorralNativeTerminalView(frame: .zero, pasteboard: pasteboard)
        view.terminalDelegate = sink

        pasteboard.setString("ordinary clipboard text", forType: .string)
        XCTAssertTrue(view.handleControlVPaste(event: keyEvent(modifiers: .control)))
        XCTAssertEqual(sink.payloads, [Data("ordinary clipboard text".utf8)])
        XCTAssertFalse(sink.payloads[0].contains(0x16))

        pasteboard.clearContents()
        pasteboard.setData(samplePNG(), forType: .png)
        XCTAssertTrue(view.handleControlVPaste(event: keyEvent(modifiers: .control)))
        let pastedPath = try XCTUnwrap(sink.payloads.last.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(pastedPath.hasPrefix("'") && pastedPath.hasSuffix("'"))
        let path = String(pastedPath.dropFirst().dropLast())
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertNotNil(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))))
    }

    func testCommandVPastesQuotedFilePathWithBracketedPasteMarkers() throws {
        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/Agent's folder/code file.swift")])

        let sink = PasteCapture()
        let view = CorralNativeTerminalView(frame: .zero, pasteboard: pasteboard)
        view.terminalDelegate = sink
        view.getTerminal().feed(text: "\u{1b}[?2004h")
        XCTAssertTrue(view.getTerminal().bracketedPasteMode)

        view.paste(view)

        XCTAssertEqual(
            sink.payloads,
            [Data("\u{1b}[200~'/tmp/Agent'\\''s folder/code file.swift'\u{1b}[201~".utf8)]
        )
    }

    func testCommandVKeyDownInvokesBracketedPasteActionWithoutHostInput() throws {
        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/Agent's folder/code file.swift")])

        let sink = PasteCapture()
        let view = CorralNativeTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), pasteboard: pasteboard)
        view.terminalDelegate = sink
        view.getTerminal().feed(text: "\u{1b}[?2004h")
        let window = makeBackgroundWindow(containing: view)
        defer { closeAndDrain(window) }
        XCTAssertTrue(window.firstResponder === view)

        view.keyDown(with: keyEvent(modifiers: .command, windowNumber: window.windowNumber))

        XCTAssertEqual(
            sink.payloads,
            [Data("\u{1b}[200~'/tmp/Agent'\\''s folder/code file.swift'\u{1b}[201~".utf8)]
        )
    }

    func testWindowDeliveredControlVUsesTheLocalPasteMonitor() throws {
        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(samplePNG(), forType: .png)

        let sink = PasteCapture()
        let view = CorralNativeTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), pasteboard: pasteboard)
        view.terminalDelegate = sink
        let window = makeBackgroundWindow(containing: view)
        defer { closeAndDrain(window) }
        XCTAssertTrue(window.firstResponder === view)

        NSApp.sendEvent(keyEvent(modifiers: .control, windowNumber: window.windowNumber))

        let payload = try XCTUnwrap(sink.payloads.first.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertFalse(payload.contains("\u{16}"), "the window-delivered Ctrl+V must not send the raw control byte")
        XCTAssertTrue(payload.hasPrefix("'") && payload.hasSuffix("'"))
        let imagePath = String(payload.dropFirst().dropLast())
        defer { try? FileManager.default.removeItem(atPath: imagePath) }
        XCTAssertNotNil(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: imagePath))))
    }

    func testWindowDeliveredCommandVUsesThePasteActionAndBracketedMarkers() throws {
        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/Agent's folder/code file.swift")])

        let sink = PasteCapture()
        let view = CorralNativeTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), pasteboard: pasteboard)
        view.terminalDelegate = sink
        view.getTerminal().feed(text: "\u{1b}[?2004h")
        let window = makeBackgroundWindow(containing: view)
        defer { closeAndDrain(window) }
        XCTAssertTrue(window.firstResponder === view)

        window.sendEvent(keyEvent(modifiers: .command, windowNumber: window.windowNumber))

        XCTAssertEqual(
            sink.payloads,
            [Data("\u{1b}[200~'/tmp/Agent'\\''s folder/code file.swift'\u{1b}[201~".utf8)]
        )
    }

    private func isolatedPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.corral.native-paste-tests.\(UUID().uuidString)"))
    }

    private func makeBackgroundWindow(containing view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        _ = window.makeFirstResponder(view)
        return window
    }

    private func closeAndDrain(_ window: NSWindow) {
        let wasVisible = window.isVisible
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        if wasVisible {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func keyEvent(modifiers: NSEvent.ModifierFlags, windowNumber: Int = 0) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        )!
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
private final class PasteCapture: NSObject, @preconcurrency TerminalViewDelegate {
    private(set) var payloads: [Data] = []

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { payloads.append(Data(data)) }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
