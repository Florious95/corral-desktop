import CorralContracts
import CorralServices
@testable import CorralUI
import XCTest

/// Legacy `workspaceLayout.js` / `tabDrag.js` geometry (Issue #271/#272, PR #274): 6pt gaps, 120×60 leaves.
final class SplitLayoutTests: XCTestCase {
    private let a = SessionID("A"), b = SessionID("B"), c = SessionID("C"), d = SessionID("D"), s = SessionID("S")

    private func columns(_ ratio: Double, _ first: WorkspaceLayoutNode, _ second: WorkspaceLayoutNode) -> WorkspaceLayoutNode {
        .split(direction: .horizontal, ratio: ratio, first: first, second: second)
    }
    private func rows(_ ratio: Double, _ first: WorkspaceLayoutNode, _ second: WorkspaceLayoutNode) -> WorkspaceLayoutNode {
        .split(direction: .vertical, ratio: ratio, first: first, second: second)
    }
    private func frames(_ projection: SplitLayout.Projection) -> [SessionID: CGRect] {
        Dictionary(uniqueKeysWithValues: projection.panes.map { ($0.sessionID, $0.frame) })
    }

    func testProjectionLeavesSixPointGapsWithRemainderToTheSecondChild() {
        let pair = SplitLayout.project(columns(0.5, .session(a), .session(b)), in: CGRect(x: 0, y: 0, width: 1001, height: 600))
        XCTAssertEqual(frames(pair), [a: CGRect(x: 0, y: 0, width: 497, height: 600), b: CGRect(x: 503, y: 0, width: 498, height: 600)])
        XCTAssertEqual(pair.dividers.map(\.frame), [CGRect(x: 497, y: 0, width: 6, height: 600)])
        XCTAssertEqual(pair.dividers.map(\.path), ["root"])
        XCTAssertEqual(SplitLayout.project(.session(a), in: CGRect(x: 0, y: 0, width: 800, height: 500)).panes,
                       [SplitLayout.Pane(sessionID: a, frame: CGRect(x: 0, y: 0, width: 800, height: 500))])
        XCTAssertTrue(SplitLayout.project(nil, in: CGRect(x: 0, y: 0, width: 800, height: 500)).panes.isEmpty)
    }

    func testOneLeftTwoRightAndTwoByTwoProjectExactlyWithoutOverlapOrCracks() {
        let stage = CGRect(x: 0, y: 0, width: 1206, height: 806)
        let three = SplitLayout.project(columns(0.5, .session(a), rows(0.5, .session(b), .session(c))), in: stage)
        XCTAssertEqual(frames(three), [
            a: CGRect(x: 0, y: 0, width: 600, height: 806),
            b: CGRect(x: 606, y: 0, width: 600, height: 400),
            c: CGRect(x: 606, y: 406, width: 600, height: 400)
        ])
        XCTAssertEqual(three.dividers.map(\.path), ["root", "root.second"])
        XCTAssertEqual(three.dividers[1].frame, CGRect(x: 606, y: 400, width: 600, height: 6))

        let grid = SplitLayout.project(columns(0.5, rows(0.5, .session(a), .session(c)), rows(0.5, .session(b), .session(d))), in: stage)
        XCTAssertEqual(frames(grid), [
            a: CGRect(x: 0, y: 0, width: 600, height: 400), c: CGRect(x: 0, y: 406, width: 600, height: 400),
            b: CGRect(x: 606, y: 0, width: 600, height: 400), d: CGRect(x: 606, y: 406, width: 600, height: 400)
        ])
        XCTAssertEqual(grid.panes.map(\.sessionID), [a, c, b, d])
        XCTAssertEqual(grid.dividers.count, 3)
        let covered = grid.panes.reduce(0) { $0 + $1.frame.width * $1.frame.height } + grid.dividers.reduce(0) { $0 + $1.frame.width * $1.frame.height }
        XCTAssertEqual(covered, stage.width * stage.height, "leaves + gaps tile the stage exactly")
    }

