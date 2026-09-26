import CorralContracts
import CorralMetalTerminal
import XCTest

final class TerminalEngineTests: XCTestCase {
    func testParsesSGRColorsAttributesAndCursorModes() async throws {
        let engine = SwiftTermEngineAdapter(size: GridSize(rows: 2, columns: 8))
        _ = try await feed("\u{1B}[1;3;4;7;38;2;1;2;3mX\u{1B}[3 q\u{1B}[?25l", to: engine)

        let snapshot = await engine.snapshot()
        let cell = snapshot.cells[0]
        XCTAssertEqual(cell.codepoint, 88)
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
        XCTAssertEqual(snapshot.cells[0].codepoint, 65)
        XCTAssertTrue(snapshot.cells[1].isWide)
        XCTAssertTrue(snapshot.cells[3].isWide)
        XCTAssertTrue(snapshot.cells[5].isWide)
        XCTAssertEqual(snapshot.cells[7].codepoint, 0x2500)
        XCTAssertFalse(snapshot.cells[7].isWide)
        XCTAssertEqual(snapshot.cursor.column, 8)
    }

    func testParsesCSIAndUTF8AcrossFrameBoundaries() async throws {
        let engine = SwiftTermEngineAdapter(size: GridSize(rows: 1, columns: 4))
        _ = try await engine.apply(.delta(data: Data([0x1B, 0x5B, 0x33, 0x38, 0x3B, 0x35, 0x3B]), epoch: .initial))
        _ = try await engine.apply(.delta(data: Data([0x32, 0x30, 0x31, 0x6D, 0xE7]), epoch: .initial))
        _ = try await engine.apply(.delta(data: Data([0x95, 0x8C]), epoch: .initial))

        let snapshot = await engine.snapshot()
        let cell = snapshot.cells[0]
        XCTAssertEqual(cell.codepoint, 0x754C)
        XCTAssertEqual(cell.foreground, .indexed(201))
        XCTAssertTrue(cell.isWide)
    }

    func testAlternateScreenAndMouseReportModesFollowVTState() async throws {
        let engine = SwiftTermEngineAdapter(size: GridSize(rows: 2, columns: 8))
        _ = try await feed("main", to: engine)
        _ = try await feed("\u{1B}[?1049h\u{1B}[HALT\u{1B}[?1003h", to: engine)
        let alternate = await engine.snapshot()
        let mouseMode = await engine.mouseReportingMode()
        XCTAssertEqual(alternate.cells[0].codepoint, 65)
        XCTAssertEqual(mouseMode, .anyEvent)

        _ = try await feed("\u{1B}[?1049l", to: engine)
        let restored = await engine.snapshot()
        XCTAssertEqual(restored.cells[0].codepoint, 109)
    }

    func testTerminalQueriesAreDroppedAndCannotBecomeUserInput() async throws {
        let engine = SwiftTermEngineAdapter(size: GridSize(rows: 2, columns: 8))
        let replies = try await feed("\u{1B}[5n\u{1B}[6n\u{1B}[c\u{1B}[?6n", to: engine)
        XCTAssertTrue(replies.isEmpty)

        try await engine.submitUserInput(UserInputBytes(Data("user".utf8)))
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.cells[0].codepoint, 0x20)
    }

    func testSnapshotIsAnImmutableCopyAndOlderEpochsAreIgnored() async throws {
        let engine = SwiftTermEngineAdapter(size: GridSize(rows: 1, columns: 4))
        _ = try await engine.apply(.snapshot(data: Data("A".utf8), epoch: ConnectionEpoch(1)))
        let first = await engine.snapshot()
        _ = try await engine.apply(.delta(data: Data("B".utf8), epoch: ConnectionEpoch(1)))
        let second = await engine.snapshot()
        XCTAssertEqual(first.cells[0].codepoint, 65)
        XCTAssertEqual(second.cells[1].codepoint, 66)

        _ = try await engine.apply(.delta(data: Data("Z".utf8), epoch: ConnectionEpoch(0)))
        let afterOldEpoch = await engine.snapshot()
        XCTAssertEqual(afterOldEpoch.cells[2].codepoint, 0x20)
    }

    private func feed(_ text: String, to engine: SwiftTermEngineAdapter) async throws -> [TerminalAutoReplyBytes] {
        try await engine.apply(.delta(data: Data(text.utf8), epoch: .initial))
    }
}
