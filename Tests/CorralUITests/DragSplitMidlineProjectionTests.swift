import AppKit
import CorralContracts
@testable import CorralUI
import XCTest

/// Tests the stage's production coordinate conversion and preview without pasteboard IPC or a window.
/// System pasteboard parsing and the OS drag manager remain integration-test boundaries.
@MainActor
final class DragSplitMidlineProjectionTests: XCTestCase {
    private let target = SessionID("dev::target")
    private let source = SessionID("dev::source")

    func testMidlineLeftAndRightHoverProjectHalfPaneAndSplitTowardPointerSide() throws {
        let stage = makeStage()
        stage.splitView.update(root: .session(target), focusedSessionID: target)

        XCTAssertEqual(hover(stage, x: 480), .move)
        let left = try XCTUnwrap(stage.dropTarget)
        XCTAssertEqual(left.edge, .left, "x=480 is just left of the 1000pt stage midline")
        XCTAssertEqual(left.previewFrame.width, 497, accuracy: 2, "The 6pt divider leaves an approximately half-stage pane")
        XCTAssertNotEqual(left.previewFrame, stage.bounds, "The left-center drop must never shade the entire stage")

        stage.draggingExited(nil)
        XCTAssertEqual(hover(stage, x: 520), .move)
        let right = try XCTUnwrap(stage.dropTarget)
        XCTAssertEqual(right.edge, .right, "x=520 is just right of the 1000pt stage midline")
        XCTAssertEqual(right.previewFrame.width, 497, accuracy: 2)
        XCTAssertNotEqual(right.previewFrame, stage.bounds, "The right-center drop must never shade the entire stage")
        XCTAssertEqual(stage.dropZone.frame.width, right.previewFrame.width, accuracy: 0.1)
        XCTAssertNil(stage.window, "The geometry fixture must not depend on a WindowServer window")
    }

    func testCentralFortyToSixtyPercentBandNeverProjectsTheWholeStage() throws {
        let stage = makeStage()
        stage.splitView.update(root: .session(target), focusedSessionID: target)

        var previews: [(x: CGFloat, target: SplitLayout.DropTarget)] = []
        for x in [CGFloat(400), 480, 500, 520, 600] {
            stage.draggingExited(nil)
            XCTAssertEqual(hover(stage, x: x), .move, "A valid center-band hover at x=\(x) must remain a split target")
            if let target = stage.dropTarget { previews.append((x, target)) }
        }
        XCTAssertEqual(previews.count, 5)
        XCTAssertTrue(previews.allSatisfy {
            $0.target.edge != .center && $0.target.previewFrame != stage.bounds && $0.target.previewFrame.width < stage.bounds.width
        }, "Every 40–60% hover must show a pane-sized split preview, never the full blue stage; actual=\(previews)")
    }

    private func makeStage() -> CorralWorkspaceStageView {
        let stage = CorralWorkspaceStageView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        stage.layoutSubtreeIfNeeded()
        return stage
    }

    private func hover(_ stage: CorralWorkspaceStageView, x: CGFloat) -> NSDragOperation {
        let point = stage.convert(CGPoint(x: x, y: 300), to: nil)
        return stage.updateDropPreview(stage.resolveDropTarget(at: point, source: source))
    }
}
