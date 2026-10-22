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
    private var controlSubscribes: Int { sent.filter { if case .conversationSubscribeControl = $0 { true } else { false } }.count }

    private func switchCommands() -> [[String: Any]] {
        sent.compactMap { command in
            guard case let .conversationCommand(_, id, body) = command,
                  var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], object["type"] as? String == "switch_mode" else { return nil }
            object["id"] = id
            return object
        }
    }

    private func event(_ object: [String: Any], view: String? = nil) -> ConversationEvent {
        ConversationEvent(reference: ref, viewID: view, sourceEpoch: nil, event: try! JSONSerialization.data(withJSONObject: object))
    }

    /// A ready windowed controller whose initial page has been adopted.
    private func readyController() async throws -> ConversationSessionController {
        let controller = makeController()
        controller.start()
        controller.handleReady(ready(view: "v1"))
        await settle()
        let initial = pending.removeFirst()
        initial.continuation.resume(returning: try page(for: initial.request, items: [row("a", "a")]))
        await settle()
        controller.handleUpdate(ConversationUpdate(reference: ref, viewID: "v1", sourceEpoch: "e", baseSeq: 4, commitSeq: 5, upserts: [], removes: [],
                                                   state: ConversationLiveState(running: false, queued: 0, mode: "rpc")))
        await settle()
        return controller
    }

    private func usageCommands() -> [(String, String)] {
        sent.compactMap {
            guard case let .conversationCommand(reference, id, body) = $0,
                  String(decoding: body, as: UTF8.self) == #"{"type":"get_session_stats"}"# else { return nil }
            return (reference.rawValue, id)
        }
    }

    private var usageData: [String: Any] {
        ["tokens": ["input": 1200, "output": 300, "cacheRead": 4000, "cacheWrite": 500, "total": 6000],
         "cost": 0.1234, "contextUsage": ["tokens": 2500, "contextWindow": 10000, "percent": 25.0]]
    }

    func testUsageMenuQueriesNativeTotalsOnceWithoutTranscriptMutation() async throws {
        let controller = try await readyController()
        let rowsBefore = controller.paneState().rows
        let menu = try XCTUnwrap(controller.header.makeActionMenu?())
        XCTAssertEqual(menu.entries.map(\.spec.id), [.usage, .terminal])
        XCTAssertTrue(menu.performAction(.usage))
        XCTAssertTrue(menu.performAction(.usage))
        controller.refreshUsage()
        await settle()
        XCTAssertEqual(usageCommands().count, 1)
        XCTAssertEqual(usageCommands().first?.0, ref.rawValue)
        let id = try XCTUnwrap(usageCommands().first?.1)
        controller.handleEvent(event(["type": "response", "id": "unrelated", "success": true, "data": usageData]))
        XCTAssertEqual(controller.usageDashboard?.state, .loading)
        controller.handleEvent(event(["type": "response", "id": id, "success": true, "data": usageData], view: "wrong-view"))
        XCTAssertEqual(controller.usageDashboard?.state, .loading)
        controller.handleEvent(event(["type": "response", "id": id, "success": true, "data": usageData], view: "v1"))
        guard case let .ready(usage, _) = controller.usageDashboard?.state else { return XCTFail("No native usage snapshot") }
        XCTAssertEqual(usage.tokens.total, 6000)
        XCTAssertEqual(usage.cost, 0.1234)
        XCTAssertEqual(usage.contextUsage?.knownPercent, 25)
        XCTAssertEqual(controller.paneState().rows, rowsBefore)
        XCTAssertTrue(switchCommands().isEmpty)
        controller.usageDashboard?.handleEscape()
        XCTAssertNil(controller.usageDashboard)
    }

    func testUsageRefreshAndMalformedResponsesDoNotInventZero() async throws {
        let controller = try await readyController()
        XCTAssertTrue(controller.performAction(.usage))
        await settle()
        var id = try XCTUnwrap(usageCommands().last?.1)
        controller.handleEvent(event(["type": "response", "id": id, "success": true, "data": ["cost": 0]]))
        guard case .failed = controller.usageDashboard?.state else { return XCTFail("Incomplete totals accepted") }
        controller.refreshUsage()
        await settle()
        id = try XCTUnwrap(usageCommands().last?.1)
        var data = usageData
        data["contextUsage"] = ["tokens": NSNull(), "contextWindow": 10000, "percent": NSNull()]
        controller.handleEvent(event(["type": "response", "id": id, "success": true, "data": data]))
        guard case let .ready(usage, _) = controller.usageDashboard?.state else { return XCTFail("Unknown context rejected") }
        XCTAssertNil(usage.contextUsage?.knownPercent)
        XCTAssertEqual(usage.tokens.total, 6000)
        controller.stop()
    }

    func testStaleMenuAndLateUsageResponseCannotCrossRebind() async throws {
        let controller = try await readyController()
        let menu = try XCTUnwrap(controller.actionMenu())
        XCTAssertTrue(menu.performAction(.usage))
        await settle()
        let id = try XCTUnwrap(usageCommands().first?.1)
        controller.rebind(to: ConnectionEpoch(2))
        guard case .unavailable = controller.usageDashboard?.state else { return XCTFail("Stale metrics survived reconnect") }
        controller.handleEvent(event(["type": "response", "id": id, "success": true, "data": usageData]))
        guard case .unavailable = controller.usageDashboard?.state else { return XCTFail("Late response adopted") }
        XCTAssertFalse(controller.performAction(.usage))
        _ = menu.performAction(.usage) // Cached enabled row rechecks the controller's current context.
        await settle()
        XCTAssertEqual(usageCommands().count, 1)
        controller.stop()
    }

    func testMenuModeActionUsesExistingBusyConsentPath() async throws {
        let controller = try await readyController()
        XCTAssertTrue(controller.actionMenu()?.performAction(.terminal) == true)
        await settle()
        XCTAssertEqual(switchCommands().count, 1)
        XCTAssertEqual(switchCommands().first?["mode"] as? String, "tui")
        XCTAssertEqual(switchCommands().first?["force"] as? Bool, false)
        XCTAssertFalse(controller.performAction(.usage))
        controller.handleEvent(event(["type": "response", "id": switchCommands()[0]["id"]!, "success": false, "data": ["busy": true], "error": "busy"]))
        XCTAssertTrue(controller.modeSwitch?.awaitingConsent == true)
        controller.cancelSwitch()
        controller.stop()
    }

    func testUsageSendFailureAndCloseDoNotAcceptLateReceipts() async throws {
        let controller = try await readyController()
        controller.send = { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertTrue(controller.performAction(.usage))
        await settle()
        guard case .failed = controller.usageDashboard?.state else { return XCTFail("Network failure not surfaced") }
        controller.usageDashboard?.handleEscape()
        controller.send = { [unowned self] in self.sent.append($0) }
        XCTAssertTrue(controller.performAction(.usage))
        await settle()
        let id = try XCTUnwrap(usageCommands().last?.1)
        controller.stop()
        controller.handleEvent(event(["type": "response", "id": id, "success": true, "data": usageData]))
        XCTAssertNil(controller.usageDashboard)
    }

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

    func testClosedUnavailableFallsBackToTheTerminalAndToolBodiesParseOnlyWhenComplete() async {
        let controller = makeController()
        XCTAssertTrue(controller.presentsConversation, "a managed pane shows the structured view while it connects")
        controller.handleClosed(.unavailable)
        await settle()
        XCTAssertEqual(controlSubscribes, 1, "a closed windowed view first asks the worker itself (a TUI has no window)")
        controller.handleClosed(.unavailable)
        XCTAssertFalse(controller.presentsConversation)
        XCTAssertFalse(controller.presentsHeader, "an unmanaged pane is a plain terminal: no switcher")
        XCTAssertNil(ConversationSessionController.toolBody(#"{"arguments":{"path":"a"},"output":"partial"#))
        let parsed = ConversationSessionController.toolBody(#"{"arguments":{"path":"a"},"output":"done"}"#)
        XCTAssertEqual(parsed?.arguments, #"{"path":"a"}"#)
        XCTAssertEqual(parsed?.output, "done")
    }

    // MARK: Mode switching (b40 facts: a switch to the TUI retires the windowed view and loses its response;
    // the worker's control-lane ready reports rpc until worker_mode announces the confirmed replacement).

    func testSwitchToTerminalIsConfirmedByTheWorkerNotByTheLocalClick() async throws {
        let controller = try await readyController()
        controller.requestSwitch(to: .tui)
        await settle()
        let command = try XCTUnwrap(switchCommands().first)
        XCTAssertEqual(command["mode"] as? String, "tui")
        XCTAssertEqual(command["force"] as? Bool, false)
        XCTAssertEqual(controller.headerState().pendingMode, .tui)
        XCTAssertEqual(controller.headerState().mode, .gui, "the selected segment waits for the native mode")
        controller.handleResync(viewID: "v1", reason: "source_changed")
        await settle()
        XCTAssertEqual(controlSubscribes, 1)
        controller.handleControlReady(mode: "rpc", running: false)
        await settle()
        XCTAssertTrue(controller.presentsConversation, "mid-switch the GUI stays until the worker confirms")
        XCTAssertEqual(subscribes, 1, "no premature windowed resubscribe while the replacement Pi starts")
        controller.handleEvent(event(["type": "worker_mode", "mode": "tui"]))
        await settle()
        XCTAssertFalse(controller.presentsConversation)
        XCTAssertTrue(controller.presentsHeader)
        XCTAssertEqual(controller.headerState().mode, .tui)
        XCTAssertNil(controller.headerState().pendingMode)
        XCTAssertEqual(switchCommands().count, 1, "a switch is written exactly once")
    }

    func testABusyRefusalAsksForConsentAndCancelWritesNothing() async throws {
        let controller = try await readyController()
        var consent: [CorralViewportHeaderState.Mode] = []
        controller.onConsentNeeded = { consent.append($0) }
        controller.requestSwitch(to: .tui)
        controller.handleResync(viewID: "v1", reason: "source_changed")
        controller.handleControlReady(mode: "rpc", running: true)
        await settle()
        XCTAssertEqual(consent, [.tui])
        XCTAssertEqual(controller.headerState().canSwitch, false)
        controller.cancelSwitch()
        await settle()
        XCTAssertEqual(switchCommands().count, 1, "cancelling consent sends no second switch")
        XCTAssertEqual(subscribes, 2, "the still-running RPC Pi gets its live view back")
        XCTAssertNil(controller.modeSwitch)
    }

    func testConfirmedConsentForcesOnTheAttachedLane() async throws {
        let controller = try await readyController()
        controller.requestSwitch(to: .tui)
        controller.handleResync(viewID: "v1", reason: "source_changed")
        controller.handleControlReady(mode: "rpc", running: true)
        controller.confirmSwitch()
        await settle()
        let commands = switchCommands()
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.last?["force"] as? Bool, true)
        controller.handleEvent(event(["type": "worker_mode", "mode": "tui"]))
        XCTAssertEqual(controller.nativeMode, .tui)
    }

    func testTerminalToGUIUsesTheControlLaneAndResubscribesOnce() async throws {
        let controller = makeController()
        controller.start()
        controller.handleClosed(.exited)
        await settle()
        XCTAssertEqual(controlSubscribes, 1)
        controller.handleControlReady(mode: "tui", running: false)
        XCTAssertTrue(controller.managed)
        XCTAssertFalse(controller.presentsConversation)
        controller.requestSwitch(to: .gui)
        await settle()
        let command = try XCTUnwrap(switchCommands().first)
        XCTAssertEqual(command["mode"] as? String, "rpc")
        // Core publishes worker_mode before the response to the same client.
        controller.handleEvent(event(["type": "worker_mode", "mode": "rpc"]))
        controller.handleEvent(event(["type": "response", "id": command["id"] as Any, "command": "switch_mode", "success": true, "data": ["mode": "rpc"]]))
        await settle()
        XCTAssertEqual(subscribes, 2, "start plus exactly one windowed resubscribe")
        controller.handleReady(ready(view: "v9"))
        await settle()
        XCTAssertTrue(controller.presentsConversation)
        XCTAssertNil(controller.modeSwitch)
    }

    func testDefaultModeAppliesOnceOnExplicitOpenAndBusyKeepsTheMode() async throws {
        let controller = makeController()
        controller.start()
        controller.handleClosed(.exited)
        controller.noteExplicitOpen(preferred: .gui)
        await settle()
        XCTAssertTrue(switchCommands().isEmpty, "nothing is written before the native mode is known")
        controller.handleControlReady(mode: "tui", running: false)
        await settle()
        let command = try XCTUnwrap(switchCommands().first)
        XCTAssertEqual(command["force"] as? Bool, false, "the preference never forces")
        var consent = 0
        controller.onConsentNeeded = { _ in consent += 1 }
        controller.handleEvent(event(["type": "response", "id": command["id"] as Any, "command": "switch_mode", "success": false,
                                      "error": "当前任务正在运行", "data": ["mode": "tui", "busy": true]]))
        await settle()
        XCTAssertEqual(consent, 0, "an automatic switch never interrupts work")
        XCTAssertEqual(controller.headerState().notice, "Pi 正在运行任务，已保持终端")
        controller.handleControlReady(mode: "tui", running: false)
        await settle()
        XCTAssertEqual(switchCommands().count, 1, "the preference is applied once per explicit open")
    }
}
