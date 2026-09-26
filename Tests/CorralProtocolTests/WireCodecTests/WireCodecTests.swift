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
