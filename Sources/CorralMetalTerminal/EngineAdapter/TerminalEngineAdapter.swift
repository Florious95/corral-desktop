import CorralContracts
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
}

/// SwiftTerm owns VT parsing and screen state. Its delegate's `send` callback intentionally drops
/// every kernel-generated response; only `UserInputBytes` is accepted by the uplink contract.
public actor SwiftTermEngineAdapter: TerminalEngineAdapter {
    private static let maximumCellCount = 1_000_000

    private let delegate: EngineDelegate
    private let terminal: Terminal
    private var epoch: ConnectionEpoch?
    private var generation = DirtyGeneration.initial

    public init(size: GridSize = GridSize(rows: 24, columns: 80)) {
        let initialSize = Self.isSupported(size) ? size : GridSize(rows: 24, columns: 80)
        let delegate = EngineDelegate()
        self.delegate = delegate
        terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(
                cols: initialSize.columns,
                rows: initialSize.rows,
                convertEol: false,
                termName: "xterm-256color",
                cursorStyle: .steadyBlock,
                scrollback: 500,
                regionalIndicatorWidth: .narrow
            )
        )
    }

    public func apply(_ update: TerminalUpdate) async throws -> [TerminalAutoReplyBytes] {
        switch update {
        case let .snapshot(data, incomingEpoch):
            guard accept(incomingEpoch, resetOnEpochChange: false) else { return [] }
            terminal.resetToInitialState()
            delegate.resetCursor()
            terminal.feed(byteArray: Array(data))
        case let .delta(data, incomingEpoch):
            guard accept(incomingEpoch, resetOnEpochChange: true) else { return [] }
            terminal.feed(byteArray: Array(data))
        case .scrollback:
            return []
        }
        generation = generation.next()
        return []
    }

    /// Input is routed to the remote session by the typed SessionLink path, not echoed into its output parser.
    public func submitUserInput(_ input: UserInputBytes) async throws {
        // Routing lives in TerminalInputRouting; never echo user bytes into remote output state.
    }

    public func resize(to size: GridSize) async throws {
        guard Self.isSupported(size) else { throw TerminalEngineError.invalidGridSize }
        terminal.resize(cols: size.columns, rows: size.rows)
        generation = generation.next()
    }

    public func snapshot() async -> TerminalGridSnapshot {
        let dimensions = terminal.getDims()
        var cells: [TerminalCell] = []
        cells.reserveCapacity(dimensions.rows * dimensions.cols)

        for row in 0..<dimensions.rows {
            for column in 0..<dimensions.cols {
                guard let data = terminal.getCharData(col: column, row: row) else {
                    cells.append(Self.blankCell)
                    continue
                }
                let character = terminal.getCharacter(for: data)
                let codepoint = character.unicodeScalars.first.map { UInt32($0.value) } ?? 0x20
                let attribute = data.attribute
                var attributes: TerminalAttributes = []
                if attribute.style.contains(.bold) { attributes.insert(.bold) }
                if attribute.style.contains(.italic) { attributes.insert(.italic) }
                if attribute.style.contains(.underline) { attributes.insert(.underline) }
                if attribute.style.contains(.inverse) { attributes.insert(.inverse) }

                cells.append(TerminalCell(
                    codepoint: codepoint == 0 ? 0x20 : codepoint,
                    isWide: data.width > 1,
                    foreground: Self.color(attribute.fg, default: terminal.foregroundColor, inverse: terminal.backgroundColor),
                    background: Self.color(attribute.bg, default: terminal.backgroundColor, inverse: terminal.foregroundColor),
                    attributes: attributes
                ))
            }
        }

        let position = terminal.getCursorLocation()
        return TerminalGridSnapshot(
            size: GridSize(rows: dimensions.rows, columns: dimensions.cols),
            cells: cells,
            cursor: CursorDescriptor(
                row: position.y,
                column: position.x,
                isVisible: delegate.isCursorVisible,
                shape: delegate.cursorShape
            ),
            generation: generation
        )
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
        codepoint: 0x20,
        foreground: .rgba(RGBAColor(red: 138, green: 138, blue: 138)),
        background: .rgba(RGBAColor(red: 0, green: 0, blue: 0))
    )

    private static func color(_ color: Attribute.Color, default defaultColor: SwiftTerm.Color, inverse inverseColor: SwiftTerm.Color) -> TerminalColor {
        switch color {
        case let .ansi256(index):
            return .indexed(index)
        case let .trueColor(red, green, blue):
            return .rgba(RGBAColor(red: red, green: green, blue: blue))
        case .defaultColor:
            return rgb(defaultColor)
        case .defaultInvertedColor:
            return rgb(inverseColor)
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

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        // CPR/DA/DSR and every other terminal-generated response are deliberately discarded here.
    }

    func showCursor(source: Terminal) {
        isCursorVisible = true
    }

    func hideCursor(source: Terminal) {
        isCursorVisible = false
    }

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
}
