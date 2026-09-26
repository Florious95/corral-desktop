import CorralContracts
import CorralProtocol
import Foundation
import XCTest

final class BinaryV1CodecTests: XCTestCase {
    func testRoundTripsProtocolV1Frame() throws {
        let codec = BinaryV1Codec()
        let reference = try SessionReference("session-α")
        let frame = BinaryFrame.delta(reference: reference, ansi: Data([0x1B, 0x5B, 0x31]))
        let encoded = try codec.encodeBinaryFrame(frame)

        XCTAssertEqual(Array(encoded.prefix(5)), [0x52, 0x41, 0x01, 0x02, UInt8(reference.rawValue.utf8.count)])
        XCTAssertEqual(try codec.decodeBinaryFrame(encoded), frame)
    }

    func testScrollbackMetadataIsParsedAndRemovedFromAnsi() throws {
        let codec = BinaryV1Codec()
        let reference = try SessionReference("s1")
        let metadata = try ScrollbackMetadata(requestID: 7, fromLine: -50, lineCount: 50)
        let frame = BinaryFrame.scrollback(reference: reference, metadata: metadata, ansi: Data("A".utf8))
        let encoded = try codec.encodeBinaryFrame(frame)
        let decoded = try codec.decodeBinaryFrame(encoded)

        XCTAssertEqual(decoded, frame)
        XCTAssertEqual(Array(encoded.suffix(13)), [0, 0, 0, 7, 0xFF, 0xFF, 0xFF, 0xCE, 0, 0, 0, 50, 0x41])
    }

    func testScrollbackAcceptsOneMiBAnsiPlusMetadataAndRefusesBadFrames() throws {
        let codec = BinaryV1Codec()
        let reference = try SessionReference("s1")
        let metadata = try ScrollbackMetadata(requestID: 1, fromLine: Int32.min, lineCount: 1)
        let maximumANSI = Data(repeating: 0x41, count: ProtocolV1.maximumANSIBytes)
        let valid = try codec.encodeBinaryFrame(.scrollback(reference: reference, metadata: metadata, ansi: maximumANSI))
        XCTAssertEqual(try codec.decodeBinaryFrame(valid).ansi.count, ProtocolV1.maximumANSIBytes)

        let emptyReference = Data([0x52, 0x41, 1, 2, 0, 0x41])
        XCTAssertThrowsError(try codec.decodeBinaryFrame(emptyReference)) {
            XCTAssertEqual($0 as? ProtocolContractError, .invalidReference)
        }
        let shortHistory = Data([0x52, 0x41, 1, 3, 1, 0x73])
        XCTAssertThrowsError(try codec.decodeBinaryFrame(shortHistory)) {
            XCTAssertEqual($0 as? ProtocolContractError, .truncatedFrame)
        }
        let zeroMetadata = Data([0x52, 0x41, 1, 3, 1, 0x73] + Array(repeating: 0, count: 12))
        XCTAssertThrowsError(try codec.decodeBinaryFrame(zeroMetadata)) {
            XCTAssertEqual($0 as? ProtocolContractError, .invalidScrollbackMetadata)
        }
    }

