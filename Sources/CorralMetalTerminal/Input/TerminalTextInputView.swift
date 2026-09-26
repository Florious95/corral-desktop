import AppKit
import CorralContracts
import Foundation

public struct TerminalCellPosition: Hashable, Sendable {
    public let row: Int
    public let column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

public struct TerminalCellSelection: Hashable, Sendable {
    public enum Mode: Hashable, Sendable {
        case linear
        case rectangular
    }

    public let anchor: TerminalCellPosition
    public let focus: TerminalCellPosition
    public let mode: Mode

    public init(anchor: TerminalCellPosition, focus: TerminalCellPosition, mode: Mode = .linear) {
        self.anchor = anchor
        self.focus = focus
        self.mode = mode
    }

    public func selectedColumns(on row: Int, grid: GridSize) -> Range<Int>? {
        let (_, overflow) = grid.rows.multipliedReportingOverflow(by: grid.columns)
        guard grid.isValid, !overflow, (0..<grid.rows).contains(row) else { return nil }
        let anchorRow = min(max(anchor.row, 0), grid.rows - 1)
        let focusRow = min(max(focus.row, 0), grid.rows - 1)
        let anchorColumn = min(max(anchor.column, 0), grid.columns - 1)
        let focusColumn = min(max(focus.column, 0), grid.columns - 1)

        switch mode {
        case .rectangular:
            guard (min(anchorRow, focusRow)...max(anchorRow, focusRow)).contains(row) else { return nil }
            return min(anchorColumn, focusColumn)..<max(anchorColumn, focusColumn) + 1
        case .linear:
            let first = min(anchorRow * grid.columns + anchorColumn, focusRow * grid.columns + focusColumn)
            let last = max(anchorRow * grid.columns + anchorColumn, focusRow * grid.columns + focusColumn)
            let rowStart = row * grid.columns
            let lower = max(first, rowStart) - rowStart
            let upper = min(last + 1, rowStart + grid.columns) - rowStart
            return lower < upper ? lower..<upper : nil
        }
    }

    public func selectedText(in snapshot: TerminalGridSnapshot) -> String {
        guard snapshot.isValid else { return "" }
        var selectedRows: [String] = []
        for row in 0..<snapshot.size.rows {
            guard let columns = selectedColumns(on: row, grid: snapshot.size) else { continue }
            var selectedRow = ""
            for column in columns {
                let index = row * snapshot.size.columns + column
                let previous = column > 0 ? snapshot.cells[index - 1] : nil
                if let text = Self.text(for: snapshot.cells[index], previousCell: previous) { selectedRow.append(text) }
            }
            selectedRows.append(selectedRow)
        }
        return selectedRows.joined(separator: "\n")
    }

    public func highlightRects(grid: GridSize, cellSize: NSSize, in bounds: NSRect) -> [NSRect] {
        guard grid.isValid, cellSize.width.isFinite, cellSize.height.isFinite, cellSize.width > 0, cellSize.height > 0 else { return [] }
        return (0..<grid.rows).compactMap { row in
            guard let columns = selectedColumns(on: row, grid: grid) else { return nil }
            let rect = NSRect(
                x: bounds.minX + CGFloat(columns.lowerBound) * cellSize.width,
                y: bounds.maxY - CGFloat(row + 1) * cellSize.height,
                width: CGFloat(columns.count) * cellSize.width,
                height: cellSize.height
            ).intersection(bounds)
            return rect.isEmpty ? nil : rect
        }
    }

    fileprivate static func text(for cell: TerminalCell, previousCell: TerminalCell? = nil) -> String? {
        if cell.codepoint == 0 { return previousCell?.isWide == true ? nil : " " }
        guard let scalar = UnicodeScalar(cell.codepoint) else { return "\u{FFFD}" }
        return CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
    }
}

/// Native AppKit text-input client. Marked text stays local until the input method commits it.
@MainActor
public class TerminalTextInputView: NSView, @preconcurrency NSTextInputClient {
    private let sessionID: SessionID
    private let inputRouting: any TerminalInputRouting
    private var markedTextValue: NSAttributedString?
    private var markedSelection = NSRange(location: 0, length: 0)
    private var compositionEnterInFlight = false
    private let routingContinuation: AsyncStream<UserInputBytes>.Continuation
    private var routingTask: Task<Void, Never>?
    private var gridSize = GridSize.zero
    private var cellSize = NSSize.zero
    private var terminalFont: NSFont?
    private var cursor = CursorDescriptor(row: 0, column: 0, isVisible: true)
    private var terminalSnapshot: TerminalGridSnapshot?
    private var accessibilitySnapshot = ""

    public private(set) var selection: TerminalCellSelection?

