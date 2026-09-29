import AppKit
@testable import CorralUI
import XCTest

@MainActor
final class Issue6GitBranchIconTests: XCTestCase {
    func testGitBranchIconAssetIsRegisteredAndRenderable() throws {
        let icon = try XCTUnwrap(
            CorralLegacyIcon.allCases.first { $0.rawValue.localizedCaseInsensitiveContains("branch") },
            "The UI must provide a dedicated Git branch symbol/vector instead of a missing-glyph fallback"
        )
        let image = try XCTUnwrap(CorralLegacyIcon.image(icon, size: 24), "The Git branch asset must produce an image")
        var proposedRect = NSRect(origin: .zero, size: NSSize(width: 24, height: 24))
        let rendered = try XCTUnwrap(
            image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil),
            "The Git branch asset must have a rasterizable vector/symbol representation"
        )
        XCTAssertGreaterThan(rendered.width, 0)
        XCTAssertGreaterThan(rendered.height, 0)
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let paintedPixels = (0..<bitmap.pixelsHigh).reduce(into: 0) { count, y in
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                count += 1
            }
        }
        XCTAssertGreaterThan(paintedPixels, 0, "The vector/symbol asset must paint visible pixels")
    }
}
