import CorralContracts
import CorralServices
import XCTest

final class WorkspaceLayoutTopologyTests: XCTestCase {
    private let a = SessionID("A"), b = SessionID("B"), c = SessionID("C"), d = SessionID("D")

    func testEdgeDropsRebalanceSingleLeafColumnsAndSplitCompoundColumnsInPlace() throws {
        let pair = try XCTUnwrap(WorkspaceLayoutNode.session(a).dropping(b, onto: a, edge: .right))
        XCTAssertEqual(pair, .split(direction: .horizontal, ratio: 0.5, first: .session(a), second: .session(b)))

        // Legacy dropNode: a new column beside a single-leaf column rebalances every column 1:1:1.
        let skewed = WorkspaceLayoutNode.split(direction: .horizontal, ratio: 0.8, first: .session(a), second: .session(b))
        XCTAssertEqual(skewed.dropping(c, onto: a, edge: .right), .split(
            direction: .horizontal, ratio: 1.0 / 3,
            first: .session(a),
            second: .split(direction: .horizontal, ratio: 0.5, first: .session(c), second: .session(b))
        ))

        // A | (B / C): a vertical edge splits B in place; a side edge on B splits B, never rebalancing A.
        let nested = WorkspaceLayoutNode.split(direction: .horizontal, ratio: 0.7, first: .session(a),
            second: .split(direction: .vertical, ratio: 0.3, first: .session(b), second: .session(c)))
        XCTAssertEqual(nested.dropping(d, onto: b, edge: .bottom), .split(direction: .horizontal, ratio: 0.7, first: .session(a),
            second: .split(direction: .vertical, ratio: 0.3,
                first: .split(direction: .vertical, ratio: 0.5, first: .session(b), second: .session(d)),
                second: .session(c))))
        XCTAssertEqual(nested.dropping(d, onto: b, edge: .left), .split(direction: .horizontal, ratio: 0.7, first: .session(a),
            second: .split(direction: .vertical, ratio: 0.3,
                first: .split(direction: .horizontal, ratio: 0.5, first: .session(d), second: .session(b)),
                second: .session(c))))
    }

    func testMovingAnExistingLeafVacatesItsSlotAndCenterReplacesTheTarget() throws {
        let columns = try XCTUnwrap(WorkspaceLayoutNode.session(a).dropping(b, onto: a, edge: .right)?.dropping(c, onto: b, edge: .right))
        XCTAssertEqual(columns.leafIDs, [a, b, c])
        let moved = try XCTUnwrap(columns.dropping(a, onto: c, edge: .right))
        XCTAssertEqual(moved.leafIDs, [b, c, a])
        XCTAssertEqual(moved.topLevelColumns.count, 3)
        guard case let .split(_, ratio, _, _) = moved else { return XCTFail("three columns must stay split") }
        XCTAssertEqual(ratio, 1.0 / 3, accuracy: 1e-12)

        XCTAssertEqual(columns.dropping(a, onto: c, edge: .center)?.leafIDs, [b, a])
        XCTAssertNil(columns.dropping(a, onto: a, edge: .left), "dropping a pane on itself is a no-op")
        XCTAssertNil(WorkspaceLayoutNode.session(a).dropping(a, onto: a, edge: .right))
    }

    func testTwoByTwoGridIsBuiltByDropsAndClosingPromotesTheSiblingSubtreeIntact() throws {
        var root = WorkspaceLayoutNode.session(a)
        root = try XCTUnwrap(root.dropping(b, onto: a, edge: .right))
        root = try XCTUnwrap(root.dropping(c, onto: a, edge: .bottom))
        root = try XCTUnwrap(root.dropping(d, onto: b, edge: .bottom))
        XCTAssertEqual(root, .split(direction: .horizontal, ratio: 0.5,
            first: .split(direction: .vertical, ratio: 0.5, first: .session(a), second: .session(c)),
            second: .split(direction: .vertical, ratio: 0.5, first: .session(b), second: .session(d))))
        XCTAssertEqual(root.leafIDs, [a, c, b, d])
        XCTAssertTrue(root.isValid)

        let custom = WorkspaceLayoutNode.split(direction: .horizontal, ratio: 0.62,
            first: .split(direction: .vertical, ratio: 0.5, first: .session(a), second: .session(c)),
            second: .split(direction: .vertical, ratio: 0.27, first: .session(b), second: .session(d)))
        XCTAssertEqual(custom.removing(c), .split(direction: .horizontal, ratio: 0.62, first: .session(a),
            second: .split(direction: .vertical, ratio: 0.27, first: .session(b), second: .session(d))))
        XCTAssertEqual(custom.removing(a)?.removing(c), .split(direction: .vertical, ratio: 0.27, first: .session(b), second: .session(d)))
        XCTAssertNil(WorkspaceLayoutNode.session(a).removing(a))
        XCTAssertEqual(custom.removing(SessionID("missing")), custom)
    }

    func testClosingAPaneKeepsFocusRebalancesPureColumnsAndPreservesNestedRatios() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("corral-topology-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try CorralWorkspaceStore(applicationSupportDirectory: support)
        _ = try await store.smartOpenSession(a, gesture: .doubleClick)
        _ = try await store.splitSession(b, target: a, edge: .right)
        _ = try await store.splitSession(c, target: b, edge: .right)
        _ = try await store.updateSplitRatio(path: "root", ratio: 0.2)
        _ = try await store.focusPane(a)

        var state = try await store.closePane(b)
        XCTAssertEqual(state.activeTab?.root, .split(direction: .horizontal, ratio: 0.5, first: .session(a), second: .session(c)),
                       "pure columns are rebalanced 1:1 after a close")
        XCTAssertEqual(state.activeTab?.activeSessionID, a, "closing an unfocused pane keeps the focus")

        _ = try await store.splitSession(d, target: c, edge: .bottom)
        _ = try await store.updateSplitRatio(path: "root.second", ratio: 0.3)
        _ = try await store.focusPane(c)
        state = try await store.closePane(a)
        XCTAssertEqual(state.activeTab?.root, .split(direction: .vertical, ratio: 0.3, first: .session(c), second: .session(d)),
                       "the promoted sibling keeps its own ratio")
        XCTAssertEqual(state.activeTab?.activeSessionID, c)

        state = try await store.closePane(c)
        XCTAssertEqual(state.activeTab?.root, .session(d))
        XCTAssertEqual(state.activeTab?.activeSessionID, d, "a closed focus falls back to the first surviving leaf")
    }
}
