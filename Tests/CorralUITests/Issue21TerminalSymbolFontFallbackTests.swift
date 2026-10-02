import AppKit
import CoreText
@testable import CorralApp
import XCTest

@MainActor
final class Issue21TerminalSymbolFontFallbackTests: XCTestCase {
    func testTerminalFontResolvesDiskAndGitSymbolsOutsideLastResort() {
        let terminal = CorralNativeTerminalView(frame: .zero)
        let primaryFont = terminal.font as CTFont
        let primaryName = CTFontCopyPostScriptName(primaryFont) as String

        for (label, scalarValue) in [("disk U+1F5AB", 0x1F5AB), ("Git branch U+E0A0", 0xE0A0)] {
            let scalar = UnicodeScalar(scalarValue)!
            let symbol = String(scalar)
            let resolved = CTFontCreateForString(primaryFont, symbol as CFString, CFRange(location: 0, length: symbol.utf16.count))
            let postScriptName = CTFontCopyPostScriptName(resolved) as String
            let familyName = CTFontCopyFamilyName(resolved) as String
            let isLastResort = postScriptName.localizedCaseInsensitiveContains("LastResort")
                || familyName.localizedCaseInsensitiveContains("LastResort")

            XCTAssertFalse(isLastResort, "\(label) resolved to LastResort (\(postScriptName), \(familyName))")
            XCTAssertNotEqual(postScriptName, primaryName, "\(label) must resolve through the dedicated symbol-font fallback")

            let characters = Array(symbol.utf16)
            var glyphs = Array(repeating: CGGlyph(0), count: characters.count)
            let mapped = characters.withUnsafeBufferPointer { characterBuffer in
                glyphs.withUnsafeMutableBufferPointer { glyphBuffer in
                    CTFontGetGlyphsForCharacters(resolved, characterBuffer.baseAddress!, glyphBuffer.baseAddress!, characters.count)
                }
            }
            XCTAssertTrue(mapped, "CoreText must map \(label)")
            XCTAssertGreaterThan(glyphs[0], 0, "\(label) must have a nonzero glyph ID")
            XCTAssertNotEqual(glyphs[0], CGGlyph(0xFFFF), "\(label) must not use the missing-glyph sentinel")
        }
    }
}
