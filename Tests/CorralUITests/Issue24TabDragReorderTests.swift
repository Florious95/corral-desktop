import AppKit
import XCTest
@testable import CorralUI

@MainActor
final class Issue24TabDragReorderTests: XCTestCase {
    func testTabDragPreviewsWithoutReorderingModelThenCommitsOnceAfterDrop() throws {
        _ = NSApplication.shared
        let tabA = CorralTab(title: "Tab A")
        let tabB = CorralTab(title: "Tab B")
        let tabC = CorralTab(title: "Tab C")
        let workspace = CorralWorkspaceView(tabs: [tabA, tabB, tabC])
        workspace.frame = NSRect(x: 0, y: 0, width: 1400, height: 860)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1400, height: 860),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = workspace
        window.orderBack(nil)
        defer { window.close() }
        workspace.layoutSubtreeIfNeeded()
        workspace.tabBar.layoutSubtreeIfNeeded()
        XCTAssertLessThan(window.frame.minX, -1_000)
        XCTAssertLessThan(window.frame.minY, -1_000)
        XCTAssertFalse(window.isKeyWindow)

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
        let drag = Issue24DraggingInfo(location: dropPoint, session: tabA.id.uuidString)
        defer { drag.pasteboard.releaseGlobally() }

        XCTAssertEqual(bar.draggingEntered(drag), .move)
        XCTAssertEqual(bar.tabs.map(\.id), initialOrder, "Previewing a drag must not commit the tabs model")
        XCTAssertEqual(workspace.tabs.map(\.id), initialOrder, "Coordinator-facing workspace order must remain unchanged until release")
        XCTAssertEqual(reorderCommits, 0, "Coordinator reordering must not run while the drag is in flight")
        XCTAssertLessThan(source.alphaValue, 0.75, "The source TabItem should be visibly translucent during drag")
        let previewCenters = [middle, source, destination].map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: bar).x }
        XCTAssertTrue(previewCenters[0] < previewCenters[1] && previewCenters[1] < previewCenters[2],
                      "Crossing Tab B's midpoint should visually make room for Tab A on its right")

        XCTAssertTrue(bar.performDragOperation(drag), "Dropping Tab A to the right of Tab B must be accepted")
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

@MainActor
private final class Issue24DraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("corral-issue24-\(UUID().uuidString)"))
    let draggingLocation: NSPoint

    init(location: NSPoint, session: String) {
        draggingLocation = location
        super.init()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(session, forType: .string)
        pasteboard.writeObjects([item])
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
