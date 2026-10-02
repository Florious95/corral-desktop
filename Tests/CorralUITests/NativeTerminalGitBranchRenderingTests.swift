import AppKit
import CoreText
@testable import CorralApp
@testable import SwiftTerm
import XCTest

final class NativeTerminalGitBranchRenderingTests: XCTestCase {
    @MainActor
    func testActualRenderSegmentsKeepF418GlyphAcrossFontsAndStyles() {
        let view = CorralNativeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        for family in ["Menlo", "Monaco", "corral-deliberately-unavailable-font"] {
            view.setTerminalFont(family: family, size: 15)
            let primary = NSFont(name: family, size: 15) ?? NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
            XCTAssertEqual(view.font.fontName, primary.fontName)
            XCTAssertEqual(view.font.pointSize, primary.pointSize)
            XCTAssertEqual(view.font.maximumAdvancement, primary.maximumAdvancement)
            XCTAssertEqual(CTFontGetAscent(view.font), CTFontGetAscent(primary))
            XCTAssertEqual(CTFontGetDescent(view.font), CTFontGetDescent(primary))
            let grid = (view.getTerminal().cols, view.getTerminal().rows)
            let font = view.font
            view.setTerminalFont(family: family, size: 15)
            XCTAssertEqual(view.font, font)
            XCTAssertEqual(view.getTerminal().cols, grid.0)
            XCTAssertEqual(view.getTerminal().rows, grid.1)
            for style in ["0", "1", "3", "1;3"] {
                view.replaceSnapshot(Data("\u{1B}[\(style)m\u{F418} main A 中 ش".utf8))
                let terminal = view.getTerminal()
                let rendered = view.buildAttributedString(row: 0, line: terminal.getLine(row: 0)!, cols: terminal.cols)
                var sawBranchGlyph = false
                for segment in rendered.segments {
                    let line = CTLineCreateWithAttributedString(segment.attributedString as CFAttributedString)
                    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                        let resolved = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                        let name = CTFontCopyPostScriptName(resolved) as String
                        XCTAssertFalse(name.lowercased().contains("lastresort"), "\(family) / SGR \(style) / \(segment.attributedString.string)")
                        var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                        XCTAssertFalse(glyphs.isEmpty)
                        XCTAssertTrue(glyphs.allSatisfy { $0 > 0 })
                        if name == "CorralTerminalGitBranchSymbols-Regular" {
                            sawBranchGlyph = true
                            XCTAssertTrue(glyphs.allSatisfy { CTFontCreatePathForGlyph(resolved, $0, nil)?.isEmpty == false })
                        }
                    }
                }
                XCTAssertTrue(sawBranchGlyph, "\(family) / SGR \(style) must render F418 with the bundled outline")
            }
        }
    }
}
