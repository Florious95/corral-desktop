import AppKit
import CorralContracts
@testable import CorralUI
import XCTest

@MainActor
final class DragSplitMidlineProjectionTests: XCTestCase {
    private let target = SessionID("dev::target")
    private let source = SessionID("dev::source")

    func testMidlineLeftAndRightHoverProjectHalfPaneAndSplitTowardPointerSide() throws {
        let (window, stage) = makeStage()
        stage.splitView.update(root: .session(target), focusedSessionID: target)

        let leftDrag = drag(stage, x: 480)
        defer { leftDrag.pasteboard.releaseGlobally() }
        XCTAssertEqual(stage.draggingUpdated(leftDrag), .move)
        let left = try XCTUnwrap(stage.dropTarget)
        XCTAssertEqual(left.edge, .left, "x=480 is just left of the 1000pt stage midline")
        XCTAssertEqual(left.previewFrame.width, 497, accuracy: 2, "The 6pt divider leaves an approximately half-stage pane")
        XCTAssertNotEqual(left.previewFrame, stage.bounds, "The left-center drop must never shade the entire stage")

        stage.draggingExited(nil)
        let rightDrag = drag(stage, x: 520)
        defer { rightDrag.pasteboard.releaseGlobally() }
        XCTAssertEqual(stage.draggingUpdated(rightDrag), .move)
        let right = try XCTUnwrap(stage.dropTarget)
        XCTAssertEqual(right.edge, .right, "x=520 is just right of the 1000pt stage midline")
        XCTAssertEqual(right.previewFrame.width, 497, accuracy: 2)
        XCTAssertNotEqual(right.previewFrame, stage.bounds, "The right-center drop must never shade the entire stage")
        XCTAssertEqual(stage.dropZone.frame.width, right.previewFrame.width, accuracy: 0.1)
        XCTAssertEqual(window.contentView, stage)
    }

    func testCentralFortyToSixtyPercentBandNeverProjectsTheWholeStage() throws {
        let (_, stage) = makeStage()
        stage.splitView.update(root: .session(target), focusedSessionID: target)

        var previews: [(x: CGFloat, target: SplitLayout.DropTarget)] = []
        for x in [CGFloat(400), 480, 500, 520, 600] {
            stage.draggingExited(nil)
            let info = drag(stage, x: x)
            XCTAssertEqual(stage.draggingUpdated(info), .move, "A valid center-band hover at x=\(x) must remain a split target")
            if let target = stage.dropTarget { previews.append((x, target)) }
            info.pasteboard.releaseGlobally()
        }
        XCTAssertEqual(previews.count, 5)
        XCTAssertTrue(previews.allSatisfy {
            $0.target.edge != .center && $0.target.previewFrame != stage.bounds && $0.target.previewFrame.width < stage.bounds.width
        }, "Every 40–60% hover must show a pane-sized split preview, never the full blue stage; actual=\(previews)")
    }

    private func makeStage() -> (NSWindow, CorralWorkspaceStageView) {
        let bounds = NSRect(x: 0, y: 0, width: 1000, height: 600)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        let stage = CorralWorkspaceStageView(frame: bounds)
        window.contentView = stage
        stage.layoutSubtreeIfNeeded()
        return (window, stage)
    }

    private func drag(_ stage: CorralWorkspaceStageView, x: CGFloat) -> MidlineDraggingInfo {
        MidlineDraggingInfo(location: stage.convert(CGPoint(x: x, y: 300), to: nil),
                            session: source.rawValue)
    }
}

@MainActor
private final class MidlineDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("corral-midline-\(UUID().uuidString)"))
    let draggingLocation: NSPoint

    init(location: NSPoint, session: String) {
        draggingLocation = location
        super.init()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(session, forType: CorralWorkspaceStageView.sessionPasteboardType)
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
