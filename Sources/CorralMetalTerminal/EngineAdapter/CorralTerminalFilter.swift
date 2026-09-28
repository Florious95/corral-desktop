import Foundation

/// Applies Corral's dark-theme override to one known light truecolor background SGR.
public struct CorralTerminalFilter: Sendable {
    private static let source = Array("\u{1B}[48;2;244;244;240m".utf8)
    private static let replacement = Array("\u{1B}[48;2;40;47;57m".utf8)

    private var pending: [UInt8] = []

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
        var input = pending
        input.append(contentsOf: data)
        pending.removeAll(keepingCapacity: true)

        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            let remaining = input.count - index
            if remaining >= Self.source.count,
               input[index..<(index + Self.source.count)].elementsEqual(Self.source) {
                output.append(contentsOf: Self.replacement)
                index += Self.source.count
            } else if remaining < Self.source.count,
                      Self.source.starts(with: input[index...]) {
                pending.append(contentsOf: input[index...])
                break
            } else {
                output.append(input[index])
                index += 1
            }
        }
        return Data(output)
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