    public init(frame frameRect: NSRect, sessionID: SessionID, inputRouting: any TerminalInputRouting) {
        self.sessionID = sessionID
        self.inputRouting = inputRouting
        var continuation: AsyncStream<UserInputBytes>.Continuation!
        let stream = AsyncStream<UserInputBytes> { continuation = $0 }
        self.routingContinuation = continuation
        super.init(frame: frameRect)
        let routing = self.inputRouting
        self.routingTask = Task {
            for await input in stream {
                try? await routing.route(input, to: sessionID)
            }
        }
    }

    public required init?(coder: NSCoder) { nil }

    deinit { routingContinuation.finish() }

    public override var acceptsFirstResponder: Bool { true }
    public var hasMarkedComposition: Bool { (markedTextValue?.length ?? 0) > 0 }
    public var markedText: NSAttributedString? { markedTextValue }
    public var caretRectInView: NSRect { cursorCellRect }

    public func configure(grid: GridSize, cellSize: NSSize, cursor: CursorDescriptor, font: NSFont? = nil) {
        self.gridSize = grid
        self.cellSize = cellSize
        self.cursor = cursor
        terminalFont = font
        needsDisplay = true
    }

    public func updateTerminalSnapshot(_ snapshot: TerminalGridSnapshot, accessibilityCharacterLimit: Int = 4096) {
        terminalSnapshot = snapshot
        gridSize = snapshot.size
        cursor = snapshot.cursor
        accessibilitySnapshot = Self.accessibleText(from: snapshot, characterLimit: min(max(accessibilityCharacterLimit, 0), 4096))
        needsDisplay = true
    }

    public func setSelection(_ selection: TerminalCellSelection?) {
        self.selection = selection
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35).setFill()
        for rect in selectionHighlightRects { rect.fill() }

        guard let markedTextValue, !markedTextValue.string.isEmpty, !cursorCellRect.isEmpty else { return }
        let font = terminalFont ?? NSFont.monospacedSystemFont(ofSize: min(max(cellSize.height * 0.8, 1), 256), weight: .regular)
        let composition = NSMutableAttributedString(attributedString: markedTextValue)
        composition.addAttributes([.font: font, .foregroundColor: NSColor.textColor], range: NSRange(location: 0, length: composition.length))
        let rect = NSRect(
            x: cursorCellRect.minX,
            y: cursorCellRect.minY,
            width: max(bounds.maxX - cursorCellRect.minX, CGFloat(composition.length) * cellSize.width),
            height: cellSize.height
        )
        composition.draw(in: rect)
    }

    public var selectionHighlightRects: [NSRect] {
        selection?.highlightRects(grid: gridSize, cellSize: cellSize, in: bounds) ?? []
    }

    public func selectedText() -> String {
        guard let selection, let terminalSnapshot else { return "" }
        return selection.selectedText(in: terminalSnapshot)
    }

    public func hasMarkedText() -> Bool { hasMarkedComposition }

    public func markedRange() -> NSRange {
        hasMarkedComposition ? NSRange(location: 0, length: markedTextValue!.length) : NSRange(location: NSNotFound, length: 0)
    }

    public func selectedRange() -> NSRange {
        if hasMarkedComposition { return markedSelection }
        let (_, overflow) = gridSize.rows.multipliedReportingOverflow(by: gridSize.columns)
        guard let selection, gridSize.isValid, !overflow else { return NSRange(location: NSNotFound, length: 0) }
        let anchor = clampedCellIndex(selection.anchor)
        let focus = clampedCellIndex(selection.focus)
        return NSRange(location: min(anchor, focus), length: abs(focus - anchor) + 1)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let value = attributedText(from: string), value.length > 0 else {
            markedTextValue = nil
            markedSelection = NSRange(location: 0, length: 0)
            needsDisplay = true
            return
        }
        markedTextValue = value
        let length = value.length
        let location = min(max(selectedRange.location == NSNotFound ? length : selectedRange.location, 0), length)
        let selectionLength = min(max(selectedRange.length, 0), length - location)
        markedSelection = NSRange(location: location, length: selectionLength)
        needsDisplay = true
    }

