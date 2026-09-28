import AppKit
import CorralMetalTerminal
import CorralUI
@preconcurrency import SwiftTerm

@MainActor
final class CorralNativeTerminalView: TerminalView {
    static let defaultForegroundColor = NSColor(srgbRed: 213.0 / 255, green: 220.0 / 255, blue: 230.0 / 255, alpha: 1)
    static let defaultBackgroundColor = NSColor(srgbRed: 16.0 / 255, green: 17.0 / 255, blue: 21.0 / 255, alpha: 1)

    private let pasteboard: NSPasteboard
    private var displayFilter = CorralTerminalFilter()
    private var inputEnabled = true
    var onFocus: (() -> Void)?
    var onDiscardedAutomaticReply: ((Int) -> Void)?

    override init(frame: CGRect) {
        pasteboard = .general
        super.init(frame: frame)
        installDarkColors()
    }

    init(frame: CGRect, pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        super.init(frame: frame)
        installDarkColors()
    }

    required init?(coder: NSCoder) {
        pasteboard = .general
        super.init(coder: coder)
        installDarkColors()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onFocus?()
        super.mouseDown(with: event)
    }

    func setTerminalFont(family: String, size: Int) {
        let pointSize = CGFloat(size)
        let resolved = family.split(separator: ",").lazy.compactMap { candidate in
            NSFont(name: String(candidate).trimmingCharacters(in: CharacterSet(charactersIn: " \"'\t")), size: pointSize)
        }.first ?? NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        if font != resolved { font = resolved }
    }

    private func installDarkColors() {
        installColors(CorralTerminalPalette.darkANSI16)
        setTerminalColors(foreground: Self.defaultForegroundColor, background: Self.defaultBackgroundColor)
    }

    func setTerminalColors(foreground: NSColor, background: NSColor) {
        if let color = Self.swiftTermColor(foreground) { getTerminal().foregroundColor = color }
        if let color = Self.swiftTermColor(background) { getTerminal().backgroundColor = color }
        needsDisplay = true
    }

    func replaceSnapshot(_ bytes: Data) {
        getTerminal().resetToInitialState()
        displayFilter.reset()
        let normalized = Data(Self.normalizeSnapshotLineEndings(bytes))
        let mapped = CorralTerminalFilter.remapTrueColorBackground(normalized)
        feed(byteArray: Array(mapped)[...])
    }

    func feedRemoteANSI(_ bytes: ArraySlice<UInt8>) {
        let mapped = displayFilter.process(Data(bytes))
        guard !mapped.isEmpty else { return }
        feed(byteArray: Array(mapped)[...])
    }

    func finishRemoteANSI() {
        let remaining = displayFilter.finish()
        guard !remaining.isEmpty else { return }
        feed(byteArray: Array(remaining)[...])
    }

