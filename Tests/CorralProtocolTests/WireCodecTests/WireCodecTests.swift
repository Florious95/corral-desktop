import CorralContracts
import CorralProtocol
import Foundation
import XCTest

final class WireCodecTests: XCTestCase {
    private let codec = BinaryV1Codec()

    func testBinaryGoldenVectorsRoundTripEveryKindAndPreservePayloadBytes() throws {
        let reference = "pty-🧪-多字符"
        let payload = Data((0...255).map(UInt8.init))
        let expectedReference = Array(reference.utf8)

        for kind in FrameKind.allCases {
            let frame = BinaryFrame(kind: kind, reference: reference, payload: payload)
            let encoded = try codec.encodeBinaryFrame(frame)
            XCTAssertEqual(Array(encoded.prefix(5)), [0x52, 0x41, 0x01, kind.rawValue, UInt8(expectedReference.count)])
            XCTAssertEqual(Array(encoded.dropFirst(5).prefix(expectedReference.count)), expectedReference)
            XCTAssertEqual(try codec.decodeBinaryFrame(encoded), frame)
        }
    }

    func testBinaryReferenceLimitUsesUTF8ByteCount() throws {
        let limitFrame = BinaryFrame(kind: .snapshot, reference: String(repeating: "a", count: 255), payload: Data([0]))
        XCTAssertEqual(try codec.decodeBinaryFrame(codec.encodeBinaryFrame(limitFrame)), limitFrame)

        let overlongUTF8 = BinaryFrame(kind: .delta, reference: String(repeating: "界", count: 86), payload: Data([0]))
        XCTAssertThrowsError(try codec.encodeBinaryFrame(overlongUTF8)) {
            XCTAssertEqual($0 as? ProtocolContractError, .referenceTooLong)
        }
        XCTAssertThrowsError(try codec.encodeBinaryFrame(BinaryFrame(kind: .snapshot, reference: "", payload: Data([0])))) {
            XCTAssertEqual($0 as? ProtocolContractError, .invalidReference)
        }
    }

    func testBinaryDecoderRejectsCorruptAndTruncatedFrames() throws {
        let cases: [(Data, ProtocolContractError)] = [
            (Data([0x00, 0x41, 0x01, 0x01, 0x01, 0x61, 0x00]), .invalidMagic),
            (Data([0x52, 0x41, 0x02, 0x01, 0x01, 0x61, 0x00]), .unsupportedVersion(0x02)),
            (Data([0x52, 0x41, 0x01, 0x7f, 0x01, 0x61, 0x00]), .unknownFrameKind(0x7f)),
            (Data([0x52, 0x41]), .truncatedFrame),
            (Data([0x52, 0x41, 0x01, 0x01, 0x02, 0x61]), .truncatedFrame),
            (Data([0x52, 0x41, 0x01, 0x01, 0x01, 0xff, 0x00]), .invalidReference),
            (Data([0x52, 0x41, 0x01, 0x01, 0x01, 0x61]), .truncatedFrame)
        ]

        for (bytes, expectedError) in cases {
            XCTAssertThrowsError(try codec.decodeBinaryFrame(bytes)) {
                XCTAssertEqual($0 as? ProtocolContractError, expectedError)
            }
        }
    }

    func testBinaryCodecRejectsEmptyAndOversizedPayloads() throws {
        let headerWithoutPayload = Data([0x52, 0x41, 0x01, 0x01, 0x01, 0x61])
        XCTAssertThrowsError(try codec.decodeBinaryFrame(headerWithoutPayload)) {
            XCTAssertEqual($0 as? ProtocolContractError, .truncatedFrame)
        }
        XCTAssertThrowsError(try codec.encodeBinaryFrame(BinaryFrame(kind: .snapshot, reference: "a", payload: Data()))) {
            XCTAssertEqual($0 as? ProtocolContractError, .truncatedFrame)
        }

        let oversized = Data(repeating: 0xA5, count: ProtocolV1.maximumTerminalPayloadBytes + 1)
        XCTAssertThrowsError(try codec.encodeBinaryFrame(BinaryFrame(kind: .delta, reference: "a", payload: oversized))) {
            XCTAssertEqual($0 as? ProtocolContractError, .payloadTooLarge)
        }
        var encodedOversized = Data([0x52, 0x41, 0x01, 0x01, 0x01, 0x61])
        encodedOversized.append(oversized)
        XCTAssertThrowsError(try codec.decodeBinaryFrame(encodedOversized)) {
            XCTAssertEqual($0 as? ProtocolContractError, .payloadTooLarge)
        }
    }

