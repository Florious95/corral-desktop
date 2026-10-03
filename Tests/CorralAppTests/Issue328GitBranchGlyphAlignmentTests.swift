import AppKit
@testable import CorralApp
import CorralServices
@testable import SwiftTerm
import XCTest

/// Issue #328 on the shipped terminal view: Pi's footer `$0.00 +4 -0  main` must draw U+F418 as a
/// real branch glyph whose ink is vertically centred on the neighbouring digits.
@MainActor
final class Issue328GitBranchGlyphAlignmentTests: XCTestCase {
    private static let footer = "$0.00 +4 -0 \u{F418} main"
    private static let glyphColumn = 12
    nonisolated private static let digitColumns = [1, 3, 4, 10]

    func testBranchGlyphIsCentredOnDigitsInTheUsersAndDefaultFonts() throws {
        for (family, size, dark) in [("JetBrains Mono, \"Andale Mono\", Menlo, \"Lucida Console\"", 14, false),
                                     (UserPreferences.defaultFontFamily, 13, true),
                                     ("No Such Font", 13, true)] { // falls back to the system monospaced font
            let row = try render(family: family, size: size, dark: dark)
            let glyph = try XCTUnwrap(row.ink(column: Self.glyphColumn), "U+F418 drew no ink in \(row.fontName)")
            // The ink must be the bundled branch outline, not LastResort's wider, taller [?] box.
            let expected = try bundledGlyphInkPixels(size: size, scale: row.scale)
            XCTAssertEqual(glyph.height, expected.height, accuracy: 2, "\(row.fontName): U+F418 ink \(glyph) is not the bundled branch glyph")
            XCTAssertEqual(glyph.width, expected.width, accuracy: 2, "\(row.fontName): U+F418 ink \(glyph) is not the bundled branch glyph")
            XCTAssertEqual(glyph.centerY, row.digit.centerY, accuracy: 0.5,
                           "\(row.fontName) \(size)pt: U+F418 ink \(glyph) must share the digits' centre \(row.digit) within half a device pixel")
        }
    }

    func testBranchGlyphComesFromTheBundledSymbolFontNotLastResort() throws {
        let view = makeView(family: "JetBrains Mono, \"Andale Mono\", Menlo", size: 14)
        let font = CTFontCreateForString(view.font as CTFont, "\u{F418}" as CFString, CFRange(location: 0, length: 1))
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, "CorralTerminalGitBranchSymbols-Regular")
    }

    /// The instrument must see a real offset: Andale Mono's `-` sits ~2 device pixels below its digit centre.
    func testInstrumentResolvesSubPointVerticalOffsets() throws {
        let row = try render(family: "\"Andale Mono\"", size: 14, dark: false)
        let hyphen = try XCTUnwrap(row.ink(column: 9))
        XCTAssertGreaterThan(row.digit.centerY - hyphen.centerY, -3)
        XCTAssertGreaterThan(abs(row.digit.centerY - hyphen.centerY), 1.5, "Control: digit \(row.digit) vs hyphen \(hyphen)")
        for column in Self.digitColumns {
            XCTAssertEqual(try XCTUnwrap(row.ink(column: column)).centerY, row.digit.centerY, accuracy: 0.01)
        }
    }

    // MARK: - Real-view raster

    private struct Ink: CustomStringConvertible {
        var top: Int, bottom: Int, left: Int, right: Int // device pixels from the top-left, inclusive
        var height: Double { Double(bottom - top + 1) }
        var width: Double { Double(right - left + 1) }
        var centerY: Double { Double(top + bottom) / 2 }
        var description: String { "x=\(left)...\(right) y=\(top)...\(bottom)" }
    }

    private func bundledGlyphInkPixels(size: Int, scale: Double) throws -> (width: Double, height: Double) {
        let font = CTFontCreateWithName("CorralTerminalGitBranchSymbols-Regular" as CFString, CGFloat(size), nil)
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, "CorralTerminalGitBranchSymbols-Regular")
        var character: UniChar = 0xF418, glyph: CGGlyph = 0
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &bounds, 1)
        return (bounds.width * scale, bounds.height * scale)
    }

    private struct Row {
        let bitmap: NSBitmapImageRep // cacheDisplay of one row: glyph coverage over a transparent background
        let cellWidthPixels: Double
        let scale: Double
        let fontName: String
        var digit: Ink { ink(column: Issue328GitBranchGlyphAlignmentTests.digitColumns[0])! }

        /// Ink is any pixel with at least 40% glyph coverage inside the cell's columns.
        func ink(column: Int) -> Ink? {
            let minX = Int((Double(column) * cellWidthPixels).rounded(.down)) + 1
            let maxX = Int((Double(column + 1) * cellWidthPixels).rounded(.up)) - 2
            var top: Int?, bottom: Int?, left = Int.max, right = Int.min
            for y in 0..<bitmap.pixelsHigh {
                for x in minX...maxX where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.4 {
                    top = top ?? y; bottom = y; left = min(left, x); right = max(right, x)
                }
            }
            guard let top, let bottom else { return nil }
            return Ink(top: top, bottom: bottom, left: left, right: right)
        }
    }

    private var window: NSWindow?

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    private func makeView(family: String, size: Int) -> CorralNativeTerminalView {
        let view = CorralNativeTerminalView(frame: CGRect(x: 0, y: 0, width: 520, height: 120),
                                            pasteboard: NSPasteboard(name: NSPasteboard.Name(UUID().uuidString)))
        view.setTerminalFont(family: family, size: size)
        return view
    }

    private func render(family: String, size: Int, dark: Bool) throws -> Row {
        _ = NSApplication.shared
        let view = makeView(family: family, size: size)
        view.applyTerminalTheme(isDark: dark)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Below the desktop: composited by the WindowServer at the display's scale, never visible.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window
        view.replaceSnapshot(Data(Self.footer.utf8))
        view.needsDisplay = true
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let scale = window.backingScaleFactor
        let rowRect = NSRect(x: 0, y: view.bounds.height - view.cellDimension.height, width: view.bounds.width, height: view.cellDimension.height)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rowRect))
        view.cacheDisplay(in: rowRect, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["CORRAL_ISSUE328_EVIDENCE_DIR"] {
            let name = "\(view.font.fontName.trimmingCharacters(in: CharacterSet(charactersIn: ".")))-\(size)pt-\(dark ? "dark" : "light")"
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-row.png"))
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-l", "\(window.windowNumber)", "-o", "-x", "\(directory)/\(name)-window.png"]
            try capture.run(); capture.waitUntilExit()
        }
        return Row(bitmap: bitmap, cellWidthPixels: Double(view.cellDimension.width * CGFloat(bitmap.pixelsWide) / rowRect.width),
                   scale: Double(bitmap.pixelsWide) / rowRect.width, fontName: view.font.fontName + "@\(scale)x")
    }
}
