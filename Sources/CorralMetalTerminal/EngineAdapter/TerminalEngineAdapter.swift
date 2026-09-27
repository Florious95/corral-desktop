import CorralContracts
import Foundation
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
public actor SwiftTermEngineAdapter: TerminalEngineAdapter {
    private static let maximumCellCount = 1_000_000

    private let delegate: EngineDelegate
    private let terminal: Terminal
    private var epoch: ConnectionEpoch?
    private var generation = DirtyGeneration.initial
    private var lastValidSnapshot: TerminalGridSnapshot?

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
        var cells: [TerminalCell] = []
        cells.reserveCapacity(dimensions.rows * dimensions.cols)

        var invalidSpan: (row: Int, column: Int)?
        for row in 0..<dimensions.rows {
            let rowStart = cells.count
            let rawRow = (0..<dimensions.cols).map { terminal.getCharData(col: $0, row: row) }
            for column in 0..<dimensions.cols {
                guard let data = rawRow[column] else {
                    cells.append(Self.blankCell)
                    continue
                }
                if data.width == 0 {
                    guard column > 0, rawRow[column - 1]?.width == 2,
                          cells.count > rowStart,
                          case .cluster(_, columns: .two) = cells[cells.count - 1].content else {
                        invalidSpan = (row, column)
                        break
                    }
                    let leading = cells[cells.count - 1]
                    cells.append(TerminalCell(
                        content: .continuation,
                        foreground: leading.foreground,
                        background: leading.background,
                        attributes: leading.attributes
                    ))
                    continue
                }
                guard data.width == 1 || data.width == 2,
                      data.width != 2 || (column + 1 < dimensions.cols && rawRow[column + 1]?.width == 0) else {
                    invalidSpan = (row, column)
                    break
                }
                let cluster = String(terminal.getCharacter(for: data))
                let content: CellContent
                if cluster.isEmpty || cluster == " " || cluster == "\0" {
                    content = .blank
                } else {
                    content = .cluster(cluster, columns: data.width == 2 ? .two : .one)
                }
                let attribute = data.attribute
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
            if invalidSpan != nil { break }
        }

        let position = terminal.getCursorLocation()
        let wrapPending = position.x >= dimensions.cols
        let snapshot = TerminalGridSnapshot(
            size: GridSize(rows: dimensions.rows, columns: dimensions.cols),
            cells: cells,
            cursor: CursorDescriptor(
                row: min(max(position.y, 0), dimensions.rows - 1),
                column: min(max(position.x, 0), dimensions.cols - 1),
                isVisible: delegate.isCursorVisible,
                wrapPending: wrapPending,
                shape: delegate.cursorShape
            ),
            generation: generation
        )
        guard invalidSpan == nil, snapshot.isValid else {
            if let invalidSpan {
                NSLog("CorralMetalTerminal: invalid wide-cell span at row %d column %d; preserving last valid snapshot", invalidSpan.row, invalidSpan.column)
            } else {
                NSLog("CorralMetalTerminal: invalid terminal snapshot; preserving last valid snapshot")
            }
            return lastValidSnapshot ?? snapshot
        }
        lastValidSnapshot = snapshot
        return snapshot
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

    private static let blankCell = TerminalCell(
        content: .blank,
        foreground: .rgba(RGBAColor(red: 138, green: 138, blue: 138)),
        background: .rgba(RGBAColor(red: 0, green: 0, blue: 0))
    )

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