    func testControlJSONMatchesWireEnvelopeGoldenShapes() throws {
        let session = SessionDescriptor(id: SessionID("term-1"), deviceID: DeviceID("device-1"), name: "shell", workingDirectory: "/tmp", state: .running)
        let golden: [(ControlMessage, [String: Any])] = [
            (.auth(credential: CredentialHandle("opaque-token")), ["type": "auth", "token": "opaque-token"]),
            (.authAck(accepted: true), ["type": "auth_ack", "success": true]),
            (.subscribe(sessionID: SessionID("term-1"), initialSize: nil), ["type": "subscribe", "session_id": "term-1"]),
            (.subscribe(sessionID: SessionID("term-1"), initialSize: GridSize(rows: 24, columns: 80)), ["type": "subscribe", "session_id": "term-1", "cols": 80, "rows": 24]),
            (.unsubscribe(sessionID: SessionID("term-1")), ["type": "unsubscribe", "session_id": "term-1"]),
            (.input(sessionID: SessionID("term-1"), bytes: UserInputBytes(Data([0x00, 0xFF]))), ["type": "input", "session_id": "term-1", "data": "AP8="]),
            (.resize(sessionID: SessionID("term-1"), size: GridSize(rows: 24, columns: 80)), ["type": "resize", "session_id": "term-1", "cols": 80, "rows": 24]),
            (.ping(nonce: 0), ["type": "ping"]),
            (.pong(nonce: 0), ["type": "pong"]),
            (.sessionList(requestID: 0), ["type": "list"]),
            (.sessionListResult(requestID: 0, sessions: [session]), ["type": "listing", "sessions": [["id": "term-1", "device_id": "device-1", "name": "shell", "working_directory": "/tmp", "state": "running"]]])
        ]

        for (message, expected) in golden {
            let encoded = try codec.encodeControlMessage(message)
            let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertTrue(NSDictionary(dictionary: actual).isEqual(to: expected), "Unexpected JSON for \(message)")
            XCTAssertEqual(try codec.decodeControlMessage(from: encoded), message)
        }

        let inputAck = try codec.decodeControlMessage(from: Data(#"{"type":"auth_ack","success":false}"#.utf8))
        XCTAssertEqual(inputAck, .authAck(accepted: false))
        XCTAssertEqual(try codec.decodeControlMessage(from: Data(#"{"type":"pong"}"#.utf8)), .pong(nonce: 0))
    }

    func testControlJSONRoundTripsAllContractCases() throws {
        let session = SessionDescriptor(
            id: SessionID("term-1"),
            deviceID: DeviceID("device-1"),
            name: "shell",
            workingDirectory: "/tmp",
            state: .running
        )
        let messages: [ControlMessage] = [
            .auth(credential: CredentialHandle("token")),
            .authAck(accepted: false),
            .subscribe(sessionID: SessionID("term-1"), initialSize: nil),
            .subscribe(sessionID: SessionID("term-1"), initialSize: GridSize(rows: 40, columns: 120)),
            .unsubscribe(sessionID: SessionID("term-1")),
            .input(sessionID: SessionID("term-1"), bytes: UserInputBytes(Data([0, 0x1B, 0xFF]))),
            .resize(sessionID: SessionID("term-1"), size: GridSize(rows: 40, columns: 120)),
            .ping(nonce: 123),
            .pong(nonce: 456),
            .sessionList(requestID: 9),
            .sessionListResult(requestID: 10, sessions: [session]),
            .createSession(requestID: 11, deviceID: DeviceID("device-1"), name: "zsh", workingDirectory: nil),
            .createSessionResult(requestID: 12, session: session),
            .createSessionResult(requestID: 13, session: nil),
            .failure(code: "denied", message: "not authorized")
        ]

        for message in messages {
            XCTAssertEqual(try codec.decodeControlMessage(from: codec.encodeControlMessage(message)), message)
        }
    }

    func testControlJSONRejectsUnknownTypesAndMalformedRequiredFields() {
        let malformed: [String] = [
            #"{"type":"unknown"}"#,
            #"{"type":"auth"}"#,
            #"{"type":"subscribe","session_id":"term-1","cols":80}"#,
            #"{"type":"input","session_id":"term-1","data":"%%%"}"#,
            #"{"type":"resize","session_id":"term-1","cols":"wide","rows":24}"#,
            #"{"type":"failure","code":"denied"}"#,
            #"{"type":"listing"}"#
        ]
        for json in malformed {
            XCTAssertThrowsError(try codec.decodeControlMessage(from: Data(json.utf8)))
        }
    }
}
