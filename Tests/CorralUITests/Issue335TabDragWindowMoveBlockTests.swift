import AppKit
import XCTest
@testable import CorralUI

@MainActor
final class Issue335TabDragWindowMoveBlockTests: XCTestCase {
    func testTabDragIsOwnedByTabBarAndCannotMoveWindow() throws {
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
        XCTAssertFalse(window.isKeyWindow, "The offscreen test window must never take keyboard focus")

        let bar = workspace.tabBar
        let source = try tabItem("Tab A", in: bar)
        let target = try tabItem("Tab B", in: bar)
        let originalWindowFrame = window.frame

        XCTAssertFalse(source.mouseDownCanMoveWindow,
                       "A TabItem must own its drag gesture instead of passing it to AppKit window dragging")
        XCTAssertFalse(bar.mouseDownCanMoveWindow,
                       "The TabBar must never be interpreted as a window-drag region")
        XCTAssertTrue(source is NSDraggingSource,
                      "The hit-tested TabItem must provide the internal tab drag source")

        // Exercise the TabBar's internal drag destination path with a private pasteboard.
        // This keeps the test fully background/offscreen and avoids a system drag cursor.
        let dropPoint = target.convert(NSPoint(x: target.bounds.maxX - 1, y: target.bounds.midY), to: nil)
        let drag = Issue335DraggingInfo(location: dropPoint, tabID: tabA.id.uuidString)
        defer { drag.pasteboard.releaseGlobally() }
        XCTAssertEqual(bar.draggingEntered(drag), .move)
        XCTAssertLessThan(source.alphaValue, 0.75, "The internal tab drag preview should make its source translucent")
        XCTAssertEqual(window.frame, originalWindowFrame, "The tab drag preview must not move the window")
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
private final class Issue335DraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("corral-issue335-\(UUID().uuidString)"))
    let draggingLocation: NSPoint

    init(location: NSPoint, tabID: String) {
        draggingLocation = location
        super.init()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(tabID, forType: .string)
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
