import CorralContracts
import CorralServices
import CorralUI
import Foundation
import XCTest
@testable import CorralApp

@MainActor
final class ConversationSessionControllerTests: XCTestCase {
    private let ref = try! SessionReference("sock\u{1F}%7")
    private var sent: [ClientCommand] = []
    private var pending: [(request: ConversationHistoryRequest, continuation: CheckedContinuation<ConversationHistoryPage, Error>)] = []

    private func makeController() -> ConversationSessionController {
        let controller = ConversationSessionController(key: SessionKey(deviceID: DeviceID("dev"), reference: ref), connectionEpoch: ConnectionEpoch(1))
        controller.send = { [unowned self] command in self.sent.append(command) }
        controller.fetch = { [unowned self] request in
            try await withCheckedThrowingContinuation { continuation in self.pending.append((request, continuation)) }
        }
        return controller
    }

    private func ready(view: String) -> ConversationReady {
        ConversationReady(reference: ref, mode: "rpc", running: true, sessionID: "sid", viewID: view, sourceEpoch: "e",
                          snapshotSeq: 4, windowToken: "tok-\(view)", historySupport: "complete", sourceOmitted: false)
    }

    private func page(for request: ConversationHistoryRequest, items: [[String: Any]]) throws -> ConversationHistoryPage {
        let object: [String: Any] = ["request_id": request.requestID, "view_id": request.viewID, "source_epoch": "e", "snapshot_seq": 4,
                                     "items": items, "has_more_before": false, "has_more_after": false, "history_support": "complete", "source_omitted": false]
        return try JSONDecoder().decode(ConversationHistoryPage.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func row(_ id: String, _ order: String, revision: Int = 4) -> [String: Any] {
        ["id": id, "revision": revision, "order_key": order, "kind": "assistant", "summary": id, "body_state": "complete"]
    }

    private func settle() async { for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(10)) } }

    private func applied() -> [UInt64] {
        sent.compactMap { if case let .conversationApplied(_, _, _, seq) = $0 { seq } else { nil } }
    }

    private var subscribes: Int { sent.filter { if case .conversationSubscribe = $0 { true } else { false } }.count }

    func testInitialPageIsAdoptedBeforeBufferedLiveCommitsWhichAreAcknowledgedOnce() async throws {
        let controller = makeController()
        controller.start()
        await settle()
        XCTAssertEqual(subscribes, 1)
        controller.handleReady(ready(view: "v1"))
        await settle()
        let initial = try XCTUnwrap(pending.first?.request)
        XCTAssertEqual(initial.operation, .initial)
        XCTAssertEqual(initial.cursor, "tok-v1")
        XCTAssertEqual(initial.viewID, "v1")
        XCTAssertTrue(sent.contains { if case let .conversationCommand(_, _, command) = $0 { String(decoding: command, as: UTF8.self).contains("get_state") } else { false } })

        let live = ConversationItem(id: "live", revision: 5, orderKey: "z", kind: "assistant", summary: "streamed", streaming: true)
        controller.handleUpdate(ConversationUpdate(reference: ref, viewID: "v1", sourceEpoch: "e", baseSeq: 4, commitSeq: 5, upserts: [live], removes: [],
                                                   state: ConversationLiveState(running: true, queued: 1, mode: "rpc")))
        await settle()
        XCTAssertTrue(applied().isEmpty, "a commit buffered before the initial page is not acknowledged")

        pending.removeFirst().continuation.resume(returning: try page(for: initial, items: [row("b", "b"), row("a", "a")]))
        await settle()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.paneState().rows.map(\.id), ["a", "b", "live"])
        XCTAssertEqual(controller.paneState().queued, 1)
        XCTAssertEqual(applied(), [5])

        controller.handleUpdate(ConversationUpdate(reference: ref, viewID: "v1", sourceEpoch: "e", baseSeq: 5, commitSeq: 6, upserts: [], removes: [], state: nil))
        controller.handleUpdate(ConversationUpdate(reference: ref, viewID: "v1", sourceEpoch: "e", baseSeq: 6, commitSeq: 7, upserts: [], removes: [], state: nil))
        await settle()
        XCTAssertEqual(applied(), [5, 7], "acknowledgements are cumulative per run-loop turn")
    }

    func testAGapRecoversWithAFreshViewInsteadOfAdoptingOutOfOrderData() async throws {
        let controller = makeController()
        controller.start()
        controller.handleReady(ready(view: "v1"))
        await settle()
        let initial = pending.removeFirst()
        initial.continuation.resume(returning: try page(for: initial.request, items: [row("a", "a")]))
        await settle()
        controller.handleUpdate(ConversationUpdate(reference: ref, viewID: "v1", sourceEpoch: "e", baseSeq: 9, commitSeq: 10, upserts: [], removes: [], state: nil))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(subscribes, 2)
        XCTAssertTrue(applied().isEmpty)
        XCTAssertEqual(controller.paneState().rows.map(\.id), ["a"], "the reader keeps the rows while the view is rebuilt")
    }

    func testHistoryFailureIsLocalAndRetriesWithoutTouchingTheSubscription() async throws {
        let controller = makeController()
        controller.start()
        controller.handleReady(ready(view: "v1"))
        await settle()
        pending.removeFirst().continuation.resume(throwing: ConversationHistoryFailure("busy"))
        await settle()
        XCTAssertEqual(controller.phase, .historyFailed("busy"))
        XCTAssertFalse(sent.contains { if case .conversationUnsubscribe = $0 { true } else { false } })
        XCTAssertEqual(subscribes, 1)
        controller.retry()
        await settle()
        XCTAssertEqual(pending.first?.request.operation, .initial)
        XCTAssertEqual(subscribes, 1, "a busy history retry is an HTTP retry, not a resubscribe")
    }

    func testALateResultForARetiredViewIsNeverAdopted() async throws {
        let controller = makeController()
        controller.start()
        controller.handleReady(ready(view: "v1"))
        await settle()
        let stale = pending.removeFirst()
        controller.rebind(to: ConnectionEpoch(2))
        controller.handleReady(ready(view: "v2"))
        await settle()
        stale.continuation.resume(returning: try page(for: stale.request, items: [row("old", "a")]))
        await settle()
        XCTAssertTrue(controller.paneState().rows.isEmpty)
        let fresh = try XCTUnwrap(pending.first)
        XCTAssertEqual(fresh.request.viewID, "v2")
        pending.removeFirst().continuation.resume(returning: try page(for: fresh.request, items: [row("new", "a")]))
        await settle()
        XCTAssertEqual(controller.paneState().rows.map(\.id), ["new"])
    }

    func testClosedUnavailableFallsBackToTheTerminalAndToolBodiesParseOnlyWhenComplete() {
        let controller = makeController()
        XCTAssertTrue(controller.presentsConversation, "a managed pane shows the structured view while it connects")
        controller.handleClosed(.unavailable)
        XCTAssertFalse(controller.presentsConversation)
        XCTAssertNil(ConversationSessionController.toolBody(#"{"arguments":{"path":"a"},"output":"partial"#))
        let parsed = ConversationSessionController.toolBody(#"{"arguments":{"path":"a"},"output":"done"}"#)
        XCTAssertEqual(parsed?.arguments, #"{"path":"a"}"#)
        XCTAssertEqual(parsed?.output, "done")
    }
}
