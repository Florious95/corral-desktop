import Foundation

public struct GridSize: Codable, Hashable, Sendable {
    public let rows: Int
    public let columns: Int

    public init(rows: Int, columns: Int) {
        self.rows = rows
        self.columns = columns
    }

    public static let zero = GridSize(rows: 0, columns: 0)
    public var isValid: Bool { rows > 0 && columns > 0 }
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

public struct TerminalCell: Codable, Hashable, Sendable {
    public let codepoint: UInt32
    public let isWide: Bool
    public let foreground: TerminalColor
    public let background: TerminalColor
    public let attributes: TerminalAttributes

    public init(
        codepoint: UInt32,
        isWide: Bool = false,
        foreground: TerminalColor,
        background: TerminalColor,
        attributes: TerminalAttributes = []
    ) {
        self.codepoint = codepoint
        self.isWide = isWide
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
    public let shape: CursorShape

    public init(row: Int, column: Int, isVisible: Bool = true, shape: CursorShape = .block) {
        self.row = row
        self.column = column
        self.isVisible = isVisible
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
        guard size.isValid else { return false }
        let (cellCount, overflow) = size.rows.multipliedReportingOverflow(by: size.columns)
        return !overflow && cells.count == cellCount
    }
}

public enum TerminalUpdate: Codable, Equatable, Sendable {
    case snapshot(data: Data, epoch: ConnectionEpoch)
    case delta(data: Data, epoch: ConnectionEpoch)
    case scrollback(requestID: UInt32, data: Data, epoch: ConnectionEpoch)
}

/// VT-generated DA/CPR/DSR replies are deliberately not accepted by any SessionLink input API.
public struct TerminalAutoReplyBytes: Codable, Hashable, Sendable {
    public let data: Data
    public init(_ data: Data) { self.data = data }
}

public enum TerminalKey: String, Codable, Equatable, Sendable {
    case up, down, left, right, home, end, pageUp, pageDown, insert, delete
    case backspace, enter, escape, tab
    case function1, function2, function3, function4, function5, function6
    case function7, function8, function9, function10, function11, function12
}

/// Platform input intent stays typed until converted to user-originated bytes.
public enum TerminalInput: Codable, Equatable, Sendable {
    case userText(String)
    case namedKey(TerminalKey)
    case userBytes(UserInputBytes)
    case pasteIntent(String)
}

public struct LinkMetadata: Codable, Equatable, Sendable {
    public let label: String
    public let destination: String

    public init(label: String, destination: String) {
        self.label = label
        self.destination = destination
    }
}

public enum TerminalEffect: Codable, Equatable, Sendable {
    case autoReply(TerminalAutoReplyBytes)
    case bell
    case title(String)
    case linkMetadata(LinkMetadata)
    case deniedExternalEffect(String)
}

public protocol TerminalEngineSubmitting: Sendable {
    func apply(_ update: TerminalUpdate) async throws -> [TerminalAutoReplyBytes]
    func submitUserInput(_ input: UserInputBytes) async throws
    func resize(to size: GridSize) async throws
}

public protocol TerminalSnapshotProviding: Sendable {
    func snapshot() async -> TerminalGridSnapshot
}

public protocol ViewportStageIdentifiable: Sendable {
    var viewportStageID: UUID { get }
}

/// Top-left-origin stage coordinates in points, not device pixels.
public struct StageViewportRect: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite && width >= 0 && height >= 0
    }
}

public enum RenderSleepState: String, Codable, Sendable {
    case active
    case tabHidden
    case applicationInactive

    public var allowsDrawing: Bool { self == .active }
}

public struct DirtyGeneration: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let initial = DirtyGeneration(0)
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public func next() -> Self { DirtyGeneration(rawValue &+ 1) }
}

public struct GlyphKey: Codable, Hashable, Sendable {
    public let fontPostScriptName: String
    public let codepoint: UInt32
    public let pixelSize: UInt16
    public let isBold: Bool
    public let isItalic: Bool

    public init(fontPostScriptName: String, codepoint: UInt32, pixelSize: UInt16, isBold: Bool = false, isItalic: Bool = false) {
        self.fontPostScriptName = fontPostScriptName
        self.codepoint = codepoint
        self.pixelSize = pixelSize
        self.isBold = isBold
        self.isItalic = isItalic
    }
}

/// A zero-sized coordinate is the cleared/evicted sentinel; eviction must zero every coordinate field.
public struct AtlasCoordinates: Codable, Hashable, Sendable {
    public let page: UInt16
    public let x: UInt16
    public let y: UInt16
    public let width: UInt16
    public let height: UInt16

    public init(page: UInt16, x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        self.page = page
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = AtlasCoordinates(page: 0, x: 0, y: 0, width: 0, height: 0)
    public var isZeroed: Bool { self == .zero }
}

public struct AtlasMemoryBudget: Codable, Hashable, Sendable {
    public let maximumBytes: UInt64
    public let maximumPages: UInt32

    public init(maximumBytes: UInt64, maximumPages: UInt32) {
        self.maximumBytes = maximumBytes
        self.maximumPages = maximumPages
    }

    public func allowsAllocation(currentBytes: UInt64, additionalBytes: UInt64) -> Bool {
        let (total, overflow) = currentBytes.addingReportingOverflow(additionalBytes)
        return !overflow && total <= maximumBytes
    }

    public func allowsPageAllocation(currentPages: UInt32, additionalPages: UInt32 = 1) -> Bool {
        let (total, overflow) = currentPages.addingReportingOverflow(additionalPages)
        return !overflow && total <= maximumPages
    }
}
