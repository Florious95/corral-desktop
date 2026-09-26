import CorralContracts
import CorralMetalTerminal
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
