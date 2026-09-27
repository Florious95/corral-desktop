import CorralContracts
import CorralProtocol
import Foundation
import XCTest

final class WireCodecTests: XCTestCase {
    func testCapturedControlFramesDecodeWithCurrentV1Contracts() throws {
        let fixture = try goldenFrames()
        let frames = try XCTUnwrap(fixture["frames"] as? [String: [String: Any]])
        let codec = JSONV1Codec()

        let auth = try codec.decodeControlMessage(capturedBytes(try XCTUnwrap(frames["auth_ok"])))
        XCTAssertEqual(auth, .authAck(ok: true, reason: nil))

        let listingFrame = try XCTUnwrap(frames["session_list"])
        guard case let .listing(listing) = try codec.decodeControlMessage(capturedBytes(listingFrame)) else {
            return XCTFail("Expected the captured listing response")
        }
        let sessions = listing.workspaces.flatMap(\.sessions)
        XCTAssertEqual(listing.requestID, 1)
        XCTAssertGreaterThan(listing.sequence, 0)
        XCTAssertEqual(sessions.count, listingFrame["fixture_session_count"] as? Int)
        XCTAssertTrue(sessions.allSatisfy { $0.state == .idle })
        XCTAssertTrue(sessions.first?.reference.rawValue.contains("\u{1F}%0") ?? false)
    }

    func testCapturedBinarySnapshotAndDeltaRoundTripByteForByte() throws {
        let fixture = try goldenFrames()
        let frames = try XCTUnwrap(fixture["frames"] as? [String: [String: Any]])
        let codec = BinaryV1Codec()

        for (name, expectedKind) in [("snapshot", FrameKind.snapshot), ("delta", .delta)] {
            let capture = try XCTUnwrap(frames[name])
            let bytes = try capturedBytes(capture)
            let frame = try codec.decodeBinaryFrame(bytes)
            XCTAssertEqual(frame.kind, expectedKind)
            XCTAssertEqual(frame.reference.rawValue, capture["ref"] as? String)
            XCTAssertEqual(frame.reference.rawValue.utf8.count, capture["ref_length"] as? Int)
            XCTAssertEqual(try codec.encodeBinaryFrame(frame), bytes)
        }
    }

    func testAgentCreateAndCloseCommandsUseExactServerFieldsAndUInt32IDs() throws {
        let codec = JSONV1Codec()
        let anchor = try SessionReference("socket\u{1F}%1")
        let create = CreateAgentRequest(requestID: 17, workspace: "/workspace", anchorReference: anchor, provider: "codex", name: "Review worker", bypass: false)
        let createData = try codec.encodeClientCommand(.createAgent(create))
        let createFrame = try XCTUnwrap(JSONSerialization.jsonObject(with: createData) as? [String: Any])
        let createPayload = try XCTUnwrap(createFrame["payload"] as? [String: Any])
        XCTAssertEqual(createFrame["v"] as? Int, 1)
        XCTAssertEqual(createFrame["type"] as? String, "create_agent")
        XCTAssertEqual(createPayload["req_id"] as? Int, 17)
        XCTAssertEqual(createPayload["workspace"] as? String, "/workspace")
        XCTAssertEqual(createPayload["anchor_ref"] as? String, anchor.rawValue)
        XCTAssertEqual(createPayload["provider"] as? String, "codex")
        XCTAssertEqual(createPayload["name"] as? String, "Review worker")
        XCTAssertEqual(createPayload["bypass"] as? Bool, false)

        let close = CloseSessionRequest(requestID: 18, reference: anchor)
        let closeData = try codec.encodeClientCommand(.closeSession(close))
        let closeFrame = try XCTUnwrap(JSONSerialization.jsonObject(with: closeData) as? [String: Any])
        XCTAssertEqual(closeFrame["type"] as? String, "close_session")
        let closePayload = try XCTUnwrap(closeFrame["payload"] as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: closePayload).isEqual(to: ["req_id": 18, "ref": anchor.rawValue]))

