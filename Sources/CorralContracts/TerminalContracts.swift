import Foundation

public struct GridSize: Codable, Hashable, Sendable {
    public let rows: Int
    public let columns: Int

    public init(rows: Int, columns: Int) {
        self.rows = rows
        self.columns = columns
    }

    /// Local geometry validity is distinct from the v1 UInt16 wire representation.
    public var isValid: Bool { rows > 0 && columns > 0 }
    public var fitsProtocolV1: Bool {
        isValid && rows <= Int(UInt16.max) && columns <= Int(UInt16.max)
    }
    public static let zero = GridSize(rows: 0, columns: 0)
}

public struct RGBAColor: Codable, Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public enum TerminalColor: Codable, Hashable, Sendable {
    case rgba(RGBAColor)
    case indexed(UInt8)
}

public struct TerminalAttributes: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let bold = Self(rawValue: 1 << 0)
    public static let italic = Self(rawValue: 1 << 1)
    public static let underline = Self(rawValue: 1 << 2)
    public static let inverse = Self(rawValue: 1 << 3)
}

public enum CellSpan: UInt8, Codable, Sendable {
    case one = 1
    case two = 2
}

/// Cluster boundaries and terminal column width are supplied by the engine; never infer width from String.count.
public enum CellContent: Codable, Equatable, Sendable {
    case blank
    case cluster(String, columns: CellSpan)
    case continuation

    public var isValid: Bool {
        switch self {
        case .blank, .continuation: true
        case let .cluster(text, _): !text.isEmpty
        }
    }
}

public struct TerminalCell: Codable, Equatable, Sendable {
    public let content: CellContent
    public let foreground: TerminalColor
    public let background: TerminalColor
    public let attributes: TerminalAttributes

    public init(content: CellContent, foreground: TerminalColor, background: TerminalColor, attributes: TerminalAttributes = []) {
        self.content = content
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
    }
}

public enum CursorShape: String, Codable, Sendable {
    case block
    case bar
    case underline
}

public struct CursorDescriptor: Codable, Hashable, Sendable {
    public let row: Int
    public let column: Int
    public let isVisible: Bool
    public let wrapPending: Bool
    public let shape: CursorShape

    public init(row: Int, column: Int, isVisible: Bool = true, wrapPending: Bool = false, shape: CursorShape = .block) {
        self.row = row
        self.column = column
        self.isVisible = isVisible
        self.wrapPending = wrapPending
        self.shape = shape
    }
}

public struct TerminalGridSnapshot: Codable, Equatable, Sendable {
    public let size: GridSize
    public let cells: [TerminalCell]
    public let cursor: CursorDescriptor
    public let generation: DirtyGeneration

    public init(size: GridSize, cells: [TerminalCell], cursor: CursorDescriptor, generation: DirtyGeneration) {
        self.size = size
        self.cells = cells
        self.cursor = cursor
        self.generation = generation
    }

    public var isValid: Bool {
        guard size.isValid,
              cursor.row >= 0, cursor.row < size.rows,
              cursor.column >= 0, cursor.column < size.columns,
              !cursor.wrapPending || cursor.column == size.columns - 1 else { return false }
        let (cellCount, overflow) = size.rows.multipliedReportingOverflow(by: size.columns)
        guard !overflow, cells.count == cellCount, cells.allSatisfy({ $0.content.isValid }) else { return false }

        for row in 0..<size.rows {
            for column in 0..<size.columns {
                let content = cells[row * size.columns + column].content
                switch content {
                case .blank, .cluster(_, columns: .one): break
                case .cluster(_, columns: .two):
                    guard column + 1 < size.columns,
                          cells[row * size.columns + column + 1].content == .continuation else { return false }
                case .continuation:
                    guard column > 0 else { return false }
                    if case .cluster(_, columns: .two) = cells[row * size.columns + column - 1].content {
                        break
                    }
                    return false
                }
            }
        }
        return true
    }

