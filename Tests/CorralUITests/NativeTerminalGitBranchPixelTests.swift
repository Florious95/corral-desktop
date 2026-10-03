import AppKit
import CoreText
import CorralServices
@testable import CorralApp
@testable import SwiftTerm
import XCTest

final class NativeTerminalGitBranchPixelTests: XCTestCase {
    @MainActor
    func testPiFooterDrawsTheBundledBranchOutlineAtTheBottomOfTheViewport() throws {
        for family in [UserPreferences.defaultFontFamily, "Menlo", "Monaco", "corral-unavailable-font"] {
            let view = CorralNativeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
            view.setTerminalFont(family: family, size: 13)
            XCTAssertNil(view.window)
            XCTAssertFalse(view.isUsingMetalRenderer)
            let reference = CTFontCreateWithName("CorralTerminalGitBranchSymbols-Regular" as CFString, 13, nil)
            XCTAssertEqual(CTFontCopyPostScriptName(reference) as String, "CorralTerminalGitBranchSymbols-Regular")
            var code: UniChar = 0xF418
            var glyph: CGGlyph = 0
            XCTAssertTrue(CTFontGetGlyphsForCharacters(reference, &code, &glyph, 1))
            XCTAssertGreaterThan(glyph, 0)
            for style in ["0", "1", "3", "1;3"] {
                let row = view.getTerminal().rows - 1
                let prefix = "$0.00 +4 -0 "
                view.replaceSnapshot(Data("\u{1B}[\(row + 1);1H\u{1B}[\(style)m\(prefix)\u{F418} main".utf8))
                let metric = view.cellDimension!
                let bottom = view.frame.height - CGFloat(row + 1) * metric.height
                var position = CGPoint(x: CGFloat(prefix.count) * metric.width, y: bottom + ceil(CTFontGetDescent(view.font) + CTFontGetLeading(view.font)))
                let roi = CGRect(x: position.x * 2, y: (view.frame.height - bottom - metric.height) * 2, width: metric.width * 2, height: metric.height * 2)
                func context() throws -> CGContext {
                    let result = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 960, bitsPerComponent: 8, bytesPerRow: 6400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    result.scaleBy(x: 2, y: 2)
                    return result
                }
                let actual = try context()
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: actual, flipped: false)
                view.draw(view.bounds)
                NSGraphicsContext.restoreGraphicsState()
                let expected = try context()
                expected.setShouldSmoothFonts(view.fontSmoothing)
                expected.setFillColor(view.effectiveNativeForegroundColor.cgColor)
                CTFontDrawGlyphs(reference, &glyph, &position, 1, expected)
                func pixels(_ source: CGContext, column: Int? = nil) throws -> (data: Data, width: Int) {
                    let rect = roi.offsetBy(dx: CGFloat((column ?? prefix.count) - prefix.count) * metric.width * 2, dy: 0)
                    let image = try XCTUnwrap(source.makeImage()?.cropping(to: rect))
                    // Cropped CGImages may still expose their parent's backing data.
                    let normalized = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    normalized.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    return (Data(bytes: normalized.data!, count: image.width * image.height * 4), image.width)
                }
                let golden = try pixels(expected)
                XCTAssertTrue(golden.data.contains { $0 > 0 }, "The reference must contain visible branch pixels")
                let branch = try pixels(actual)
                XCTAssertEqual(branch.data, golden.data, "\(family) / SGR \(style): actual TerminalView.draw must render the bundled outline, not tofu")
                func inkCenter(_ image: (data: Data, width: Int)) throws -> Double {
                    var mass = 0.0, moment = 0.0
                    for offset in stride(from: 3, to: image.data.count, by: 4) {
                        let alpha = Double(image.data[offset])
                        mass += alpha
                        moment += alpha * Double((offset / 4) / image.width)
                    }
                    return try XCTUnwrap(mass > 0 ? moment / mass : nil, "The glyph must contain visible ink")
                }
                let zero = try pixels(actual, column: prefix.count - 2)
                XCTAssertLessThanOrEqual(abs(try inkCenter(branch) - inkCenter(zero)), 1,
                                         "\(family) / SGR \(style): branch ink must optically center within one 2x pixel of the adjacent digit")
            }
        }
    }
}
