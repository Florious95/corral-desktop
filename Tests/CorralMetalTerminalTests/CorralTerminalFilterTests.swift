import CorralMetalTerminal
import Foundation
import XCTest

final class CorralTerminalFilterTests: XCTestCase {
    func testSustainedANSIThroughputDoesNotSpendAFrameScanningEveryByteForOneColor() {
        let row = Data("\u{1b}[38;2;213;220;230mS00 LIVE-00000042 中文 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ\r\n".utf8)
        var input = Data()
        for _ in 0..<16_000 { input.append(row) }
        var filter = CorralTerminalFilter()
        let started = ContinuousClock.now
        let output = filter.process(input)
        let elapsed = started.duration(to: .now)
        XCTAssertEqual(output, input, "unrelated ANSI and UTF-8 bytes must pass through unchanged")
        XCTAssertLessThan(elapsed, .milliseconds(100), "the color override must sustain the multiplexed stream without per-byte token comparisons")
    }

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

    func testByteSpansKeepMalformedEscapesAndNonUTF8AcrossSmallChunks() {
        let unrelated = Data((0...255).map(UInt8.init)) + Data("\u{1b}[48;2;244;\u{1b}[0m".utf8)
        let target = Data("\u{1b}[48;2;244;244;240m".utf8)
        let mapped = Data("\u{1b}[48;2;40;47;57m".utf8)
        let input = unrelated + target + target + unrelated + Data("\u{1b}[48;2;244".utf8)
        let expected = unrelated + mapped + mapped + unrelated + Data("\u{1b}[48;2;244".utf8)
        for width in 1...25 {
            var filter = CorralTerminalFilter()
            var output = Data()
            for start in stride(from: 0, to: input.count, by: width) {
                output.append(filter.process(input[start..<min(input.count, start + width)]))
            }
            output.append(filter.finish())
            XCTAssertEqual(output, expected, "chunk width \(width)")
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
