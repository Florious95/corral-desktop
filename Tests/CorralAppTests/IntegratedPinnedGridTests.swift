import AppKit
import CorralContracts
import XCTest
@testable import CorralApp
@testable import SwiftTerm

@MainActor
final class IntegratedPinnedGridTests: XCTestCase {
    func testFontChangesNeverReflowThroughAnIntermediateSmallerGrid() throws {
        let view = CorralNativeTerminalView(frame: .zero)
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 400)
        view.pinnedGrid = GridSize(rows: 44, columns: 46)
        view.place(in: viewport)
        view.replaceSnapshot(Data("\u{1b}[?1049h\u{1b}[44;1HFOOTER_MUST_STAY_ON_LAST_ROW".utf8))
        XCTAssertTrue(view.terminal.isDisplayBufferAlternate, "Pi uses the alternate screen")
        for pointSize in [18, 13, 20, 13] {
            view.setTerminalFont(family: "Menlo", size: pointSize)
            view.place(in: viewport)
            XCTAssertEqual(view.terminal.cols, 46)
            XCTAssertEqual(view.terminal.rows, 44)
            XCTAssertTrue(view.terminal.getLine(row: 43)?.translateToString(trimRight: true).contains("FOOTER_MUST_STAY_ON_LAST_ROW") == true,
                          "Changing font metrics must not resize with the old pixel frame and lose the bottom rows")
            XCTAssertEqual(view.frame.maxY, viewport.maxY, accuracy: 0.01)
        }
    }
}
