import CorralMetalTerminal
import Foundation
import XCTest

final class CorralTerminalFilterTests: XCTestCase {
    func testOnlyExactLightTrueColorBackgroundIsRemapped() {
        let input = Data("A\u{1B}[48;2;244;244;240mB\u{1B}[38;2;244;244;240mC\u{1B}[48;2;244;244;241mD\u{1B}[48;5;231mE".utf8)
        let expected = Data("A\u{1B}[48;2;40;47;57mB\u{1B}[38;2;244;244;240mC\u{1B}[48;2;244;244;241mD\u{1B}[48;5;231mE".utf8)

        XCTAssertEqual(CorralTerminalFilter.remapTrueColorBackground(input), expected)
    }

    func testStreamingFilterMatchesAcrossEveryByteBoundary() {
        let before = Data("before".utf8)
        let target = Array("\u{1B}[48;2;244;244;240m".utf8)
        let after = Data("after".utf8)
        let expected = Data("before\u{1B}[48;2;40;47;57mafter".utf8)

        for split in 1..<target.count {
            var filter = CorralTerminalFilter()
            var output = filter.process(before + Data(target[..<split]))
            output.append(filter.process(Data(target[split...]) + after))
            output.append(filter.finish())
            XCTAssertEqual(output, expected, "failed at split offset \(split)")
        }
    }

    func testFinishPreservesUnmatchedPrefixAndResetDropsOldStreamPrefix() {
        let partial = Data("prefix\u{1B}[48;2;244;244;".utf8)
        var filter = CorralTerminalFilter()
        var output = filter.process(partial)
        output.append(filter.finish())
        XCTAssertEqual(output, partial)

        _ = filter.process(Data("\u{1B}[48;2;244".utf8))
        filter.reset()
        var afterReset = filter.process(Data("new stream".utf8))
        afterReset.append(filter.finish())
        XCTAssertEqual(afterReset, Data("new stream".utf8))
    }
}
