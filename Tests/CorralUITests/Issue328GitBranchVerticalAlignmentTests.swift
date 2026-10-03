import AppKit
import CoreText
import XCTest
@testable import CorralApp

@MainActor
final class Issue328GitBranchVerticalAlignmentTests: XCTestCase {
    func testGitBranchGlyphOpticalCenterMatchesUppercaseAndDigitBaseline() {
        let terminal = CorralNativeTerminalView(frame: .zero)
        let font = terminal.font as CTFont
        let uppercase = glyphMetrics("H", in: font)
        let digit = glyphMetrics("0", in: font)
        let branch = glyphMetrics("\u{F418}", in: font)
        let referenceCenter = (uppercase.bounds.midY + digit.bounds.midY) / 2
        let yOffset = branch.bounds.midY - referenceCenter

        XCTAssertNotEqual(branch.fontName, "LastResort",
                           "U+F418 must resolve to the configured branch-symbol font; branch=\(branch.bounds), H=\(uppercase.bounds), 0=\(digit.bounds), yOffset=\(yOffset)pt")
        XCTAssertGreaterThan(branch.glyph, 0, "U+F418 must map to a real glyph")
        XCTAssertNotEqual(branch.glyph, CGGlyph(0xFFFF), "U+F418 must not map to the missing-glyph sentinel")
        XCTAssertLessThanOrEqual(abs(yOffset), 0.75,
                                 "U+F418 optical center must align with H/0; branch=\(branch.bounds), H=\(uppercase.bounds), 0=\(digit.bounds), yOffset=\(yOffset)pt")
    }

    private func glyphMetrics(_ text: String, in baseFont: CTFont) -> (fontName: String, glyph: CGGlyph, bounds: CGRect) {
        let resolvedFont = CTFontCreateForString(baseFont, text as CFString,
                                                 CFRange(location: 0, length: text.utf16.count))
        let units = Array(text.utf16)
        var glyph = CGGlyph()
        let mapped = units.withUnsafeBufferPointer {
            CTFontGetGlyphsForCharacters(resolvedFont, $0.baseAddress!, &glyph, 1)
        }
        XCTAssertTrue(mapped, "CoreText must map \(text.unicodeScalars.first!.value) in \(CTFontCopyPostScriptName(resolvedFont) as String)")
        var bounds = CGRect.zero
        _ = CTFontGetBoundingRectsForGlyphs(resolvedFont, .default, &glyph, &bounds, 1)
        return (CTFontCopyPostScriptName(resolvedFont) as String, glyph, bounds)
    }
}
