import CorralContracts
import CorralProtocol
import Foundation
import XCTest

final class BinaryV1CodecTests: XCTestCase {
    func testRoundTripsProtocolV1Frame() throws {
        let codec = BinaryV1Codec()
        let frame = BinaryFrame(kind: .delta, reference: "session-α", payload: Data([0x1B, 0x5B, 0x31]))
        let encoded = try codec.encodeBinaryFrame(frame)

        XCTAssertEqual(Array(encoded.prefix(5)), [0x52, 0x41, 0x01, 0x02, UInt8("session-α".utf8.count)])
        XCTAssertEqual(try codec.decodeBinaryFrame(encoded), frame)
    }

    func testRejectsBadHeaderAndOversizedReference() throws {
        let codec = BinaryV1Codec()
        XCTAssertThrowsError(try codec.decodeBinaryFrame(Data([0, 0, 1, 1, 0]))) {
            XCTAssertEqual($0 as? ProtocolContractError, .invalidMagic)
        }
        XCTAssertThrowsError(try codec.encodeBinaryFrame(BinaryFrame(kind: .snapshot, reference: String(repeating: "x", count: 256), payload: Data()))) {
            XCTAssertEqual($0 as? ProtocolContractError, .referenceTooLong)
        }
    }

    func testInputControlMessageUsesUserBytesType() {
        let message = ControlMessage.input(sessionID: SessionID("session-a"), bytes: UserInputBytes(Data([0x61])))
        guard case let .input(_, bytes) = message else { return XCTFail("Expected typed user input") }
        XCTAssertEqual(bytes.data, Data([0x61]))
    }
}
