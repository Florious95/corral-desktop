import CorralContracts
import CorralMetalTerminal
import CorralProtocol
import Foundation
import XCTest

final class TerminalEngineTests: XCTestCase {
    private let linkInstanceID = LinkInstanceID()

    func testParsesSGRColorsAttributesAndCursorModes() async throws {
        let engine = SwiftTermEngineAdapter(size: GridSize(rows: 2, columns: 8))
        _ = try await feed("\u{1B}[1;3;4;7;38;2;1;2;3mX\u{1B}[3 q\u{1B}[?25l", to: engine)

        let snapshot = await engine.snapshot()
        let cell = snapshot.cells[0]
        XCTAssertEqual(cell.content, .cluster("X", columns: .one))
        XCTAssertEqual(cell.foreground, .rgba(RGBAColor(red: 1, green: 2, blue: 3)))
        XCTAssertTrue(cell.attributes.contains(.bold))
        XCTAssertTrue(cell.attributes.contains(.italic))
        XCTAssertTrue(cell.attributes.contains(.underline))
        XCTAssertTrue(cell.attributes.contains(.inverse))
        XCTAssertEqual(snapshot.cursor.shape, .underline)
        XCTAssertFalse(snapshot.cursor.isVisible)
        XCTAssertTrue(snapshot.isValid)
    }

