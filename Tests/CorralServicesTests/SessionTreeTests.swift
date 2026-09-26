import CorralContracts
import CorralServices
import XCTest

final class SessionTreeTests: XCTestCase {
    func testNestedHorizontalAndVerticalSplitsPreserveRatiosAndCollapseOnRemoval() throws {
        let first = SessionID("pane-1")
        let second = SessionID("pane-2")
        let third = SessionID("pane-3")
        var tree = try SessionTree(root: .session(first))

        try tree.split(first, adding: second, direction: .horizontal, ratio: 0.4)
        try tree.split(second, adding: third, direction: .vertical, ratio: 0.65)
        XCTAssertEqual(tree.sessionIDs, [first, second, third])
        XCTAssertEqual(
            tree.root,
            .split(
                direction: .horizontal,
                ratio: 0.4,
                first: .session(first),
                second: .split(direction: .vertical, ratio: 0.65, first: .session(second), second: .session(third))
            )
        )

        XCTAssertTrue(tree.remove(second))
        XCTAssertEqual(
            tree.root,
            .split(direction: .horizontal, ratio: 0.4, first: .session(first), second: .session(third))
        )
        XCTAssertTrue(tree.remove(first))
        XCTAssertEqual(tree.root, .session(third))
        XCTAssertFalse(tree.remove(first))
    }

    func testRejectsInvalidRatiosAndDuplicatePaneIDs() throws {
        let first = SessionID("pane-1")
        var tree = try SessionTree(root: .session(first))

        XCTAssertThrowsError(try tree.split(first, adding: SessionID("pane-2"), direction: .horizontal, ratio: 1))
        XCTAssertThrowsError(try tree.split(first, adding: first, direction: .vertical))
        XCTAssertThrowsError(try SessionTree(root: .split(
            direction: .vertical,
            ratio: .infinity,
            first: .session(first),
            second: .session(SessionID("pane-2"))
        )))
    }

    func testEmptyTreeCanReceiveItsFirstPaneButRejectsEmptyIDs() throws {
        var tree = try SessionTree()
        let first = SessionID("first")

        try tree.setInitialSession(first)
        XCTAssertEqual(tree.sessionIDs, [first])
        XCTAssertThrowsError(try tree.setInitialSession(SessionID("other")))
        XCTAssertThrowsError(try tree.split(first, adding: SessionID(""), direction: .horizontal))
        XCTAssertThrowsError(try SessionTree(root: .session(SessionID(""))))
    }

    func testEncodesAndDecodesValidTopology() throws {
        let tree = try SessionTree(root: .split(
            direction: .vertical,
            ratio: 0.3,
            first: .session(SessionID("one")),
            second: .session(SessionID("two"))
        ))

        XCTAssertEqual(try JSONDecoder().decode(SessionTree.self, from: JSONEncoder().encode(tree)), tree)
    }
}