        let missingAnchor = CreateAgentRequest(requestID: 1, workspace: "/workspace", anchorReference: nil, provider: "codex", name: "worker", bypass: false)
        XCTAssertThrowsError(try codec.encodeClientCommand(.createAgent(missingAnchor))) {
            XCTAssertEqual($0 as? V1ControlCodecError, .invalidField("create_agent.anchor_ref"))
        }
        XCTAssertThrowsError(try codec.encodeClientCommand(.createAgent(CreateAgentRequest(requestID: 0, workspace: "/workspace", anchorReference: anchor, provider: "codex", name: "worker", bypass: false)))) {
            XCTAssertEqual($0 as? V1ControlCodecError, .invalidField("create_agent.req_id"))
        }
        XCTAssertThrowsError(try codec.encodeClientCommand(.createAgent(CreateAgentRequest(requestID: 1, workspace: "/workspace", anchorReference: anchor, provider: "codex", name: String(repeating: "界", count: 65), bypass: false)))) {
            XCTAssertEqual($0 as? V1ControlCodecError, .invalidField("create_agent.name"))
        }
    }

    func testAgentResultAndAuthAckMessagesDecodeLosslessly() throws {
        let codec = JSONV1Codec()
        let auth = Data(#"{"v":1,"type":"auth_ack","payload":{"ok":true,"agent_launchers":[{"provider":"codex","display_name":"Codex CLI","supports_bypass":true,"naming":"tmux"}]}}"#.utf8)
        guard case let .authAck(ok, reason, launchers) = try codec.decodeControlMessage(auth) else {
            return XCTFail("Expected auth_ack")
        }
        XCTAssertTrue(ok)
        XCTAssertNil(reason)
        XCTAssertEqual(launchers, [AgentLauncher(provider: "codex", displayName: "Codex CLI", supportsBypass: true, naming: .tmux)])

        let created = Data(#"{"v":1,"type":"create_agent_result","payload":{"req_id":17,"ok":true,"ref":"socket\u001f%8","name":"Review worker","naming":"tmux"}}"#.utf8)
        guard case let .createAgentResult(result) = try codec.decodeControlMessage(created) else {
            return XCTFail("Expected create_agent_result")
        }
        XCTAssertEqual(result, CreateAgentResult(requestID: 17, ok: true, reference: try SessionReference("socket\u{1F}%8"), name: "Review worker", naming: .tmux))

        let rejected = Data(#"{"v":1,"type":"create_agent_result","payload":{"req_id":19,"ok":false,"reason":"provider_unavailable"}}"#.utf8)
        XCTAssertEqual(try codec.decodeControlMessage(rejected), .createAgentResult(CreateAgentResult(requestID: 19, ok: false, reason: .providerUnavailable)))
        let closed = Data(#"{"v":1,"type":"close_session_result","payload":{"req_id":18,"ok":false,"reason":"session_not_found"}}"#.utf8)
        XCTAssertEqual(try codec.decodeControlMessage(closed), .closeSessionResult(CloseSessionResult(requestID: 18, ok: false, reason: .sessionNotFound)))
        let closeResult = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(CloseSessionResult(requestID: 18, ok: false, reason: .sessionNotFound))) as? [String: Any])
        XCTAssertEqual(closeResult["req_id"] as? Int, 18)
        XCTAssertNil(closeResult["ref"])
        let closedOK = Data(#"{"v":1,"type":"close_session_result","payload":{"req_id":18,"ok":true}}"#.utf8)
        XCTAssertEqual(try codec.decodeControlMessage(closedOK), .closeSessionResult(CloseSessionResult(requestID: 18, ok: true)))
        let error = Data(#"{"v":1,"type":"error","payload":{"code":"invalid_field","reason":"name is invalid"}}"#.utf8)
        XCTAssertEqual(try codec.decodeControlMessage(error), .error(code: .invalidField, reason: "name is invalid"))

        XCTAssertThrowsError(try codec.decodeControlMessage(Data(#"{"v":1,"type":"create_agent_result","payload":{"req_id":0,"ok":false,"reason":"invalid_field"}}"#.utf8)))
        XCTAssertThrowsError(try codec.decodeControlMessage(Data(#"{"v":1,"type":"close_session_result","payload":{"req_id":18,"ok":true,"reason":"close_failed"}}"#.utf8)))
    }

    func testListingDefaultsMissingAggregateStateFromWorkingCount() throws {
        let frame = Data(#"{"v":1,"type":"listing","payload":{"req_id":1,"seq":2,"workspaces":[{"cwd":"/workspace","session_count":1,"working_count":1,"sessions":[{"ref":"s1","name":"agent","window_name":"agent","window_index":"0","cwd":"/workspace","title":"title","provider":"codex","activity":"working","health":"normal","status":"working","rows":24,"cols":80}]},{"cwd":"/idle","session_count":0,"working_count":0,"sessions":[]}]}}"#.utf8)
        guard case let .listing(listing) = try JSONV1Codec().decodeControlMessage(frame) else {
            return XCTFail("Expected listing")
        }
        XCTAssertEqual(listing.workspaces.map(\.aggregateState), [.working, .idle])

        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
        let payload = try XCTUnwrap(envelope["payload"] as? [String: Any])
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let contractListing = try JSONDecoder().decode(SessionListing.self, from: payloadData)
        XCTAssertEqual(contractListing.workspaces.map(\.aggregateState), [.working, .idle])
    }

    func testListingPreservesFullAgentMirrordSessionAndWorkspaceFields() throws {
        let json = Data(#"{"v":1,"type":"listing","payload":{"req_id":7,"seq":42,"workspaces":[{"cwd":"/workspace","session_count":1,"working_count":1,"aggregate_state":"working","sessions":[{"ref":"socket\u001f%1","name":"Codex task","window_name":"Codex task","window_index":"3","cwd":"/workspace","title":"Exact OSC title","provider":"codex","activity":"working","session_name":"tmux-a","health":"normal","status":"working","rows":40,"cols":100}]}]}}"#.utf8)
        guard case let .listing(listing) = try JSONV1Codec().decodeControlMessage(json) else {
            return XCTFail("Expected listing")
        }
        XCTAssertEqual(listing.requestID, 7)
        XCTAssertEqual(listing.sequence, 42)
        let workspace = try XCTUnwrap(listing.workspaces.first)
        XCTAssertEqual(workspace.workingCount, 1)
        XCTAssertEqual(workspace.aggregateState, .working)
        let session = try XCTUnwrap(workspace.sessions.first)
        XCTAssertEqual(session.reference.rawValue, "socket\u{1F}%1")
        XCTAssertEqual(session.windowName, "Codex task")
        XCTAssertEqual(session.windowIndex, "3")
        XCTAssertEqual(session.title, "Exact OSC title")
        XCTAssertEqual(session.sessionName, "tmux-a")
        XCTAssertEqual(session.provider, "codex")
        XCTAssertEqual(session.activity, "working")
        XCTAssertEqual(session.health, "normal")
        XCTAssertEqual(session.status, "working")
        XCTAssertEqual(session.state, .working)

        let encoded = try JSONEncoder().encode(listing)
        let encodedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(encodedObject["req_id"] as? Int, 7)
        XCTAssertEqual(encodedObject["seq"] as? Int, 42)
        let encodedWorkspace = try XCTUnwrap((encodedObject["workspaces"] as? [[String: Any]])?.first)
        XCTAssertEqual(encodedWorkspace["working_count"] as? Int, 1)
        let encodedSession = try XCTUnwrap((encodedWorkspace["sessions"] as? [[String: Any]])?.first)
        XCTAssertEqual(encodedSession["window_name"] as? String, "Codex task")
        XCTAssertEqual(encodedSession["session_name"] as? String, "tmux-a")
        XCTAssertNil(encodedSession["state"]) // agentmirrord sends activity/status, not the legacy state alias.
        let roundTrip = try JSONDecoder().decode(SessionListing.self, from: encoded)
        XCTAssertEqual(roundTrip, listing)

        let delta = SessionListDelta(sequence: 43, addedSessions: [session], removedReferences: [try SessionReference("old-ref")])
        let deltaData = try JSONEncoder().encode(delta)
        let deltaObject = try XCTUnwrap(JSONSerialization.jsonObject(with: deltaData) as? [String: Any])
        XCTAssertEqual(deltaObject["seq"] as? Int, 43)
        XCTAssertEqual(deltaObject["removed_refs"] as? [String], ["old-ref"])
        XCTAssertEqual(try JSONDecoder().decode(SessionListDelta.self, from: deltaData), delta)
    }

    func testPairingAndUploadHTTPJSONModels() throws {
        let codec = AgentMirrorHTTPCodec()
        let whoami = try codec.decodeWhoAmIResponse(Data(#"{"v":1,"host_id":"host-a","name":"devbox","port":9919,"addresses":["10.0.0.5"]}"#.utf8))
        XCTAssertEqual(whoami, AgentMirrorWhoAmIResponse(hostID: "host-a", name: "devbox", port: 9919, addresses: ["10.0.0.5"]))

        let request = AgentMirrorIdentifyRequest(hostID: "host-a", nonce: "0123456789abcdef0123456789abcdef", destinationIP: "10.0.0.5")
        let requestJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: codec.encodeIdentifyRequest(request)) as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: requestJSON).isEqual(to: ["v": 1, "host_id": "host-a", "nonce": request.nonce, "dest_ip": "10.0.0.5"]))

        let identity = try codec.decodeIdentifyResponse(Data(#"{"v":1,"host_id":"host-a","name":"devbox","bound":"10.0.0.5:9919","mac":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}"#.utf8))
        XCTAssertEqual(identity.bound, "10.0.0.5:9919")
        XCTAssertEqual(identity.mac.count, 64)
        XCTAssertEqual(try codec.decodeUploadResponse(Data(#"{"path":"/tmp/agentmirror-uploads/1.png"}"#.utf8)), AgentMirrorUploadResponse(path: "/tmp/agentmirror-uploads/1.png"))
        XCTAssertEqual(try codec.decodeError(Data(#"{"code":"upload_write_failed","reason":"upload write failed"}"#.utf8)), AgentMirrorHTTPError(code: "upload_write_failed", reason: "upload write failed"))
        let upload = AgentMirrorUploadRequest(fileName: "image.png", bytes: Data([0x89, 0x50]))
        XCTAssertEqual(upload.fileName, "image.png")
        XCTAssertEqual(upload.bytes, Data([0x89, 0x50]))
        XCTAssertThrowsError(try codec.encodeIdentifyRequest(AgentMirrorIdentifyRequest(nonce: "NOT-LOWERCASE-HEX", destinationIP: "10.0.0.5")))
        XCTAssertThrowsError(try codec.encodeIdentifyRequest(AgentMirrorIdentifyRequest(nonce: "0123456789abcdef0123456789abcdef", destinationIP: "127.0.0.1")))
        XCTAssertThrowsError(try codec.decodeUploadResponse(Data(#"{"path":"relative.png"}"#.utf8)))
    }

    func testLevel2OverlayAndPresenceMessagesMatchServerTypes() throws {
        let codec = JSONV1Codec()
        let l2 = try XCTUnwrap(JSONSerialization.jsonObject(with: codec.encodeClientCommand(.level2Subscribe(workspace: "/workspace"))) as? [String: Any])
        XCTAssertEqual(l2["type"] as? String, "level2_subscribe")
        XCTAssertEqual(l2["payload"] as? [String: String], ["workspace": "/workspace"])

        let l2Stop = try XCTUnwrap(JSONSerialization.jsonObject(with: codec.encodeClientCommand(.level2Unsubscribe(workspace: nil))) as? [String: Any])
        XCTAssertEqual(l2Stop["type"] as? String, "level2_unsubscribe")
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(l2Stop["payload"] as? [String: Any])).isEqual(to: [:]))

        let overlay = try XCTUnwrap(JSONSerialization.jsonObject(with: codec.encodeClientCommand(.overlaySubscribe(socket: "/tmp/tmux.sock", rows: 24, columns: 80))) as? [String: Any])
        XCTAssertEqual(overlay["type"] as? String, "overlay_subscribe")
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(overlay["payload"] as? [String: Any])).isEqual(to: ["socket": "/tmp/tmux.sock", "rows": 24, "cols": 80]))
        let overlayStop = try XCTUnwrap(JSONSerialization.jsonObject(with: codec.encodeClientCommand(.overlayUnsubscribe)) as? [String: Any])
        XCTAssertEqual(overlayStop["type"] as? String, "overlay_unsubscribe")
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(overlayStop["payload"] as? [String: Any])).isEqual(to: [:]))

        let presence = Data(#"{"v":1,"type":"presence_update","payload":{"ref":"s1","has_mobile":true,"mobile_count":1,"desktop_count":2}}"#.utf8)
        XCTAssertEqual(try codec.decodeControlMessage(presence), .presenceUpdate(reference: try SessionReference("s1"), hasMobile: true, mobileCount: 1, desktopCount: 2))
        XCTAssertThrowsError(try codec.decodeControlMessage(Data(#"{"v":1,"type":"presence_update","payload":{"ref":"s1","has_mobile":false,"mobile_count":1,"desktop_count":0}}"#.utf8)))

        let session = #"{"ref":"s1","name":"worker","window_name":"worker","window_index":"0","cwd":"/workspace","title":"title","provider":"codex","activity":"working","health":"normal","status":"working","rows":24,"cols":80}"#
        let frame = Data("{\"v\":1,\"type\":\"level2_frame\",\"payload\":{\"workspace\":\"/workspace\",\"seq\":4,\"sessions\":[\(session)]}}".utf8)
        guard case let .level2Frame(workspace, sequence, sessions) = try codec.decodeControlMessage(frame) else {
            return XCTFail("Expected level2_frame")
        }
        XCTAssertEqual(workspace, "/workspace")
        XCTAssertEqual(sequence, 4)
        XCTAssertEqual(sessions.first?.provider, "codex")
        XCTAssertEqual(try codec.decodeControlMessage(Data(#"{"v":1,"type":"level2_heartbeat","payload":{"workspace":"/workspace","seq":5}}"#.utf8)), .level2Heartbeat(workspace: "/workspace", sequence: 5))
        XCTAssertEqual(try codec.decodeControlMessage(Data(#"{"v":1,"type":"overlay_frame","payload":{"seq":6,"text":"main\n1 session","rows":24,"cols":80}}"#.utf8)), .overlayFrame(sequence: 6, text: "main\n1 session", rows: 24, columns: 80))
        XCTAssertThrowsError(try codec.decodeControlMessage(Data(#"{"v":1,"type":"overlay_frame","payload":{"seq":0,"text":""}}"#.utf8)))
    }

    func testSessionReferencesEnforceUTF8ByteLimit() throws {
        XCTAssertThrowsError(try SessionReference(""))
        XCTAssertNoThrow(try SessionReference(String(repeating: "界", count: 85)))
        XCTAssertThrowsError(try SessionReference(String(repeating: "界", count: 86)))
    }

    private func goldenFrames() throws -> [String: Any] {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/golden-frames.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        XCTAssertEqual(fixture["protocol_version"] as? Int, 1)
        return fixture
    }

    private func capturedBytes(_ fixture: [String: Any]) throws -> Data {
        let base64 = try XCTUnwrap(fixture["raw_base64"] as? String)
        let bytes = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertEqual(bytes.count, fixture["byte_length"] as? Int)
        XCTAssertEqual(bytes, try data(fromHex: XCTUnwrap(fixture["raw_hex"] as? String)))
        return bytes
    }

    private func data(fromHex hex: String) throws -> Data {
        guard hex.count.isMultiple(of: 2) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "odd-length hex in golden fixture"))
        }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "invalid hex in golden fixture"))
            }
            bytes.append(byte)
            index = end
        }
        return Data(bytes)
    }
}
