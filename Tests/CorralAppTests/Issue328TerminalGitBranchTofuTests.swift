import AppKit
import CoreText
import XCTest
@testable import CorralApp

@MainActor
final class Issue328TerminalGitBranchTofuTests: XCTestCase {
    func testPiGitBranchCodepointUsesARealNonLastResortFallbackGlyph() {
        let terminal = CorralNativeTerminalView(frame: .zero)
        let sourceFont = terminal.font as CTFont
        let gitBranch = "\u{F418}"
        XCTAssertEqual(gitBranch.unicodeScalars.first?.value, 0xF418,
                       "The tested character must be the actual Nerd Font nf-oct-git_branch codepoint")

        let resolvedFont = CTFontCreateForString(sourceFont, gitBranch as CFString,
                                                 CFRange(location: 0, length: gitBranch.utf16.count))
        let resolvedName = CTFontCopyPostScriptName(resolvedFont) as String
        var codeUnit: UniChar = 0xF418
        var glyph = CGGlyph()
        let mapped = CTFontGetGlyphsForCharacters(resolvedFont, &codeUnit, &glyph, 1)

        XCTAssertNotEqual(resolvedName, "LastResort",
                          "U+F418 must resolve through the terminal font fallback chain, not LastResort")
        XCTAssertTrue(mapped, "CoreText must map U+F418 using the resolved fallback font")
        XCTAssertNotEqual(glyph, CGGlyph(0), "U+F418 must resolve to an actual glyph")
        XCTAssertNotEqual(glyph, CGGlyph(0xFFFF), "U+F418 must not resolve to CoreText's missing-glyph sentinel")
    }
}
