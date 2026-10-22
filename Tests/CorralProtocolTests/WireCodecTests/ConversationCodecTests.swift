import CorralContracts
import CorralProtocol
import Foundation
import XCTest

final class ConversationCodecTests: XCTestCase {
    private let codec = JSONV1Codec()
    private let ref = try! SessionReference("/tmp/s\u{1F}%3")

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAuthOffersBothConversationCapabilitiesAndAckEchoIsExposed() throws {
        let auth = try object(codec.encodeAuthentication(AuthToken("secret")))
        let payload = try XCTUnwrap(auth["payload"] as? [String: Any])
        XCTAssertEqual(payload["capabilities"] as? [String], ["conversation_v1", "conversation_window_v1"])
        XCTAssertEqual(payload["token"] as? String, "secret")

        let ack = try codec.decodeControlMessage(Data(#"{"v":1,"type":"auth_ack","payload":{"ok":true,"capabilities":["conversation_v1"]}}"#.utf8))
        XCTAssertEqual(ack, .authAck(ok: true, reason: nil, launchers: [], capabilities: ["conversation_v1"]))
        let legacy = try codec.decodeControlMessage(Data(#"{"v":1,"type":"auth_ack","payload":{"ok":true}}"#.utf8))
        XCTAssertEqual(legacy, .authAck(ok: true, reason: nil, launchers: [], capabilities: []))
    }

    func testSubscribeIsAlwaysWindowedAndCommandsCarryTheirObject() throws {
        let subscribe = try object(codec.encodeClientCommand(.conversationSubscribe(reference: ref)))
        XCTAssertEqual(subscribe["type"] as? String, "conversation_subscribe")
        XCTAssertEqual(subscribe["payload"] as? [String: String], ["ref": ref.rawValue, "history_mode": "windowed"])

        let command = try object(codec.encodeClientCommand(.conversationCommand(reference: ref, id: "gs-1", command: Data(#"{"type":"get_state"}"#.utf8))))
        let payload = try XCTUnwrap(command["payload"] as? [String: Any])
        XCTAssertEqual(payload["id"] as? String, "gs-1")
        XCTAssertEqual((payload["command"] as? [String: String])?["type"], "get_state")

        let applied = try object(codec.encodeClientCommand(.conversationApplied(reference: ref, viewID: "v", sourceEpoch: "e", commitSeq: 7)))
        XCTAssertEqual((applied["payload"] as? [String: Any])?["commit_seq"] as? Int, 7)

        XCTAssertThrowsError(try codec.encodeClientCommand(.conversationCommand(reference: ref, id: "", command: Data("{}".utf8))))
        XCTAssertThrowsError(try codec.encodeClientCommand(.conversationCommand(reference: ref, id: String(repeating: "x", count: 65), command: Data("{}".utf8))))
        XCTAssertThrowsError(try codec.encodeClientCommand(.conversationCommand(reference: ref, id: "a", command: Data("[1]".utf8))))
        let oversize = Data(("{\"type\":\"prompt\",\"message\":\"" + String(repeating: "x", count: 17_000) + "\"}").utf8)
        XCTAssertThrowsError(try codec.encodeClientCommand(.conversationCommand(reference: ref, id: "a", command: oversize)))
    }

    func testWindowedReadyDecodesAndLegacyReadyIsIgnoredNotFatal() throws {
        let ready = try codec.decodeControlMessage(Data(#"{"v":1,"type":"conversation_ready","payload":{"ref":"r","stream":"s","head_seq":0,"reset":false,"history_truncated":false,"running":true,"server_time_ms":1,"mode":"","history_mode":"windowed","session_id":"sid","view_id":"v1","source_epoch":"e1","snapshot_seq":9,"window_token":"t","history_support":"retained_window","source_omitted":true}}"#.utf8))
        guard case let .conversationReady(value) = ready else { return XCTFail("\(ready)") }
        XCTAssertEqual(value.mode, "rpc", "an empty mode from older workers means rpc")
        XCTAssertEqual(value.viewID, "v1")
        XCTAssertEqual(value.snapshotSeq, 9)
        XCTAssertTrue(value.running)
        XCTAssertTrue(value.sourceOmitted)
        XCTAssertEqual(value.historySupport, "retained_window")

        let legacy = try codec.decodeControlMessage(Data(#"{"v":1,"type":"conversation_ready","payload":{"ref":"r","stream":"s","head_seq":3}}"#.utf8))
        XCTAssertEqual(legacy, .conversationIgnored(type: "conversation_ready"))

        XCTAssertEqual(try codec.decodeControlMessage(Data(#"{"v":1,"type":"conversation_ready","payload":{"ref":"r","history_mode":"windowed","view_id":"v"}}"#.utf8)),
                       .conversationMalformed(reference: try SessionReference("r"), type: "conversation_ready"),
                       "an incomplete windowed ready isolates that view instead of an empty GUI or a dead terminal link")
    }

    func testLiveFramesDecodeAndUnknownConversationFramesNeverBreakTheLink() throws {
        let update = try codec.decodeControlMessage(Data(#"{"v":1,"type":"conversation_update","payload":{"ref":"r","view_id":"v","source_epoch":"e","base_seq":2,"commit_seq":3,"upserts":[{"id":"i","revision":3,"order_key":"k","kind":"tool","summary":"","body_ref":"live:x","body_state":"deferred","streaming":true,"tool_id":"i","tool_name":"bash","tool_phase":"running","future_field":1}],"removes":["old"],"state":{"running":true,"queued":2,"mode":"rpc"}}}"#.utf8))
        guard case let .conversationUpdate(value) = update else { return XCTFail("\(update)") }
        XCTAssertEqual(value.baseSeq, 2)
        XCTAssertEqual(value.commitSeq, 3)
        XCTAssertEqual(value.removes, ["old"])
        XCTAssertEqual(value.state, ConversationLiveState(running: true, queued: 2, mode: "rpc"))
        XCTAssertEqual(value.upserts.first?.toolPhase, "running")
        XCTAssertTrue(value.upserts.first?.isDeferred == true)

        XCTAssertEqual(try codec.decodeControlMessage(Data(#"{"v":1,"type":"conversation_update","payload":{"ref":"r","view_id":"v","source_epoch":"e","base_seq":3,"commit_seq":3}}"#.utf8)),
                       .conversationMalformed(reference: try SessionReference("r"), type: "conversation_update"))

        let event = try codec.decodeControlMessage(Data(#"{"v":1,"type":"conversation_event","payload":{"ref":"r","view_id":"v","event":{"type":"response","id":"gs-1","success":true}}}"#.utf8))
        guard case let .conversationEvent(raw) = event else { return XCTFail("\(event)") }
        let native = try object(raw.event)
        XCTAssertEqual(native["id"] as? String, "gs-1")

        XCTAssertEqual(try codec.decodeControlMessage(Data(#"{"v":1,"type":"conversation_resync","payload":{"ref":"r","view_id":"v","source_epoch":"e","reason":"gap"}}"#.utf8)),
                       .conversationResync(reference: try SessionReference("r"), viewID: "v", sourceEpoch: "e", reason: "gap"))
        XCTAssertEqual(try codec.decodeControlMessage(Data(#"{"v":1,"type":"conversation_closed","payload":{"ref":"r","reason":"exited"}}"#.utf8)),
                       .conversationClosed(reference: try SessionReference("r"), reason: .exited))
        XCTAssertEqual(try codec.decodeControlMessage(Data(#"{"v":1,"type":"conversation_live_range","payload":{}}"#.utf8)),
                       .conversationIgnored(type: "conversation_live_range"))
        XCTAssertThrowsError(try codec.decodeControlMessage(Data(#"{"v":1,"type":"totally_unknown","payload":{}}"#.utf8)),
                             "the existing strict policy for non-conversation frames is unchanged")
    }

    func testListingCarriesTheConversationMarker() throws {
        let listing = try codec.decodeControlMessage(Data(#"{"v":1,"type":"listing","payload":{"req_id":1,"seq":1,"workspaces":[{"cwd":"/w","session_count":2,"sessions":[{"ref":"a","name":"pi","cwd":"/w","rows":24,"cols":80,"provider":"pi","activity":"idle","health":"normal","conversation":true},{"ref":"b","name":"sh","cwd":"/w","rows":24,"cols":80}]}]}}"#.utf8))
        guard case let .listing(value) = listing else { return XCTFail("\(listing)") }
        XCTAssertEqual(value.workspaces[0].sessions.map(\.conversation), [true, false])
    }
}
