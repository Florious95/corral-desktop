import CorralContracts
@testable import CorralServices
import Foundation
import XCTest

final class ConversationTranscriptTests: XCTestCase {
    private let ref = try! SessionReference("r")

    private func ready(view: String = "v", epoch: String = "e", h: UInt64 = 5) -> ConversationReady {
        ConversationReady(reference: ref, mode: "rpc", running: false, sessionID: "sid", viewID: view, sourceEpoch: epoch,
                          snapshotSeq: h, windowToken: "t", historySupport: "complete", sourceOmitted: false)
    }

    private func item(_ id: String, _ order: String, revision: UInt64 = 5, kind: String = "assistant", summary: String = "", deferred: Bool = false) -> ConversationItem {
        ConversationItem(id: id, revision: revision, orderKey: order, kind: kind, summary: summary.isEmpty ? id : summary,
                         bodyRef: deferred ? "b-\(id)" : nil, bodyState: deferred ? "deferred" : "complete")
    }

    private func page(_ items: [ConversationItem], before: String? = nil, more: Bool = false, view: String = "v", epoch: String = "e", h: UInt64 = 5) throws -> ConversationHistoryPage {
        var object: [String: Any] = ["request_id": "q", "view_id": view, "source_epoch": epoch, "snapshot_seq": h,
                                     "items": try items.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) },
                                     "has_more_before": more, "has_more_after": false, "history_support": "complete", "source_omitted": false]
        if let before { object["before_cursor"] = before }
        return try JSONDecoder().decode(ConversationHistoryPage.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func update(base: UInt64, commit: UInt64, upserts: [ConversationItem] = [], removes: [String] = [], view: String = "v") -> ConversationUpdate {
        ConversationUpdate(reference: ref, viewID: view, sourceEpoch: "e", baseSeq: base, commitSeq: commit, upserts: upserts, removes: removes, state: nil)
    }

    func testLiveCommitsWaitForTheInitialPageAndMustBeContiguous() throws {
        var transcript = ConversationTranscript(ready: ready())
        XCTAssertEqual(transcript.apply(update(base: 5, commit: 6, upserts: [item("live", "z", revision: 6)])), .notReady)
        XCTAssertTrue(transcript.adoptInitial(try page([item("b", "b"), item("a", "a")])))
        XCTAssertEqual(transcript.items.map(\.id), ["a", "b"], "rows follow order keys, not page order")
        XCTAssertEqual(transcript.apply(update(base: 6, commit: 7)), .gap)
        XCTAssertEqual(transcript.apply(update(base: 5, commit: 6, upserts: [item("c", "c", revision: 6)], view: "other")), .foreign)
        XCTAssertEqual(transcript.apply(update(base: 5, commit: 6, upserts: [item("c", "c", revision: 6)])), .applied)
        XCTAssertEqual(transcript.liveSeq, 6)
        XCTAssertEqual(transcript.items.map(\.id), ["a", "b", "c"])
        XCTAssertFalse(transcript.adoptInitial(try page([item("x", "x")])), "a view adopts exactly one initial page")
    }

    func testPagesFromAnotherViewSourceOrSnapshotAreRejected() throws {
        var transcript = ConversationTranscript(ready: ready())
        XCTAssertFalse(transcript.adoptInitial(try page([item("a", "a")], view: "old")))
        XCTAssertFalse(transcript.adoptInitial(try page([item("a", "a")], epoch: "old")))
        XCTAssertFalse(transcript.adoptInitial(try page([item("a", "a")], h: 4)))
        XCTAssertTrue(transcript.items.isEmpty)
    }

    func testFixedHistoryNeverOverwritesALiveRevisionNorRevivesARemovedRow() throws {
        var transcript = ConversationTranscript(ready: ready())
        XCTAssertTrue(transcript.adoptInitial(try page([item("m", "m"), item("n", "n")], before: "c1", more: true)))
        // A live revision for an already loaded row, then the removal of another.
        XCTAssertEqual(transcript.apply(update(base: 5, commit: 6, upserts: [item("m", "m", revision: 6, summary: "live")], removes: ["n"])), .applied)
        XCTAssertEqual(transcript.apply(update(base: 6, commit: 7, upserts: [item("m", "m", revision: 3, summary: "stale")])), .applied)
        XCTAssertEqual(transcript.item(id: "m")?.summary, "live", "an older revision never wins")
        // An older page that still contains both rows at H.
        XCTAssertTrue(transcript.adoptOlder(try page([item("k", "k"), item("m", "m", summary: "history"), item("n", "n")]), cursor: "c1"))
        XCTAssertEqual(transcript.items.map(\.id), ["k", "m"])
        XCTAssertEqual(transcript.item(id: "m")?.summary, "live")
        XCTAssertFalse(transcript.hasMoreBefore)
        XCTAssertFalse(transcript.adoptOlder(try page([item("j", "j")]), cursor: "c1"), "a consumed cursor is not reused")
    }

    func testLiveRowsOlderThanTheLoadedWindowAreParkedUntilTheirPageArrives() throws {
        var transcript = ConversationTranscript(ready: ready())
        XCTAssertTrue(transcript.adoptInitial(try page([item("m", "m")], before: "c1", more: true)))
        let toolResult = ConversationItem(id: "old-tool", revision: 6, orderKey: "c", kind: "tool", summary: "done", toolPhase: "succeeded")
        XCTAssertEqual(transcript.apply(update(base: 5, commit: 6, upserts: [toolResult])), .applied)
        XCTAssertEqual(transcript.items.map(\.id), ["m"], "no isolated row next to the cached suffix")
        let pending = ConversationItem(id: "old-tool", revision: 5, orderKey: "c", kind: "tool", summary: "", toolPhase: "pending")
        XCTAssertTrue(transcript.adoptOlder(try page([pending]), cursor: "c1"))
        XCTAssertEqual(transcript.item(id: "old-tool")?.toolPhase, "succeeded")
    }

    func testDisplayIsBoundedAndSaysSo() throws {
        var transcript = ConversationTranscript(ready: ready())
        let pageItems = (0..<40).map { item(String(format: "h%04d", $0), String(format: "a%04d", $0)) }
        XCTAssertTrue(transcript.adoptInitial(try page(pageItems)))
        var seq: UInt64 = 5
        for batch in 0..<30 {
            let upserts = (0..<50).map { item(String(format: "l%02d%02d", batch, $0), String(format: "b%02d%02d", batch, $0), revision: seq + 1) }
            XCTAssertEqual(transcript.apply(update(base: seq, commit: seq + 1, upserts: upserts)), .applied)
            seq += 1
        }
        XCTAssertEqual(transcript.items.count, ConversationTranscript.maximumItems)
        XCTAssertTrue(transcript.reachedDisplayLimit)
        XCTAssertFalse(transcript.hasMoreBefore)
        XCTAssertEqual(transcript.items.last?.id, "l2949", "the live tail is never evicted")
    }

    func testBodiesAreBoundToTheirRevisionAndShareOneBudget() throws {
        var transcript = ConversationTranscript(ready: ready())
        XCTAssertTrue(transcript.adoptInitial(try page([item("a", "a", deferred: true), item("b", "b", deferred: true)])))
        XCTAssertFalse(transcript.storeBody(id: "a", revision: 9, text: "future", complete: true), "a body for a revision not yet seen is not adopted")
        XCTAssertTrue(transcript.storeBody(id: "a", revision: 5, text: "full a", complete: true))
        XCTAssertEqual(transcript.body(for: "a")?.text, "full a")
        let large = String(repeating: "x", count: ConversationTranscript.maximumBodyBytes - 2)
        XCTAssertTrue(transcript.storeBody(id: "b", revision: 5, text: large, complete: true))
        XCTAssertNil(transcript.body(for: "a"), "the least recently used body is evicted to stay within 8 MiB")
        XCTAssertNotNil(transcript.body(for: "b"))
        XCTAssertFalse(transcript.storeBody(id: "b", revision: 5, text: large + large, complete: true))
    }
}