    private static func normalizeSnapshotLineEndings(_ data: Data) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count)
        var previous: UInt8?
        for byte in data {
            if byte == 0x0A, previous != 0x0D { bytes.append(0x0D) }
            bytes.append(byte)
            previous = byte
        }
        return bytes
    }

    private static func swiftTermColor(_ source: NSColor) -> Color? {
        guard let color = source.usingColorSpace(.deviceRGB) else { return nil }
        func component(_ value: CGFloat) -> UInt16 {
            UInt16(min(255, max(0, Int((value * 255).rounded()))))
        }
        return Color(red8: component(color.redComponent), green8: component(color.greenComponent), blue8: component(color.blueComponent))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackingScale()
        if let window = window as? CorralWindow {
            window.onTerminalKeyDown = { [weak window] event in
                guard let window, event.window === window,
                      let view = window.firstResponder as? CorralNativeTerminalView,
                      view.inputEnabled else { return false }
                return view.handleControlVPaste(event: event)
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingScale()
    }

    private func updateBackingScale() {
        guard let window else { return }
        layer?.contentsScale = window.backingScaleFactor
        // SwiftTerm snaps cell metrics in its font setter using the current window scale.
        let currentFont = font
        font = currentFont
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard Self.isCommandVPaste(event), event.window === window,
              window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        handleCommandVPaste()
        return true
    }

    override func interpretKeyEvents(_ eventArray: [NSEvent]) {
        guard eventArray.contains(where: Self.isCommandVPaste) else {
            super.interpretKeyEvents(eventArray)
            return
        }
        handleCommandVPaste()
    }

    override func paste(_ sender: Any) {
        handleCommandVPaste()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = CorralTerminalContextMenu(
            onCopy: { [weak self] in guard let self else { return }; self.copy(self) },
            onPaste: { [weak self] in guard let self else { return }; self.paste(self) },
            onClear: { [weak self] in guard let self else { return }; self.clearTerminalBuffer(self) }
        )
        let selectAll = NSMenuItem(title: "全选", action: #selector(selectAll(_:)), keyEquivalent: "")
        selectAll.target = self
        menu.insertItem(selectAll, at: 2)
        return menu
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(clearTerminalBuffer(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    @objc private func clearTerminalBuffer(_ sender: Any?) {
        selection.selectNone()
        getTerminal().buffer.clear()
        needsDisplay = true
    }

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard SwiftTermVTReplyFilter.isMouseReport(data) || !SwiftTermVTReplyFilter.isAutomaticResponse(data) else {
            onDiscardedAutomaticReply?(data.count)
            return
        }
        terminalDelegate?.send(source: self, data: data)
    }

    /// Ctrl+V belongs to the terminal responder, alongside ordinary keyboard input.
    func handleControlVPaste(event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isVKey = event.keyCode == 9 || event.charactersIgnoringModifiers?.lowercased() == "v"
        guard isVKey, modifiers.contains(.control), !modifiers.contains(.command) else { return false }
        _ = pasteFromClipboard(trigger: .controlV)
        return true
    }

    func setInputEnabled(_ enabled: Bool) { inputEnabled = enabled }

    private func handleCommandVPaste() {
        if !pasteFromClipboard(trigger: .commandV) { super.paste(self) }
    }

    private static func isCommandVPaste(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isVKey = event.keyCode == 9 || event.charactersIgnoringModifiers?.lowercased() == "v"
        return isVKey && modifiers.contains(.command) && !modifiers.contains(.control)
    }

    @discardableResult
    private func pasteFromClipboard(trigger: TerminalClipboardPasteTrigger) -> Bool {
        TerminalClipboardPasteHandler.handle(pasteboard: pasteboard, trigger: trigger) { [weak self] userBytes in
            guard let self else { return }
            var payload: [UInt8] = []
            if getTerminal().bracketedPasteMode {
                payload.append(contentsOf: [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e])
            }
            payload.append(contentsOf: userBytes)
            if getTerminal().bracketedPasteMode {
                payload.append(contentsOf: [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e])
            }
            send(data: payload[...])
        }
    }
}

private enum SwiftTermVTReplyFilter {
    static func isMouseReport(_ data: ArraySlice<UInt8>) -> Bool {
        let bytes = Array(data)
        return bytes.starts(with: [0x1b, 0x5b, 0x3c]) || bytes.starts(with: [0x1b, 0x5b, 0x4d])
    }

    static func isAutomaticResponse(_ data: ArraySlice<UInt8>) -> Bool {
        let bytes = Array(data)
        guard bytes.count >= 2, bytes[0] == 0x1b else { return false }
        if bytes[1] == 0x5d || bytes[1] == 0x50 { return true }
        guard bytes.count >= 3, bytes[1] == 0x5b else { return false }
        let final = bytes[bytes.count - 1]
        guard [0x6e, 0x63, 0x79, 0x74, 0x49, 0x4f, 0x52].contains(final) else { return false }
        return bytes[2..<(bytes.count - 1)].allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || [0x3b, 0x3f, 0x3e, 0x24].contains($0)
        }
    }
}
