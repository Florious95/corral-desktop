import AppKit
import CorralContracts
import Foundation
import UniformTypeIdentifiers

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
                if let text = Self.text(for: snapshot.cells[index]) { selectedRow.append(text) }
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

    fileprivate static func text(for cell: TerminalCell) -> String? {
        switch cell.content {
        case .blank: " "
        case .continuation: nil
        case let .cluster(text, _):
            text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) ? " " : text
        }
    }
}

public enum TerminalMouseEventPhase: Equatable, Sendable {
    case buttonDown
    case buttonUp
    case drag
}

public struct TerminalMouseModifiers: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = Self(rawValue: 1 << 0)
    public static let option = Self(rawValue: 1 << 1)
    public static let control = Self(rawValue: 1 << 2)
}

/// Implemented by the terminal adapter so its active protocol mode selects the mouse byte format.
public protocol TerminalMouseEventEncoding: Sendable {
    func encodeMouseEvent(
        button: Int,
        column: Int,
        row: Int,
        phase: TerminalMouseEventPhase,
        modifiers: TerminalMouseModifiers
    ) async -> Data?
}

private struct TerminalMouseEventRequest: Sendable {
    let cell: TerminalCellPosition
    let phase: TerminalMouseEventPhase
    let modifiers: TerminalMouseModifiers
}

private enum TerminalInputFIFOEntry: Sendable {
    case bytes(UserInputBytes)
    case mouse(TerminalMouseEventRequest)
}

/// Native AppKit text-input client. Marked text stays local until the input method commits it.
@MainActor
public class TerminalTextInputView: NSView, @preconcurrency NSTextInputClient {
    private let sessionKey: SessionKey
    private let inputRouting: any TerminalInputRouting
    private let pasteboard: NSPasteboard
    private var markedTextValue: NSAttributedString?
    private var markedSelection = NSRange(location: 0, length: 0)
    private var compositionEnterInFlight = false
    private let routingContinuation: AsyncStream<TerminalInputFIFOEntry>.Continuation
    private let mouseEventEncoder: (any TerminalMouseEventEncoding)?
    private var routingTask: Task<Void, Never>?
    private var mouseSelectionAnchor: TerminalCellPosition?
    private var forceTextSelectionForMouseGesture = false
    private var mouseGestureReported = false
    private var gridSize = GridSize.zero
    private var cellSize = NSSize.zero
    private var terminalFont: NSFont?
    private var cursor = CursorDescriptor(row: 0, column: 0, isVisible: true)
    private var terminalSnapshot: TerminalGridSnapshot?
    private var accessibilitySnapshot = ""

    public private(set) var selection: TerminalCellSelection?