    func testSubtreeMinimumsAreRecursiveAndProjectionNeverRoundsBelowTheFloor() {
        XCTAssertEqual(SplitLayout.minimumExtent(of: .session(a), along: .horizontal), 120)
        XCTAssertEqual(SplitLayout.minimumExtent(of: .session(a), along: .vertical), 60)
        let nested = columns(0.5, .session(a), columns(0.5, .session(b), .session(c)))
        XCTAssertEqual(SplitLayout.minimumExtent(of: columns(0.5, .session(b), .session(c)), along: .horizontal), 246)
        XCTAssertEqual(SplitLayout.minimumExtent(of: nested, along: .horizontal), 498, "ratio-aware: 246 / 0.5 + 6")
        XCTAssertEqual(SplitLayout.minimumExtent(of: nested, along: .vertical), 60)
        XCTAssertEqual(SplitLayout.minimumExtent(of: rows(0.5, .session(a), .session(b)), along: .vertical), 126)

        // 1200pt two columns at the persisted 0.1005 would floor to 119pt; the projection clamps to 120.
        let skewed = SplitLayout.project(columns(0.1005, .session(a), .session(b)), in: CGRect(x: 0, y: 0, width: 1200, height: 600))
        XCTAssertEqual(frames(skewed)[a]?.width, 120)
        XCTAssertEqual(frames(skewed)[b]?.width, 1074)
        let tall = SplitLayout.project(rows(0.95, .session(a), .session(b)), in: CGRect(x: 0, y: 0, width: 600, height: 700))
        XCTAssertEqual(frames(tall)[b]?.height, 60)
    }

    func testSinglePaneSupportsAllFiveZonesAndRejectsSelfDrops() throws {
        let stage = CGRect(x: 0, y: 0, width: 1000, height: 600)
        for (point, zone) in [(CGPoint(x: 50, y: 300), WorkspaceDropZone.left),
                              (CGPoint(x: 950, y: 300), .right), (CGPoint(x: 500, y: 20), .top),
                              (CGPoint(x: 500, y: 580), .bottom), (CGPoint(x: 500, y: 300), .center)] {
            let drop = try XCTUnwrap(SplitLayout.dropTarget(at: point, source: s, root: .session(a), in: stage))
            XCTAssertEqual(drop.edge, zone)
            XCTAssertEqual(drop.target, a)
            let candidate = try XCTUnwrap(WorkspaceLayoutNode.session(a).dropping(s, onto: a, edge: zone))
            XCTAssertEqual(drop.previewFrame, SplitLayout.project(candidate, in: stage).frame(of: s))
        }
        XCTAssertNil(SplitLayout.dropTarget(at: CGPoint(x: 400, y: 20), source: a, root: .session(a), in: stage))
        XCTAssertNil(SplitLayout.dropTarget(at: CGPoint(x: 1000, y: 20), source: s, root: .session(a), in: stage))
        let empty = try XCTUnwrap(SplitLayout.dropTarget(at: CGPoint(x: 10, y: 10), source: s, root: nil, in: stage))
        XCTAssertNil(empty.target)
        XCTAssertEqual(empty.previewFrame, stage)
    }

    func testMultiPaneDropPicksTheNearestNormalizedEdgeWithCenterCoreAndHysteresis() throws {
        let stage = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let root = columns(0.5, .session(a), .session(b)) // A: 0..<497
        func edge(_ x: CGFloat, _ y: CGFloat, previous: SplitLayout.DropTarget? = nil) -> WorkspaceDropZone? {
            SplitLayout.dropTarget(at: CGPoint(x: x, y: y), source: s, root: root, in: stage, previous: previous)?.edge
        }
        XCTAssertEqual(edge(20, 300), .left)
        XCTAssertEqual(edge(480, 300), .right)
        XCTAssertEqual(edge(248, 10), .top)
        XCTAssertEqual(edge(248, 590), .bottom)
        XCTAssertEqual(edge(248, 300), .center)
        XCTAssertEqual(edge(10, 10), .top, "diagonal corners resolve by normalized distance, not by axis order")
        XCTAssertEqual(edge(62.125, 75), .left, "exact ties (u = v = 0.125) prefer left > right > top > bottom")

        // Bottom wins by less than 3pt of left's axis: the previous edge holds; without history it flips.
        let held = SplitLayout.DropTarget(target: a, edge: .left, previewFrame: .zero)
        XCTAssertEqual(edge(25, 571.2), .bottom)
        XCTAssertEqual(edge(25, 571.2, previous: held), .left)
        XCTAssertEqual(edge(30, 580, previous: held), .bottom)

        let top = try XCTUnwrap(SplitLayout.dropTarget(at: CGPoint(x: 248, y: 10), source: s, root: root, in: stage))
        XCTAssertEqual(top.target, a)
        XCTAssertEqual(top.previewFrame, CGRect(x: 0, y: 0, width: 497, height: 297))
        let center = try XCTUnwrap(SplitLayout.dropTarget(at: CGPoint(x: 700, y: 300), source: s, root: root, in: stage))
        XCTAssertEqual(center.target, b)
        XCTAssertEqual(center.edge, .center)
        XCTAssertEqual(center.previewFrame, CGRect(x: 503, y: 0, width: 497, height: 600))
        XCTAssertNil(SplitLayout.dropTarget(at: CGPoint(x: 499, y: 300), source: s, root: root, in: stage), "the 6pt gap is not a pane")
    }

