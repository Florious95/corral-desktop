import AppKit
import CorralMetalTerminal
import CorralUI
import XCTest
@preconcurrency import SwiftTerm
@testable import CorralApp

@MainActor
final class CorralNativeTerminalPasteTests: XCTestCase {
    func testFontPreferencesResolveIndividualFamiliesAtTheRequestedPointSize() throws {
        let view = CorralNativeTerminalView(frame: .zero)
        view.setTerminalFont(family: "'Missing Fixture Font', \"Menlo\", monospace", size: 15)
        XCTAssertEqual(view.font.familyName, "Menlo")
        XCTAssertEqual(view.font.pointSize, 15)
    }

    func testTerminalAcceptsFirstMouseForBackgroundWindowClicks() {
        let view = CorralNativeTerminalView(frame: .zero)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testDarkTerminalDefaultsRemainReadableWithDarkANSIWhites() {
        let view = CorralNativeTerminalView(frame: .zero)
        let terminal = view.getTerminal()
        let rgb8: (SwiftTerm.Color) -> [UInt8] = { color in
            [UInt8(color.red / 257), UInt8(color.green / 257), UInt8(color.blue / 257)]
        }
        XCTAssertEqual(rgb8(terminal.foregroundColor), [213, 220, 230])
        XCTAssertEqual(rgb8(terminal.backgroundColor), [16, 17, 21])
        XCTAssertEqual(rgb8(CorralTerminalPalette.darkANSI16[7]), [40, 47, 57])
        XCTAssertEqual(rgb8(CorralTerminalPalette.darkANSI16[15]), [40, 47, 57])

        func luminance(_ color: [UInt8]) -> Double {
            let channels = color.map { component -> Double in
                let value = Double(component) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        }
        let contrast = (luminance(rgb8(terminal.foregroundColor)) + 0.05) / (luminance(rgb8(terminal.backgroundColor)) + 0.05)
        XCTAssertGreaterThan(contrast, 4.5)
    }

    func testSnapshotFilterRemapsOnlyTheExactTrueColorBackground() throws {
        let view = CorralNativeTerminalView(frame: .zero)
        view.replaceSnapshot(Data("\u{1b}[38;2;244;244;240m\u{1b}[48;2;244;244;240mX".utf8))

        let cell = try XCTUnwrap(view.getTerminal().getLine(row: 0)?.getData().first)
        XCTAssertEqual(cell.attribute.fg, .trueColor(red: 244, green: 244, blue: 240))
        XCTAssertEqual(cell.attribute.bg, .trueColor(red: 40, green: 47, blue: 57))

        let nearMatch = CorralNativeTerminalView(frame: .zero)
        nearMatch.replaceSnapshot(Data("\u{1b}[48;2;245;244;240mY".utf8))
        let nearMatchCell = try XCTUnwrap(nearMatch.getTerminal().getLine(row: 0)?.getData().first)
        XCTAssertEqual(nearMatchCell.attribute.bg, .trueColor(red: 245, green: 244, blue: 240))
    }

    func testDeltaFilterRemapsBackgroundTokenSplitAcrossFrames() throws {
        let view = CorralNativeTerminalView(frame: .zero)
        view.feedRemoteANSI(Array("\u{1b}[48;2;244;244;".utf8)[...])
        view.feedRemoteANSI(Array("240mX".utf8)[...])

        let cell = try XCTUnwrap(view.getTerminal().getLine(row: 0)?.getData().first)
        XCTAssertEqual(cell.attribute.bg, .trueColor(red: 40, green: 47, blue: 57))
    }

    func testControlVUsesTheWindowResponderPathWithoutAnApplicationMonitor() throws {
        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("keyboard paste", forType: .string)
        let sink = PasteCapture()
        let view = CorralNativeTerminalView(frame: .zero, pasteboard: pasteboard)
        view.terminalDelegate = sink
        let window = makeBackgroundWindow(containing: view)
        defer { closeAndDrain(window) }
        window.sendEvent(keyEvent(modifiers: .control, windowNumber: window.windowNumber))
        XCTAssertEqual(sink.payloads, [Data("keyboard paste".utf8)])
    }

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

    func testWindowDeliveredControlVPastesImageThroughTheFocusedResponder() throws {
        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(samplePNG(), forType: .png)

        let sink = PasteCapture()
        let view = CorralNativeTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), pasteboard: pasteboard)
        view.terminalDelegate = sink
        let window = makeBackgroundWindow(containing: view)
        defer { closeAndDrain(window) }
        XCTAssertTrue(window.firstResponder === view)

        window.sendEvent(keyEvent(modifiers: .control, windowNumber: window.windowNumber))

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
        let window = CorralWindow(contentRect: view.frame)
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