    func testUsesTmuxCompatibleWideCellsForCJKEmojiZWJAndBoxDrawing() async throws {
        let engine = SwiftTermEngineAdapter(size: GridSize(rows: 1, columns: 12))
        _ = try await feed("A界🙂👩‍💻─", to: engine)

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.cells[0].content, .cluster("A", columns: .one))
        XCTAssertEqual(snapshot.cells[1].content, .cluster("界", columns: .two))
        XCTAssertEqual(snapshot.cells[2].content, .continuation)
        XCTAssertEqual(snapshot.cells[3].content, .cluster("🙂", columns: .two))
        XCTAssertEqual(snapshot.cells[4].content, .continuation)
        XCTAssertEqual(snapshot.cells[5].content, .cluster("👩‍💻", columns: .two))
        XCTAssertEqual(snapshot.cells[6].content, .continuation)
        XCTAssertEqual(snapshot.cells[7].content, .cluster("─", columns: .one))
        XCTAssertEqual(snapshot.cursor.column, 8)
        XCTAssertTrue(snapshot.isValid)
    }

    func testCapturedGoldenSnapshotAndDeltaFollowVTScrolling() async throws {
        let codec = BinaryV1Codec()
        let snapshotFrame = try capturedFrame("snapshot", codec: codec)
        let deltaFrame = try capturedFrame("delta", codec: codec)
        XCTAssertEqual(snapshotFrame.kind, .snapshot)
        XCTAssertEqual(deltaFrame.kind, .delta)
        XCTAssertEqual(snapshotFrame.reference, deltaFrame.reference)

        let engine = SwiftTermEngineAdapter(size: GridSize(rows: 24, columns: 80))
        _ = try await engine.apply(.snapshot(reference: snapshotFrame.reference, ansi: snapshotFrame.ansi, origin: origin(1)))

        let afterSnapshot = await engine.snapshot()
        XCTAssertTrue(afterSnapshot.isValid)
        XCTAssertEqual(afterSnapshot.size, GridSize(rows: 24, columns: 80))
        XCTAssertEqual(textRows(in: afterSnapshot).filter { !$0.isEmpty }, (15...37).map { expectedRow($0) })
        XCTAssertEqual(afterSnapshot.cursor.row, 23)
        XCTAssertEqual(afterSnapshot.cursor.column, 0)
        assertGoldenGlyphsAndColor(in: afterSnapshot)

        _ = try await engine.apply(.delta(reference: deltaFrame.reference, ansi: deltaFrame.ansi, origin: origin(1)))
        let afterDelta = await engine.snapshot()
        XCTAssertTrue(afterDelta.isValid)
        XCTAssertEqual(textRows(in: afterDelta).filter { !$0.isEmpty }, (16...38).map { expectedRow($0) })
        XCTAssertEqual(textRows(in: afterDelta)[23], "")
        XCTAssertEqual(afterDelta.cursor.row, 23)
        XCTAssertEqual(afterDelta.cursor.column, 0)
        assertGoldenGlyphsAndColor(in: afterDelta)
    }

    func testRightEdgeWrapPendingAndFollowingCharacterStayValid() async throws {
        let engine = SwiftTermEngineAdapter(size: GridSize(rows: 2, columns: 7))
        _ = try await feed("ABCDEFG", to: engine)

        let edge = await engine.snapshot()
        XCTAssertTrue(edge.isValid)
        XCTAssertEqual(edge.cursor.column, 6)
        XCTAssertTrue(edge.cursor.wrapPending)

        _ = try await feed("H", to: engine)
        let wrapped = await engine.snapshot()
        XCTAssertTrue(wrapped.isValid)
        XCTAssertEqual(wrapped.cells[7].content, .cluster("H", columns: .one))
        XCTAssertEqual(wrapped.cursor.row, 1)
        XCTAssertEqual(wrapped.cursor.column, 1)
        XCTAssertFalse(wrapped.cursor.wrapPending)
    }

    func testRightEdgeDSRAndDAKeepSnapshotValid() async throws {
        let engine = SwiftTermEngineAdapter(size: GridSize(rows: 2, columns: 7))
        _ = try await feed("ABCDEFG", to: engine)
        let effects = try await feed("\u{1B}[6n\u{1B}[c", to: engine)
        XCTAssertTrue(effects.contains { if case .autoReply = $0 { true } else { false } })

        let snapshot = await engine.snapshot()
        XCTAssertTrue(snapshot.isValid)
        XCTAssertEqual(snapshot.cursor.column, 6)
        XCTAssertTrue(snapshot.cursor.wrapPending)
    }

    func testSnapshotsStayValidAcrossRepeatedNarrowGridWraps() async throws {
        let engine = SwiftTermEngineAdapter(size: GridSize(rows: 2, columns: 7))
        for character in "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
            _ = try await feed(String(character), to: engine)
            let snapshot = await engine.snapshot()
            XCTAssertTrue(snapshot.isValid, "invalid after \(character)")
        }
    }

    func testWideCellContinuationInheritsLeadingVisualAttributes() async throws {
        let engine = SwiftTermEngineAdapter(size: GridSize(rows: 1, columns: 4))
        _ = try await feed("\u{1B}[1;3;4;7;38;2;1;2;3;48;2;4;5;6m界", to: engine)

        let snapshot = await engine.snapshot()
        let leading = snapshot.cells[0]
        let continuation = snapshot.cells[1]
        XCTAssertEqual(leading.content, .cluster("界", columns: .two))
        XCTAssertEqual(continuation.content, .continuation)
        XCTAssertEqual(continuation.foreground, leading.foreground)
        XCTAssertEqual(continuation.background, leading.background)
        XCTAssertEqual(continuation.attributes, leading.attributes)
        XCTAssertEqual(leading.foreground, .rgba(RGBAColor(red: 1, green: 2, blue: 3)))
        XCTAssertEqual(leading.background, .rgba(RGBAColor(red: 4, green: 5, blue: 6)))
        XCTAssertTrue(leading.attributes.contains(.bold))
        XCTAssertTrue(leading.attributes.contains(.italic))
        XCTAssertTrue(leading.attributes.contains(.underline))
        XCTAssertTrue(leading.attributes.contains(.inverse))
        XCTAssertTrue(snapshot.isValid)
    }

    func testParsesCSIAndUTF8AcrossFrameBoundaries() async throws {
        let engine = SwiftTermEngineAdapter(size: GridSize(rows: 1, columns: 4))
        _ = try await engine.apply(.delta(reference: reference(), ansi: Data([0x1B, 0x5B, 0x33, 0x38, 0x3B, 0x35, 0x3B]), origin: origin(1)))
        _ = try await engine.apply(.delta(reference: reference(), ansi: Data([0x32, 0x30, 0x31, 0x6D, 0xE7]), origin: origin(1)))
        _ = try await engine.apply(.delta(reference: reference(), ansi: Data([0x95, 0x8C]), origin: origin(1)))

        let snapshot = await engine.snapshot()
        let cell = snapshot.cells[0]
        XCTAssertEqual(cell.content, .cluster("界", columns: .two))
        XCTAssertEqual(cell.foreground, .indexed(201))
        XCTAssertEqual(snapshot.cells[1].content, .continuation)
    }

    func testAlternateScreenAndMouseReportModesFollowVTState() async throws {
        let engine = SwiftTermEngineAdapter(size: GridSize(rows: 2, columns: 8))
        _ = try await feed("main", to: engine)
        _ = try await feed("\u{1B}[?1049h\u{1B}[HALT\u{1B}[?1003h", to: engine)
        let alternate = await engine.snapshot()
        let mouseMode = await engine.mouseReportingMode()
        XCTAssertEqual(alternate.cells[0].content, .cluster("A", columns: .one))
        XCTAssertEqual(mouseMode, .anyEvent)

        _ = try await feed("\u{1B}[?1049l", to: engine)
        let restored = await engine.snapshot()
        XCTAssertEqual(restored.cells[0].content, .cluster("m", columns: .one))
    }

    func testTerminalQueriesReturnOnlyTypedLocalAutoReplyEffects() async throws {
        let engine = SwiftTermEngineAdapter(size: GridSize(rows: 2, columns: 8))
        let effects = try await feed("\u{1B}[5n\u{1B}[6n\u{1B}[c\u{1B}[?6n", to: engine)
        let replies = effects.compactMap { effect -> TerminalAutoReplyBytes? in
            guard case let .autoReply(bytes) = effect else { return nil }
            return bytes
        }
        XCTAssertFalse(replies.isEmpty)
        XCTAssertEqual(replies.count, effects.count)
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.cells[0].content, .blank)
    }

    func testSnapshotIsAnImmutableCopyAndOlderEpochsAreIgnored() async throws {
        let engine = SwiftTermEngineAdapter(size: GridSize(rows: 1, columns: 4))
        _ = try await engine.apply(.snapshot(reference: reference(), ansi: Data("A".utf8), origin: origin(1)))
        let first = await engine.snapshot()
        _ = try await engine.apply(.delta(reference: reference(), ansi: Data("B".utf8), origin: origin(1)))
        let second = await engine.snapshot()
        XCTAssertEqual(first.cells[0].content, .cluster("A", columns: .one))
        XCTAssertEqual(second.cells[1].content, .cluster("B", columns: .one))

        _ = try await engine.apply(.delta(reference: reference(), ansi: Data("Z".utf8), origin: origin(0)))
        let afterOldEpoch = await engine.snapshot()
        XCTAssertEqual(afterOldEpoch.cells[2].content, .blank)
    }

    private func feed(_ text: String, to engine: SwiftTermEngineAdapter) async throws -> [TerminalEffect] {
        try await engine.apply(.delta(reference: reference(), ansi: Data(text.utf8), origin: origin(1)))
    }

    private func capturedFrame(_ name: String, codec: BinaryV1Codec) throws -> BinaryFrame {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TestSupport/Fixtures/golden-frames.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let frames = try XCTUnwrap(fixture["frames"] as? [String: [String: Any]])
        let frame = try XCTUnwrap(frames[name])
        let encoded = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(frame["raw_base64"] as? String)))
        return try codec.decodeBinaryFrame(encoded)
    }

    private func expectedRow(_ index: Int) -> String {
        String(format: "STREAM-%08d | 流式输出 | 🚀", index)
    }

    private func assertGoldenGlyphsAndColor(in snapshot: TerminalGridSnapshot) {
        for row in 0..<snapshot.size.rows {
            let firstCell = snapshot.cells[row * snapshot.size.columns]
            if firstCell.content != .blank {
                XCTAssertEqual(firstCell.foreground, .indexed(2), "green ANSI on row \(row)")
            }
        }
        XCTAssertEqual(snapshot.cells[18].content, .cluster("流", columns: .two))
        XCTAssertEqual(snapshot.cells[19].content, .continuation)
        XCTAssertEqual(snapshot.cells[29].content, .cluster("🚀", columns: .two))
    }

    private func textRows(in snapshot: TerminalGridSnapshot) -> [String] {
        (0..<snapshot.size.rows).map { row in
            var text = ""
            for column in 0..<snapshot.size.columns {
                switch snapshot.cells[row * snapshot.size.columns + column].content {
                case .blank: text.append(" ")
                case let .cluster(cluster, _): text.append(contentsOf: cluster)
                case .continuation: break
                }
            }
            return text.trimmingCharacters(in: .whitespaces)
        }
    }

    private func reference() throws -> SessionReference { try SessionReference("s1") }

    private func origin(_ epoch: UInt64) -> SessionEventOrigin {
        SessionEventOrigin(
            linkInstanceID: linkInstanceID,
            deviceID: DeviceID("test-device"),
            connectionEpoch: ConnectionEpoch(epoch),
            receiveOrdinal: ReceiveOrdinal(epoch + 1)
        )
    }
}