    public func unmarkText() {
        guard let text = markedTextValue?.string else { return }
        markedTextValue = nil
        markedSelection = NSRange(location: 0, length: 0)
        if !compositionEnterInFlight || (!text.contains("\r") && !text.contains("\n")) { sendUserText(text) }
        needsDisplay = true
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let markedTextValue else { return nil }
        let marked = NSRange(location: 0, length: markedTextValue.length)
        let location = range.location == NSNotFound ? 0 : min(max(range.location, 0), marked.length)
        let length = range.location == NSNotFound ? marked.length : min(max(range.length, 0), marked.length - location)
        let requested = NSRange(location: location, length: length)
        actualRange?.pointee = requested
        return markedTextValue.attributedSubstring(from: requested)
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = attributedText(from: string)?.string else { return }
        if compositionEnterInFlight && (text.contains("\r") || text.contains("\n")) { return }
        markedTextValue = nil
        markedSelection = NSRange(location: 0, length: 0)
        sendUserText(text)
        needsDisplay = true
    }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = hasMarkedComposition ? markedRange() : range
        let localRect = cursorCellRect
        guard !localRect.isEmpty, let window else { return .zero }
        return window.convertToScreen(convert(localRect, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int {
        let (_, overflow) = gridSize.rows.multipliedReportingOverflow(by: gridSize.columns)
        guard gridSize.isValid, !overflow, cellSize.width.isFinite, cellSize.height.isFinite,
              cellSize.width > 0, cellSize.height > 0, point.x.isFinite, point.y.isFinite else { return NSNotFound }
        let windowPoint = window?.convertPoint(fromScreen: point) ?? point
        let localPoint = convert(windowPoint, from: nil)
        guard localPoint.x.isFinite, localPoint.y.isFinite, bounds.contains(localPoint) else { return NSNotFound }
        let column = Int(floor((localPoint.x - bounds.minX) / cellSize.width))
        let row = Int(floor((bounds.maxY - localPoint.y) / cellSize.height))
        guard (0..<gridSize.columns).contains(column), (0..<gridSize.rows).contains(row) else { return NSNotFound }
        return row * gridSize.columns + column
    }

    public override func keyDown(with event: NSEvent) {
        if Self.isEnter(event) {
            guard hasMarkedComposition else {
                sendUserText("\r")
                return
            }
            compositionEnterInFlight = true
            defer { compositionEnterInFlight = false }
            interpretKeyEvents([event])
            return
        }
        interpretKeyEvents([event])
    }

    public override func doCommand(by selector: Selector) {
        guard !hasMarkedComposition else { return }
        switch NSStringFromSelector(selector) {
        case "insertNewline:":
            guard !hasMarkedComposition, !compositionEnterInFlight else { return }
            sendUserText("\r")
        case "deleteBackward:":
            sendUserText("\u{7f}")
        case "moveUp:":
            sendUserText("\u{1b}[A")
        case "moveDown:":
            sendUserText("\u{1b}[B")
        case "moveRight:":
            sendUserText("\u{1b}[C")
        case "moveLeft:":
            sendUserText("\u{1b}[D")
        default:
            break
        }
    }

    @objc public func copy(_ sender: Any?) {
        let text = selectedText()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc public func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    public override func accessibilityRole() -> NSAccessibility.Role { .textArea }
    public override func accessibilityLabel() -> String? { "Terminal" }
    public override func accessibilityValue() -> Any? { accessibilitySnapshot }

    private var cursorCellRect: NSRect {
        guard gridSize.isValid, cellSize.width.isFinite, cellSize.height.isFinite,
              cellSize.width > 0, cellSize.height > 0 else { return .zero }
        let row = min(max(cursor.row, 0), gridSize.rows - 1)
        let column = min(max(cursor.column, 0), gridSize.columns - 1)
        return NSRect(
            x: bounds.minX + CGFloat(column) * cellSize.width,
            y: bounds.maxY - CGFloat(row + 1) * cellSize.height,
            width: cellSize.width,
            height: cellSize.height
        )
    }

    private func attributedText(from value: Any) -> NSAttributedString? {
        if let attributed = value as? NSAttributedString { return attributed }
        if let string = value as? String { return NSAttributedString(string: string) }
        if let string = value as? NSString { return NSAttributedString(string: string as String) }
        return nil
    }

    private func clampedCellIndex(_ position: TerminalCellPosition) -> Int {
        let row = min(max(position.row, 0), gridSize.rows - 1)
        let column = min(max(position.column, 0), gridSize.columns - 1)
        return row * gridSize.columns + column
    }

    private func sendUserText(_ text: String) {
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return }
        routingContinuation.yield(UserInputBytes(data))
    }

    private static func isEnter(_ event: NSEvent) -> Bool { event.keyCode == 36 || event.keyCode == 76 }

    private static func accessibleText(from snapshot: TerminalGridSnapshot, characterLimit: Int) -> String {
        guard snapshot.isValid, characterLimit > 0 else { return "" }
        var scalars = String.UnicodeScalarView()
        for row in 0..<snapshot.size.rows {
            for column in 0..<snapshot.size.columns {
                guard scalars.count < characterLimit else { return String(scalars) }
                let cell = snapshot.cells[row * snapshot.size.columns + column]
                let previous = column > 0 ? snapshot.cells[row * snapshot.size.columns + column - 1] : nil
                guard let text = TerminalCellSelection.text(for: cell, previousCell: previous) else { continue }
                scalars.append(contentsOf: text.unicodeScalars)
            }
            if row + 1 < snapshot.size.rows {
                guard scalars.count < characterLimit else { return String(scalars) }
                scalars.append("\n")
            }
        }
        return String(scalars)
    }
}
