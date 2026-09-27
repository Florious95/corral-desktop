import CorralContracts
import Foundation
import OSLog
import SwiftTerm

public protocol TerminalEngineAdapter: TerminalEngineSubmitting, TerminalSnapshotProviding {}

public enum TerminalMouseReportingMode: Sendable, Equatable {
    case off
    case x10
    case vt200
    case buttonEventTracking
    case anyEvent
}

private enum TerminalEngineError: Error {
    case invalidGridSize
    case generationExhausted
}

/// SwiftTerm owns VT parsing and screen state; its replies are returned only as local terminal effects.
public actor SwiftTermEngineAdapter: TerminalEngineAdapter, TerminalMouseEventEncoding {
    private static let maximumCellCount = 1_000_000
    private static let logger = Logger(subsystem: "com.corral.native.dev", category: "terminal-adapter")

    private let delegate: EngineDelegate
    private let terminal: Terminal
    private var epoch: ConnectionEpoch?
    private var generation = DirtyGeneration.initial
    private var lastValidSnapshot: TerminalGridSnapshot?
    private var lastInvalidCellDiagnostic: String?

    public init(size: GridSize = GridSize(rows: 24, columns: 80)) {
        let initialSize = Self.isSupported(size) ? size : GridSize(rows: 24, columns: 80)
        let delegate = EngineDelegate()
        self.delegate = delegate
        terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(
                cols: initialSize.columns,
                rows: initialSize.rows,
                convertEol: true,
                termName: "xterm-256color",
                cursorStyle: .steadyBlock,
                scrollback: 500,
                regionalIndicatorWidth: .narrow
            )
        )
    }

    public func apply(_ update: TerminalUpdate) async throws -> [TerminalEffect] {
        delegate.beginUpdate()
        switch update {
        case let .snapshot(_, ansi, origin):
            guard accept(origin.connectionEpoch, resetOnEpochChange: false) else { return [] }
            terminal.resetToInitialState()
            delegate.resetCursor()
            terminal.feed(byteArray: [0x1B, 0x5B, 0x48])
            terminal.feed(byteArray: Array(ansi))
        case let .delta(_, ansi, origin):
            guard accept(origin.connectionEpoch, resetOnEpochChange: true) else { return [] }
            terminal.feed(byteArray: Array(ansi))
        case let .scrollback(_, _, ansi, origin):
            guard accept(origin.connectionEpoch, resetOnEpochChange: true) else { return [] }
            terminal.feed(byteArray: Array(ansi))
        }
        guard let next = generation.next() else { throw TerminalEngineError.generationExhausted }
        generation = next
        return delegate.drainEffects()
    }

    public func resize(to size: GridSize) async throws {
        guard Self.isSupported(size) else { throw TerminalEngineError.invalidGridSize }
        guard let next = generation.next() else { throw TerminalEngineError.generationExhausted }
        terminal.resize(cols: size.columns, rows: size.rows)
        generation = next
    }

    public func snapshot() async -> TerminalGridSnapshot {
        let dimensions = terminal.getDims()
        let size = GridSize(rows: dimensions.rows, columns: dimensions.cols)
        let position = terminal.getCursorLocation()
        let cursor = CursorDescriptor(
            row: min(max(position.y, 0), dimensions.rows - 1),
            column: min(max(position.x, 0), dimensions.cols - 1),
            isVisible: delegate.isCursorVisible,
            wrapPending: position.x >= dimensions.cols,
            shape: delegate.cursorShape
        )
        var cells: [TerminalCell] = []
        cells.reserveCapacity(dimensions.rows * dimensions.cols)

        for row in 0..<dimensions.rows {
            let rawRow = (0..<dimensions.cols).map { terminal.getCharData(col: $0, row: row) }
            for column in 0..<dimensions.cols {
                guard let raw = rawRow[column] else {
                    return invalidSnapshot(size: size, cursor: cursor, row: row, column: column, reason: "missing raw cell")
                }

                if raw.width == 0 {
                    guard column > 0,
                          let rawLeading = rawRow[column - 1], rawLeading.width == 2,
                          let leading = cells.last,
                          case .cluster(_, columns: .two) = leading.content else {
                        return invalidSnapshot(size: size, cursor: cursor, row: row, column: column, reason: "continuation without same-row leading wide cell")
                    }
                    cells.append(TerminalCell(
                        content: .continuation,
                        foreground: leading.foreground,
                        background: leading.background,
                        attributes: leading.attributes
                    ))
                    continue
                }

                guard raw.width == 1 || raw.width == 2 else {
                    return invalidSnapshot(size: size, cursor: cursor, row: row, column: column, reason: "unsupported raw cell width \(raw.width)")
                }
                let cluster = String(terminal.getCharacter(for: raw))
                let isBlank = cluster.isEmpty || cluster == " " || cluster == "\0"
                let content: CellContent = isBlank
                    ? .blank
                    : .cluster(cluster, columns: raw.width == 2 ? .two : .one)
                if raw.width == 2 {
                    guard !isBlank,
                          column + 1 < dimensions.cols,
                          rawRow[column + 1]?.width == 0 else {
                        return invalidSnapshot(size: size, cursor: cursor, row: row, column: column, reason: "wide leading cell has no same-row continuation")
                    }
                }

                let attribute = raw.attribute
                var attributes: TerminalAttributes = []
                if attribute.style.contains(.bold) { attributes.insert(.bold) }
                if attribute.style.contains(.italic) { attributes.insert(.italic) }
                if attribute.style.contains(.underline) { attributes.insert(.underline) }
                if attribute.style.contains(.inverse) { attributes.insert(.inverse) }
                cells.append(TerminalCell(
                    content: content,
                    foreground: Self.color(attribute.fg, default: terminal.foregroundColor, inverse: terminal.backgroundColor),
                    background: Self.color(attribute.bg, default: terminal.backgroundColor, inverse: terminal.foregroundColor),
                    attributes: attributes
                ))
            }
        }

        let snapshot = TerminalGridSnapshot(size: size, cells: cells, cursor: cursor, generation: generation)
        lastValidSnapshot = snapshot
        lastInvalidCellDiagnostic = nil
        return snapshot
    }

    private func invalidSnapshot(
        size: GridSize,
        cursor: CursorDescriptor,
        row: Int,
        column: Int,
        reason: String
    ) -> TerminalGridSnapshot {
        let diagnostic = "Invalid VT cell span at row \(row), column \(column): \(reason)"
        if lastInvalidCellDiagnostic != diagnostic {
            Self.logger.error("\(diagnostic, privacy: .public)")
            lastInvalidCellDiagnostic = diagnostic
        }
        return lastValidSnapshot ?? TerminalGridSnapshot(size: size, cells: [], cursor: cursor, generation: generation)
    }

    public func mouseReportingMode() -> TerminalMouseReportingMode {
        switch terminal.mouseMode {
        case .off: return .off
        case .x10: return .x10
        case .vt200: return .vt200
        case .buttonEventTracking: return .buttonEventTracking
        case .anyEvent: return .anyEvent
        }
    }

    public func encodeMouseEvent(
        button: Int,
        column: Int,
        row: Int,
        phase: TerminalMouseEventPhase,
        modifiers: TerminalMouseModifiers
    ) async -> Data? {
        guard button >= 0, button <= 2,
              (0..<terminal.cols).contains(column),
              (0..<terminal.rows).contains(row) else { return nil }

        let isRelease: Bool
        let isMotion: Bool
        switch phase {
        case .buttonDown:
            isRelease = false
            isMotion = false
        case .buttonUp:
            isRelease = true
            isMotion = false
        case .drag:
            isRelease = false
            isMotion = true
        }
        switch terminal.mouseMode {
        case .off:
            return nil
        case .x10 where isRelease || isMotion:
            return nil
        case .vt200 where isMotion:
            return nil
        default:
            break
        }

        let buttonFlags = terminal.encodeButton(
            button: button,
            release: isRelease,
            shift: modifiers.contains(.shift),
            meta: modifiers.contains(.option),
            control: modifiers.contains(.control)
        )
        delegate.beginUpdate()
        if isMotion {
            terminal.sendMotion(buttonFlags: buttonFlags, x: column, y: row, pixelX: column, pixelY: row)
        } else {
            terminal.sendEvent(buttonFlags: buttonFlags, x: column, y: row)
        }
        let effects = delegate.drainEffects()
        guard effects.count == 1, case let .autoReply(reply) = effects[0] else { return nil }
        return reply.data
    }

    private func accept(_ incoming: ConnectionEpoch, resetOnEpochChange: Bool) -> Bool {
        if let epoch, incoming < epoch { return false }
        if epoch != incoming {
            if resetOnEpochChange {
                terminal.resetToInitialState()
                delegate.resetCursor()
            }
            epoch = incoming
        }
        return true
    }

    private static func isSupported(_ size: GridSize) -> Bool {
        guard size.isValid else { return false }
        let (count, overflow) = size.rows.multipliedReportingOverflow(by: size.columns)
        return !overflow && count <= maximumCellCount
    }

    private static func color(_ color: Attribute.Color, default defaultColor: SwiftTerm.Color, inverse inverseColor: SwiftTerm.Color) -> TerminalColor {
        switch color {
        case let .ansi256(index): .indexed(index)
        case let .trueColor(red, green, blue): .rgba(RGBAColor(red: red, green: green, blue: blue))
        case .defaultColor: rgb(defaultColor)
        case .defaultInvertedColor: rgb(inverseColor)
        }
    }

    private static func rgb(_ color: SwiftTerm.Color) -> TerminalColor {
        .rgba(RGBAColor(
            red: UInt8((UInt32(color.red) + 128) / 257),
            green: UInt8((UInt32(color.green) + 128) / 257),
            blue: UInt8((UInt32(color.blue) + 128) / 257)
        ))
    }
}

private final class EngineDelegate: TerminalDelegate {
    var isCursorVisible = true
    var cursorShape: CursorShape = .block
    private var effects: [TerminalEffect] = []

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        effects.append(.autoReply(TerminalAutoReplyBytes(Data(data))))
    }

    func showCursor(source: Terminal) { isCursorVisible = true }
    func hideCursor(source: Terminal) { isCursorVisible = false }

    func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        switch newStyle {
        case .steadyBar, .blinkBar: cursorShape = .bar
        case .steadyUnderline, .blinkUnderline: cursorShape = .underline
        case .steadyBlock, .blinkBlock: cursorShape = .block
        }
    }

    func resetCursor() {
        isCursorVisible = true
        cursorShape = .block
    }

    func beginUpdate() { effects.removeAll(keepingCapacity: true) }
    func drainEffects() -> [TerminalEffect] { defer { effects.removeAll(keepingCapacity: true) }; return effects }
}
