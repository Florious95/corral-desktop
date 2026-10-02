import AppKit
@testable import CorralApp
@testable import SwiftTerm
import XCTest

@MainActor
final class Issue25TerminalPaletteXtermTests: XCTestCase {
    func testNativeTerminalConfiguresXterm256PaletteStrategy() {
        let terminal = CorralNativeTerminalView(frame: .zero).getTerminal()

        switch terminal.ansi256PaletteStrategy {
        case .xterm:
            break
        case .base16Lab, .base16LabHarmonious:
            XCTFail("CorralNativeTerminalView must use SwiftTerm's standard xterm 256-color palette")
        }
    }

    func testNativeTerminalUsesStandardXtermColorAtIndex174() {
        let terminal = CorralNativeTerminalView(frame: .zero).getTerminal()
        let color = terminal.ansiColors[174]
        let actualRGB = [UInt8(color.red / 257), UInt8(color.green / 257), UInt8(color.blue / 257)]

        XCTAssertEqual(actualRGB, [215, 135, 135], "xterm color 174 must be #D78787, not the base16Lab-tinted #CB97A3")
    }
}
