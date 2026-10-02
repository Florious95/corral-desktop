import AppKit
import XCTest
@testable import CorralUI

/// Exercises the real tab controls and reorder pipeline after the system drag payload is parsed.
/// Pasteboard IPC and OS drag sessions require a separate integration runner.
@MainActor
final class Issue24TabDragReorderTests: XCTestCase {
    func testTabDragPreviewsWithoutReorderingModelThenCommitsOnceAfterDrop() throws {
        _ = NSApplication.shared
        let tabA = CorralTab(title: "Tab A")
        let tabB = CorralTab(title: "Tab B")
        let tabC = CorralTab(title: "Tab C")
        let workspace = CorralWorkspaceView(tabs: [tabA, tabB, tabC])
        workspace.frame = NSRect(x: 0, y: 0, width: 1400, height: 860)
        workspace.layoutSubtreeIfNeeded()
        workspace.tabBar.layoutSubtreeIfNeeded()
        XCTAssertNil(workspace.window, "The fixture must not depend on a WindowServer window")

        let bar = workspace.tabBar
        let source = try tabItem("Tab A", in: bar)
        let middle = try tabItem("Tab B", in: bar)
        let destination = try tabItem("Tab C", in: bar)
        let dropPoint = middle.convert(NSPoint(x: middle.bounds.maxX - 1, y: middle.bounds.midY), to: nil)
        let destinationCenter = destination.convert(NSPoint(x: destination.bounds.midX, y: destination.bounds.midY), to: nil)
        XCTAssertLessThan(dropPoint.x, destinationCenter.x, "The release point must be just right of Tab B and before Tab C's midpoint")

        var reorderCommits = 0
        let originalReorder = bar.onReorderTabs
        bar.onReorderTabs = { id, index in
            reorderCommits += 1
            originalReorder?(id, index)
        }
        let initialOrder = [tabA.id, tabB.id, tabC.id]
        XCTAssertEqual(bar.updateTabDragPreview(bar.dragDestination(at: dropPoint, tabID: tabA.id)), .move)
        XCTAssertEqual(bar.tabs.map(\.id), initialOrder, "Previewing a drag must not commit the tabs model")
        XCTAssertEqual(workspace.tabs.map(\.id), initialOrder, "Coordinator-facing workspace order must remain unchanged until release")
        XCTAssertEqual(reorderCommits, 0, "Coordinator reordering must not run while the drag is in flight")
        XCTAssertLessThan(source.alphaValue, 0.75, "The source TabItem should be visibly translucent during drag")
        let previewCenters = [middle, source, destination].map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: bar).x }
        XCTAssertTrue(previewCenters[0] < previewCenters[1] && previewCenters[1] < previewCenters[2],
                      "Crossing Tab B's midpoint should visually make room for Tab A on its right")

        XCTAssertTrue(bar.commitTabDrag(bar.dragDestination(at: dropPoint, tabID: tabA.id)), "Dropping Tab A to the right of Tab B must be accepted")
        XCTAssertEqual(bar.tabs.map(\.id), [tabB.id, tabA.id, tabC.id])
        XCTAssertEqual(workspace.tabs.map(\.id), [tabB.id, tabA.id, tabC.id], "The final order must be persisted by the workspace")
        XCTAssertEqual(reorderCommits, 1, "The final order is committed exactly once at drop")
    }

    private func tabItem(_ title: String, in bar: NSView, file: StaticString = #filePath, line: UInt = #line) throws -> NSView {
        try XCTUnwrap(descendants(of: bar).first {
            $0.accessibilityIdentifier() == "corral.tab" && $0.accessibilityLabel() == title
        }, "Missing TabItem \(title)", file: file, line: line)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
