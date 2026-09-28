import Foundation

/// Applies Corral's dark-theme override to one known light truecolor background SGR.
public struct CorralTerminalFilter: Sendable {
    private static let source = Data("\u{1B}[48;2;244;244;240m".utf8)
    private static let replacement = Data("\u{1B}[48;2;40;47;57m".utf8)

    private var pending = Data()

    public init() {}

    /// Rewrites a complete buffer, such as a full terminal snapshot.
    public static func remapTrueColorBackground(_ data: Data) -> Data {
        var filter = Self()
        var result = filter.process(data)
        result.append(filter.finish())
        return result
    }

    /// Rewrites complete matches while retaining a possible token prefix for the next delta.
    public mutating func process(_ data: Data) -> Data {
        var input = data
        if !pending.isEmpty { input = pending; input.append(data) }
        pending.removeAll(keepingCapacity: true)

        // Foundation searches and copies whole byte spans. Comparing the SGR
        // at every printable byte made this override dominate busy PTY streams.
        var output = Data()
        var start = input.startIndex
        while let match = input.range(of: Self.source, in: start..<input.endIndex) {
            output.append(input[start..<match.lowerBound])
            output.append(Self.replacement)
            start = match.upperBound
        }
        var end = input.endIndex
        // Only this bounded suffix can be the start of a token split across frames.
        for count in stride(from: min(end - start, Self.source.count - 1), through: 1, by: -1) {
            if Self.source.starts(with: input.suffix(count)) {
                pending = Data(input.suffix(count))
                end -= count
                break
            }
        }
        if output.isEmpty { return input[input.startIndex..<end] }
        output.append(input[start..<end])
        return output
    }

    /// Emits an unfinished candidate unchanged when the stream is permanently ending.
    public mutating func finish() -> Data {
        defer { pending.removeAll(keepingCapacity: true) }
        return Data(pending)
    }

    /// Drops an unfinished candidate when a snapshot replaces the current stream.
    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }
}
