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

    func testWorkspaceSpaceRowRendersDedicatedGitBranchIcon() throws {
        let sidebar = CorralSidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 700))
        let branchSpace = CorralSidebarSpace(id: UUID(), name: "feature/main", kind: .workspace)
        sidebar.setSpaces([branchSpace])
        sidebar.layoutSubtreeIfNeeded()

        // All Spaces and 收藏 precede real workspace rows in the delivery view.
        let row = try XCTUnwrap(
            sidebar.spacesTable.delegate?.tableView?(sidebar.spacesTable, viewFor: nil, row: 2) as? CorralSidebarCellView,
            "The Git branch workspace row must be rendered by the sidebar"
        )
        let iconView = try XCTUnwrap(
            descendants(of: row).compactMap { $0 as? NSImageView }.first,
            "The Git branch workspace row must expose an icon image view"
        )
        let actual = try XCTUnwrap(iconView.image, "The Git branch workspace row must not use an empty/missing-glyph image")
        let expected = try XCTUnwrap(CorralLegacyIcon.image(.gitBranch, size: 15))
        let actualData = try XCTUnwrap(actual.tiffRepresentation)
        let expectedData = try XCTUnwrap(expected.tiffRepresentation)
        XCTAssertEqual(
            actualData,
            expectedData,
            "A branch workspace must render the dedicated Git three-way branch vector, not a folder or [?] fallback"
        )
        try exportRenderedEvidenceIfRequested(actual)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func exportRenderedEvidenceIfRequested(_ image: NSImage) throws {
        guard let path = ProcessInfo.processInfo.environment["CORRAL_ISSUE6_EVIDENCE_DIR"] else { return }
        var proposedRect = NSRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("06-rendered-git-branch-row.png"))
    }
}