    func testDropsThatWouldSqueezeAnyLeafBelow120By60AreRejected() throws {
        // 300pt row: a third column would be 96pt wide.
        let narrow = columns(0.5, .session(a), .session(b))
        let narrowStage = CGRect(x: 0, y: 0, width: 300, height: 600)
        XCTAssertNil(SplitLayout.dropTarget(at: CGPoint(x: 5, y: 300), source: s, root: narrow, in: narrowStage))
        XCTAssertEqual(SplitLayout.dropTarget(at: CGPoint(x: 70, y: 300), source: s, root: narrow, in: narrowStage)?.edge, .center,
                       "replacing a pane never changes geometry")
        // 100pt tall stage: a top/bottom split would leave 47pt rows.
        let short = CGRect(x: 0, y: 0, width: 1000, height: 100)
        XCTAssertNil(SplitLayout.dropTarget(at: CGPoint(x: 248, y: 2), source: s, root: narrow, in: short))
        // 401pt: moving A to B's right yields two ~197pt columns, a legal layout (legacy R3).
        let moved = try XCTUnwrap(SplitLayout.dropTarget(at: CGPoint(x: 395, y: 300), source: a, root: narrow, in: CGRect(x: 0, y: 0, width: 401, height: 600)))
        XCTAssertEqual(moved.edge, .right)
        XCTAssertEqual(moved.previewFrame, CGRect(x: 203, y: 0, width: 198, height: 600))
        // Every leaf in a deep tree is checked, not only the target: 4 columns fit 520pt (≥124pt); a 5th does not.
        let four = try XCTUnwrap(WorkspaceLayoutNode.equalColumns([a, b, c, d].map(WorkspaceLayoutNode.session)))
        let wide = CGRect(x: 0, y: 0, width: 520, height: 600)
        XCTAssertNil(SplitLayout.dropTarget(at: CGPoint(x: 1, y: 300), source: s, root: four, in: wide))
        XCTAssertEqual(SplitLayout.dropTarget(at: CGPoint(x: 1, y: 300), source: s, root: four, in: CGRect(x: 0, y: 0, width: 700, height: 600))?.edge, .left)
    }

    func testDividerDragClampsToRecursiveMinimumsAndKeepsFourDecimalRatios() throws {
        let pair = SplitLayout.project(columns(0.5, .session(a), .session(b)), in: CGRect(x: 0, y: 0, width: 1000, height: 600))
        let divider = try XCTUnwrap(pair.dividers.first)
        XCTAssertEqual(divider.firstExtent, 497)
        XCTAssertEqual(SplitLayout.ratio(dragging: divider, by: 100), 0.6011)
        XCTAssertEqual(SplitLayout.ratio(dragging: divider, by: -1000), 0.1208, "left limit rounds up so floor(994 × r) ≥ 120")
        XCTAssertEqual(SplitLayout.ratio(dragging: divider, by: 1000), 0.8792, "right limit rounds down so the second keeps ≥ 120")
        XCTAssertNil(SplitLayout.ratio(dragging: divider, by: 0.3), "sub-point motion never writes a ratio")
        for delta in stride(from: -370.0, through: 370.0, by: 37.0) {
            guard let ratio = SplitLayout.ratio(dragging: divider, by: CGFloat(delta)) else { continue }
            let dragged = SplitLayout.project(columns(ratio, .session(a), .session(b)), in: CGRect(x: 0, y: 0, width: 1000, height: 600))
            XCTAssertEqual(dragged.panes[0].frame.width, 497 + CGFloat(delta), "the projected pane follows the pointer exactly (delta \(delta))")
        }

        // A nested right subtree (B | C) needs 246pt: the root divider cannot squeeze it.
        let nested = SplitLayout.project(columns(0.5, .session(a), columns(0.5, .session(b), .session(c))), in: CGRect(x: 0, y: 0, width: 1000, height: 600))
        let rootDivider = try XCTUnwrap(nested.dividers.first { $0.path == "root" })
        XCTAssertEqual(rootDivider.minimumSecond, 246)
        let squeezed = try XCTUnwrap(SplitLayout.ratio(dragging: rootDivider, by: 1000))
        XCTAssertEqual(994 - (994 * squeezed).rounded(.down), 247, "the right-limit ratio rounds down, leaving the subtree ≥ 246pt")

        // A stage too small for both minimums keeps the stored ratio instead of writing a distorted one.
        let cramped = SplitLayout.project(columns(0.5, .session(a), .session(b)), in: CGRect(x: 0, y: 0, width: 200, height: 600))
        XCTAssertNil(SplitLayout.ratio(dragging: try XCTUnwrap(cramped.dividers.first), by: 40))
    }
}