    public init(
        frame frameRect: NSRect,
        sessionKey: SessionKey,
        inputRouting: any TerminalInputRouting,
        pasteboard: NSPasteboard = .general,
        mouseEventEncoder: (any TerminalMouseEventEncoding)? = nil
    ) {
        self.sessionKey = sessionKey
        self.inputRouting = inputRouting
        self.pasteboard = pasteboard
        self.mouseEventEncoder = mouseEventEncoder
        var continuation: AsyncStream<TerminalInputFIFOEntry>.Continuation!
        let stream = AsyncStream<TerminalInputFIFOEntry> { continuation = $0 }
        self.routingContinuation = continuation
        super.init(frame: frameRect)
        let routing = self.inputRouting
        self.routingTask = Task { [weak self] in
            for await entry in stream {
                switch entry {
                case let .bytes(input):
                    _ = try? await routing.route(.userBytes(input), to: sessionKey)
                case let .mouse(event):
                    guard let encoder = self?.mouseEventEncoder,
                          let data = await encoder.encodeMouseEvent(
                            button: 0,
                            column: event.cell.column,
                            row: event.cell.row,
                            phase: event.phase,
                            modifiers: event.modifiers
                          ), !data.isEmpty else {
                        self?.applyTextSelection(for: event)
                        continue
                    }
                    self?.finishReportedMouseEvent(event)
                    _ = try? await routing.route(.userBytes(UserInputBytes(data)), to: sessionKey)
                }
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

    /// Input points and cell metrics are both in AppKit points; the adapter receives zero-based cells.
    public func terminalCell(atViewPoint point: NSPoint) -> TerminalCellPosition? {
        let (_, overflow) = gridSize.rows.multipliedReportingOverflow(by: gridSize.columns)
        guard gridSize.isValid, !overflow, cellSize.width.isFinite, cellSize.height.isFinite,
              cellSize.width > 0, cellSize.height > 0, point.x.isFinite, point.y.isFinite else { return nil }
        let column = (point.x - bounds.minX) / cellSize.width
        let row = (bounds.maxY - point.y) / cellSize.height
        guard column.isFinite, row.isFinite, column >= 0, column < CGFloat(gridSize.columns),
              row >= 0, row < CGFloat(gridSize.rows) else { return nil }
        return TerminalCellPosition(row: Int(floor(row)), column: Int(floor(column)))
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

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let cell = terminalCell(atViewPoint: point) else {
            super.mouseDown(with: event)
            return
        }
        if event.modifierFlags.contains(.option) || mouseEventEncoder == nil {
            forceTextSelectionForMouseGesture = event.modifierFlags.contains(.option)
            applyTextSelection(for: TerminalMouseEventRequest(cell: cell, phase: .buttonDown, modifiers: []))
        } else {
            forceTextSelectionForMouseGesture = false
            mouseGestureReported = true
            enqueueMouseEvent(cell, phase: .buttonDown, modifiers: event.modifierFlags)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let cell = terminalCell(atViewPoint: convert(event.locationInWindow, from: nil)) else { return }
        guard mouseSelectionAnchor != nil || mouseGestureReported else { return }
        if forceTextSelectionForMouseGesture || event.modifierFlags.contains(.option) || mouseEventEncoder == nil {
            applyTextSelection(for: TerminalMouseEventRequest(cell: cell, phase: .drag, modifiers: []))
        } else {
            enqueueMouseEvent(cell, phase: .drag, modifiers: event.modifierFlags)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let cell = terminalCell(atViewPoint: point) else {
            mouseSelectionAnchor = nil
            mouseGestureReported = false
            forceTextSelectionForMouseGesture = false
            return
        }
        if forceTextSelectionForMouseGesture || event.modifierFlags.contains(.option) || mouseEventEncoder == nil {
            applyTextSelection(for: TerminalMouseEventRequest(cell: cell, phase: .buttonUp, modifiers: []))
        } else if mouseSelectionAnchor != nil || mouseGestureReported {
            enqueueMouseEvent(cell, phase: .buttonUp, modifiers: event.modifierFlags)
        }
        forceTextSelectionForMouseGesture = false
    }

    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isVKey = event.keyCode == 9 || event.charactersIgnoringModifiers?.lowercased() == "v"
        if isVKey && modifiers.contains(.command) {
            pasteClipboard(allowFiles: true, allowImages: true)
            return
        }
        if isVKey && modifiers.contains(.control) {
            pasteControlV()
            return
        }
        if hasMarkedComposition {
            if Self.isEnter(event) {
                compositionEnterInFlight = true
                defer { compositionEnterInFlight = false }
                interpretKeyEvents([event])
                return
            }
            interpretKeyEvents([event])
            return
        }
        if let text = Self.directInput(for: event, modifiers: modifiers) {
            sendUserText(text)
            return
        }
        if Self.isEnter(event) {
            sendUserText("\r")
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
        case "insertTab:":
            sendUserText("\t")
        case "cancelOperation:":
            sendUserText("\u{1b}")
        case "deleteBackward:":
            sendUserText("\u{7f}")
        case "deleteForward:":
            sendUserText("\u{1b}[3~")
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
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc public func paste(_ sender: Any?) {
        pasteClipboard(allowFiles: true, allowImages: true)
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

    private func enqueueMouseEvent(_ cell: TerminalCellPosition, phase: TerminalMouseEventPhase, modifiers: NSEvent.ModifierFlags) {
        var terminalModifiers: TerminalMouseModifiers = []
        if modifiers.contains(.shift) { terminalModifiers.insert(.shift) }
        if modifiers.contains(.option) { terminalModifiers.insert(.option) }
        if modifiers.contains(.control) { terminalModifiers.insert(.control) }
        routingContinuation.yield(.mouse(TerminalMouseEventRequest(cell: cell, phase: phase, modifiers: terminalModifiers)))
    }

    private func applyTextSelection(for event: TerminalMouseEventRequest) {
        switch event.phase {
        case .buttonDown:
            mouseGestureReported = false
            mouseSelectionAnchor = event.cell
            setSelection(TerminalCellSelection(anchor: event.cell, focus: event.cell))
        case .drag:
            guard let anchor = mouseSelectionAnchor else { return }
            setSelection(TerminalCellSelection(anchor: anchor, focus: event.cell))
        case .buttonUp:
            if let anchor = mouseSelectionAnchor {
                setSelection(TerminalCellSelection(anchor: anchor, focus: event.cell))
            }
            mouseSelectionAnchor = nil
            mouseGestureReported = false
        }
    }

    private func finishReportedMouseEvent(_ event: TerminalMouseEventRequest) {
        switch event.phase {
        case .buttonDown:
            mouseGestureReported = true
            mouseSelectionAnchor = nil
            setSelection(nil)
        case .drag:
            break
        case .buttonUp:
            mouseGestureReported = false
            mouseSelectionAnchor = nil
        }
    }

    private func pasteControlV() {
        if let path = writeClipboardImage() {
            insertText(path, replacementRange: NSRange(location: NSNotFound, length: 0))
        } else if let text = pasteboard.string(forType: .string) {
            insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    private func pasteClipboard(allowFiles: Bool, allowImages: Bool) {
        if allowFiles, let paths = clipboardFilePaths(), !paths.isEmpty {
            insertText(paths.map(Self.shellQuotedPath).joined(separator: " "), replacementRange: NSRange(location: NSNotFound, length: 0))
        } else if allowImages, let path = writeClipboardImage() {
            insertText(path, replacementRange: NSRange(location: NSNotFound, length: 0))
        } else if let text = pasteboard.string(forType: .string) {
            insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    private func clipboardFilePaths() -> [String]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        let urls = objects.compactMap { $0 as? URL }.filter(\.isFileURL)
        if !urls.isEmpty { return urls.map { $0.standardizedFileURL.path } }

        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let filenames = pasteboard.propertyList(forType: filenamesType) as? [String] {
            return filenames.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        }
        if let value = pasteboard.string(forType: .fileURL), let url = URL(string: value), url.isFileURL {
            return [url.standardizedFileURL.path]
        }
        return nil
    }

    private func writeClipboardImage() -> String? {
        guard let png = clipboardPNGData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("corral-clipboard-\(UUID().uuidString).png")
        do {
            try png.write(to: url, options: .atomic)
            return url.standardizedFileURL.path
        } catch {
            return nil
        }
    }

    private func clipboardPNGData() -> Data? {
        var types: [NSPasteboard.PasteboardType] = [.png, .tiff]
        types.append(contentsOf: (pasteboard.types ?? []).filter {
            $0 != .png && $0 != .tiff && UTType($0.rawValue)?.conforms(to: .image) == true
        })
        for type in types {
            guard let data = pasteboard.data(forType: type), data.count <= 64 * 1024 * 1024 else { continue }
            let bitmap = NSBitmapImageRep(data: data) ?? NSImage(data: data)?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
            if let png = bitmap?.representation(using: .png, properties: [:]) { return png }
        }
        return nil
    }

    private static func shellQuotedPath(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Keeps terminal keys on standard xterm byte sequences instead of layout-dependent text insertion.
    private static func directInput(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String? {
        if modifiers.contains(.control), let value = event.charactersIgnoringModifiers?.unicodeScalars.first?.value {
            let controlValue: UInt32
            switch value {
            case 0x40...0x5f: controlValue = value & 0x1f
            case 0x61...0x7a: controlValue = value - 0x60
            case 0x3f: controlValue = 0x7f
            default: controlValue = 0
            }
            if controlValue != 0, let scalar = UnicodeScalar(controlValue) { return String(scalar) }
            if value == 0x20 || value == 0x40 { return "\0" }
        }
        if modifiers.contains(.control) {
            switch event.keyCode {
            case 8: return "\u{03}"
            case 2: return "\u{04}"
            case 6: return "\u{1a}"
            default: break
            }
        }
        switch event.keyCode {
        case 48: return "\t"
        case 51: return "\u{7f}"
        case 53: return "\u{1b}"
        case 114: return "\u{1b}[2~"
        case 115: return "\u{1b}[H"
        case 116: return "\u{1b}[5~"
        case 117: return "\u{1b}[3~"
        case 119: return "\u{1b}[F"
        case 121: return "\u{1b}[6~"
        case 122: return "\u{1b}OP"
        case 120: return "\u{1b}OQ"
        case 99: return "\u{1b}OR"
        case 118: return "\u{1b}OS"
        case 96: return "\u{1b}[15~"
        case 97: return "\u{1b}[17~"
        case 98: return "\u{1b}[18~"
        case 100: return "\u{1b}[19~"
        case 101: return "\u{1b}[20~"
        case 109: return "\u{1b}[21~"
        case 103: return "\u{1b}[23~"
        case 111: return "\u{1b}[24~"
        case 123: return "\u{1b}[D"
        case 124: return "\u{1b}[C"
        case 125: return "\u{1b}[B"
        case 126: return "\u{1b}[A"
        default: return nil
        }
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
        routingContinuation.yield(.bytes(UserInputBytes(data)))
    }

    private static func isEnter(_ event: NSEvent) -> Bool { event.keyCode == 36 || event.keyCode == 76 }

    private static func accessibleText(from snapshot: TerminalGridSnapshot, characterLimit: Int) -> String {
        guard snapshot.isValid, characterLimit > 0 else { return "" }
        var scalars = String.UnicodeScalarView()
        for row in 0..<snapshot.size.rows {
            for column in 0..<snapshot.size.columns {
                guard scalars.count < characterLimit else { return String(scalars) }
                let cell = snapshot.cells[row * snapshot.size.columns + column]
                guard let text = TerminalCellSelection.text(for: cell) else { continue }
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
