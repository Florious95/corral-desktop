import CorralMetalTerminal
import XCTest

final class TerminalThemePaletteTests: XCTestCase {
    func testDarkPaletteMatchesLegacyThemeAndANSIOrder() {
        let palette = TerminalThemePalette.dark
        XCTAssertEqual(palette.background.hexRGB, "#0f1115")
        XCTAssertEqual(palette.foreground.hexRGB, "#d5dce6")
        XCTAssertEqual(palette.cursor.hexRGB, "#d5dce6")
        XCTAssertEqual(palette.cursorAccent.hexRGB, "#0f1115")
        XCTAssertEqual(palette.selectionBackground.hexRGB, "#7aa2f7")
        XCTAssertEqual(palette.selectionBackground.alpha, 0.3, accuracy: 0.0001)
        XCTAssertEqual(palette.selectionForeground?.hexRGB, "#ffffff")
        XCTAssertEqual(palette.ansi16.map(\.hexRGB), [
            "#414868", "#f7768e", "#9ece6a", "#e0af68",
            "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5",
            "#787c99", "#ff899d", "#b9f27c", "#ffc777",
            "#82aaff", "#c099ff", "#86e1fc", "#c8d3f5"
        ])
        XCTAssertEqual(palette.color(forANSIIndex: 1).hexRGB, "#f7768e")
    }

    func testLightPaletteMatchesLegacyThemeAndANSIOrder() {
        let palette = TerminalThemePalette.light
        XCTAssertEqual(palette.background.hexRGB, "#fbfaf8")
        XCTAssertEqual(palette.foreground.hexRGB, "#3a3835")
        XCTAssertEqual(palette.cursor.hexRGB, "#3a3835")
        XCTAssertEqual(palette.cursorAccent.hexRGB, "#fbfaf8")
        XCTAssertEqual(palette.selectionBackground.hexRGB, "#000000")
        XCTAssertEqual(palette.selectionBackground.alpha, 0.12, accuracy: 0.0001)
        XCTAssertNil(palette.selectionForeground)
        XCTAssertEqual(palette.ansi16.map(\.hexRGB), [
            "#343b58", "#8c2438", "#2b6a4a", "#8c5a1e",
            "#2e5898", "#6f3b89", "#1f687a", "#fbfaf8",
            "#68707a", "#a83446", "#387a56", "#a86c24",
            "#3a68b0", "#8448a4", "#28788c", "#3a3835"
        ])
        XCTAssertEqual(palette.color(forANSIIndex: 1).hexRGB, "#8c2438")
    }
}