    func testV1JSONUsesExplicitEnvelopeAndPreservesListingSequenceAndGroups() throws {
        let codec = JSONV1Codec()
        let request = try codec.encodeClientCommand(.list(requestID: 7))
        let requestObject = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        XCTAssertEqual(requestObject["v"] as? Int, 1)
        XCTAssertEqual(requestObject["type"] as? String, "list")
        XCTAssertEqual((requestObject["payload"] as? [String: Any])?["req_id"] as? Int, 7)

        let listingJSON = Data(#"{"v":1,"type":"listing","payload":{"req_id":7,"seq":42,"workspaces":[{"cwd":"/proj/a","session_count":1,"aggregate_state":"working","sessions":[{"ref":"s1","name":"claude","cwd":"/proj/a","state":"working","rows":40,"cols":100}]}]}}"#.utf8)
        guard case let .listing(listing) = try codec.decodeControlMessage(listingJSON) else {
            return XCTFail("Expected a listing control message")
        }
        XCTAssertEqual(listing.requestID, 7)
        XCTAssertEqual(listing.sequence, 42)
        XCTAssertEqual(listing.workspaces.first?.sessions.first?.reference.rawValue, "s1")
    }

    func testInputAckUsesUInt32RequestCorrelationAndRejectsOverflow() throws {
        let codec = JSONV1Codec()
        let ack = Data(#"{"v":1,"type":"input_ack","payload":{"req_id":9,"ok":false,"reason":"inject_failed"}}"#.utf8)
        guard case let .inputAck(seq, ok, reason) = try codec.decodeControlMessage(ack) else {
            return XCTFail("Expected input_ack")
        }
        XCTAssertEqual(seq, 9)
        XCTAssertFalse(ok)
        XCTAssertEqual(reason, .injectFailed)

        let overflow = Data(#"{"v":1,"type":"listing","payload":{"req_id":4294967296,"seq":1,"workspaces":[]}}"#.utf8)
        XCTAssertThrowsError(try codec.decodeControlMessage(overflow))
        XCTAssertThrowsError(try codec.decodeControlMessage(Data(#"{"v":2,"type":"input_ack","payload":{"req_id":1,"ok":true}}"#.utf8))) {
            XCTAssertEqual($0 as? V1ControlCodecError, .unsupportedVersion(2))
        }
        XCTAssertThrowsError(try codec.decodeControlMessage(Data(#"{"v":1,"type":"future_type","payload":{}}"#.utf8))) {
            XCTAssertEqual($0 as? V1ControlCodecError, .unknownType("future_type"))
        }
    }

    func testUserInputEncodingIsDirectionTypedAndMatchesV1Payload() throws {
        let codec = JSONV1Codec()
        let reference = try SessionReference("s1")
        let request = try ClientInputRequest(sequence: 10, reference: reference, payload: .keys([.escape, .controlC, .tab]))
        let data = try codec.encodeClientCommand(.input(request))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(envelope["type"] as? String, "input")
        let payload = try XCTUnwrap(envelope["payload"] as? [String: Any])
        XCTAssertEqual(payload["req_id"] as? Int, 10)
        XCTAssertEqual(payload["ref"] as? String, "s1")
        XCTAssertEqual(payload["keys"] as? [String], ["esc", "ctrl_c", "tab"])
        let textRequest = try ClientInputRequest(sequence: 11, reference: reference, payload: .text("héllo", attachmentPath: nil))
        let textData = try codec.encodeClientCommand(.input(textRequest))
        let textEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: textData) as? [String: Any])
        let textPayload = try XCTUnwrap(textEnvelope["payload"] as? [String: Any])
        XCTAssertEqual(textPayload["text"] as? String, "héllo")
        XCTAssertNil(textPayload["bytes_b64"])
        XCTAssertThrowsError(try codec.encodeClientCommand(.createSession(requestID: 1, deviceID: DeviceID("dev"), name: "shell", workingDirectory: nil)))
    }

    func testReceiveEnvelopeCarriesConnectionGenerationAndLocalOrdinal() throws {
        let origin = SessionEventOrigin(
            linkInstanceID: LinkInstanceID(UUID()),
            deviceID: DeviceID("device-a"),
            connectionEpoch: ConnectionEpoch(4),
            receiveOrdinal: ReceiveOrdinal(9)
        )
        let frame = BinaryFrame.delta(reference: try SessionReference("s1"), ansi: Data([0x41]))
        let event = try SessionEventEnvelope(origin: origin, wireByteCount: 7, event: .frame(frame))
        XCTAssertEqual(event.origin.connectionEpoch.rawValue, 4)
        XCTAssertEqual(event.origin.receiveOrdinal.rawValue, 9)
        XCTAssertEqual(event.wireByteCount, 7)
        let connection = try AuthenticatedConnection(linkInstanceID: origin.linkInstanceID, deviceID: origin.deviceID, connectionEpoch: origin.connectionEpoch)
        XCTAssertTrue(origin.belongs(to: connection))
        let reconnected = try AuthenticatedConnection(linkInstanceID: origin.linkInstanceID, deviceID: origin.deviceID, connectionEpoch: ConnectionEpoch(5))
        XCTAssertFalse(origin.belongs(to: reconnected))
        XCTAssertTrue(SessionEventStreamBudget(maximumBufferedBytes: 1024, maximumBufferedEvents: 8, maximumBufferedControls: 4).isValid)
        XCTAssertFalse(SessionEventStreamBudget(maximumBufferedBytes: 0, maximumBufferedEvents: 8, maximumBufferedControls: 4).isValid)
    }
}
