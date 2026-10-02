import AppKit
import CoreText
@testable import CorralApp
@testable import SwiftTerm
import XCTest

final class NativeTerminalSystemFontCascadeTests: XCTestCase {
    @MainActor
    func testSystemFontFallbackKeepsSymbolCascadeInEveryStyle() {
        let view = CorralNativeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.setTerminalFont(family: "corral-deliberately-unavailable-font", size: 15)
        let primary = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        XCTAssertEqual(view.font.fontName, primary.fontName)
        XCTAssertEqual(view.font.pointSize, primary.pointSize)
        XCTAssertEqual(view.font.maximumAdvancement, primary.maximumAdvancement)
        for style in ["0", "1", "3", "1;3"] {
            view.replaceSnapshot(Data("\u{1B}[\(style)m\u{1F5AB} \u{E0A0} A 中 ش".utf8))
            let terminal = view.getTerminal()
            let rendered = view.buildAttributedString(row: 0, line: terminal.getLine(row: 0)!, cols: terminal.cols)
            XCTAssertFalse(rendered.segments.isEmpty)
            var symbolFonts = Set<String>()
            for segment in rendered.segments {
                let line = CTLineCreateWithAttributedString(segment.attributedString as CFAttributedString)
                for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                    let resolved = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                    let name = CTFontCopyPostScriptName(resolved) as String
                    XCTAssertFalse(name.lowercased().contains("lastresort"), "SGR \(style) / \(segment.attributedString.string)")
                    var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                    XCTAssertFalse(glyphs.isEmpty)
                    XCTAssertTrue(glyphs.allSatisfy { $0 > 0 })
                    if name == "CorralTerminalSymbols-Regular" { symbolFonts.insert(name) }
                }
            }
            XCTAssertEqual(symbolFonts, ["CorralTerminalSymbols-Regular"])
        }
    }
}