    public func isValid(with budget: TerminalSnapshotBudget) -> Bool {
        guard isValid, UInt64(cells.count) <= budget.maximumCells else { return false }
        var clusterBytes: UInt64 = 0
        for cell in cells {
            guard case let .cluster(text, _) = cell.content else { continue }
            let (next, overflow) = clusterBytes.addingReportingOverflow(UInt64(text.utf8.count))
            guard !overflow, next <= budget.maximumClusterBytesTotal else { return false }
            clusterBytes = next
        }
        return true
    }
}

public struct TerminalSnapshotBudget: Codable, Hashable, Sendable {
    public let maximumCells: UInt64
    public let maximumClusterBytesTotal: UInt64

    public init(maximumCells: UInt64, maximumClusterBytesTotal: UInt64) {
        self.maximumCells = maximumCells
        self.maximumClusterBytesTotal = maximumClusterBytesTotal
    }
}

public struct TerminalBufferBudget: Codable, Hashable, Sendable {
    public let maximumPendingBytesPerSession: UInt64
    public let maximumPendingBytesApplicationWide: UInt64
    public let maximumSnapshotCells: UInt64

    public init(maximumPendingBytesPerSession: UInt64, maximumPendingBytesApplicationWide: UInt64, maximumSnapshotCells: UInt64) {
        self.maximumPendingBytesPerSession = maximumPendingBytesPerSession
        self.maximumPendingBytesApplicationWide = maximumPendingBytesApplicationWide
        self.maximumSnapshotCells = maximumSnapshotCells
    }
}

public enum TerminalUpdate: Equatable, Sendable {
    case snapshot(reference: SessionReference, ansi: Data, origin: SessionEventOrigin)
    case delta(reference: SessionReference, ansi: Data, origin: SessionEventOrigin)
    case scrollback(reference: SessionReference, metadata: ScrollbackMetadata, ansi: Data, origin: SessionEventOrigin)
}

/// A prevention type for accidental routing, not an unforgeable capability. Effects must use the local policy sink.
public struct UserInputBytes: Hashable, Sendable {
    public let data: Data
    public init(_ data: Data) { self.data = data }
}

public struct TerminalAutoReplyBytes: Hashable, Sendable {
    public let data: Data
    public init(_ data: Data) { self.data = data }
}

public enum TerminalKey: String, Codable, Equatable, Sendable {
    case up, down, left, right, home, end, pageUp, pageDown, insert, delete
    case backspace, enter, escape, tab
    case function1, function2, function3, function4, function5, function6
    case function7, function8, function9, function10, function11, function12
}

/// UI intent stays distinct from its v1 wire representation.
public enum TerminalInput: Equatable, Sendable {
    case userText(String)
    case namedKey(TerminalKey)
    case userBytes(UserInputBytes)
    case pasteIntent(String)
}

public struct LinkMetadata: Codable, Equatable, Sendable {
    public let label: String
    public let destination: String
    public init(label: String, destination: String) { self.label = label; self.destination = destination }
}

public enum TerminalEffect: Equatable, Sendable {
    case autoReply(TerminalAutoReplyBytes)
    case bell
    case title(String)
    case linkMetadata(LinkMetadata)
    case deniedExternalEffect(String)
}

public protocol TerminalEffectPolicySink: Sendable {
    /// Consumes engine effects locally; this interface has no SessionLink/uplink return channel.
    func consume(_ effects: [TerminalEffect], for session: SessionKey) async
}

public protocol TerminalEngineSubmitting: Sendable {
    /// Applies only server-originated bytes and returns effects; user input is sent by the input route, not locally echoed.
    func apply(_ update: TerminalUpdate) async throws -> [TerminalEffect]
    func resize(to size: GridSize) async throws
}

public protocol TerminalSnapshotProviding: Sendable {
    func snapshot() async -> TerminalGridSnapshot
}

public protocol TerminalInputRouting: Sendable {
    func route(_ input: TerminalInput, to session: SessionKey) async throws -> UInt32
}
