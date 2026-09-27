import AppKit
import CorralMetalTerminal
import CorralUI
@preconcurrency import SwiftTerm

private struct LocalPasteMonitorToken: @unchecked Sendable {
    let value: Any
}

@MainActor
final class CorralNativeTerminalView: TerminalView {
    private let pasteboard: NSPasteboard
    private var controlVPasteMonitor: LocalPasteMonitorToken?
    private var inputEnabled = false
    var onDiscardedAutomaticReply: ((Int) -> Void)?

    override init(frame: CGRect) {
        pasteboard = .general
        super.init(frame: frame)
    }

    init(frame: CGRect, pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        pasteboard = .general
        super.init(coder: coder)
    }

    deinit {
        if let controlVPasteMonitor { NSEvent.removeMonitor(controlVPasteMonitor.value) }
    }

    func setTerminalFont(family: String, size: Int) {
        let pointSize = CGFloat(size)
        font = NSFont(name: family, size: pointSize) ?? NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
    }

    func setTerminalColors(foreground: NSColor, background: NSColor) {
        if let color = Self.swiftTermColor(foreground) { getTerminal().foregroundColor = color }
        if let color = Self.swiftTermColor(background) { getTerminal().backgroundColor = color }
        needsDisplay = true
    }

    private static func swiftTermColor(_ source: NSColor) -> Color? {
        guard let color = source.usingColorSpace(.deviceRGB) else { return nil }
        func component(_ value: CGFloat) -> UInt16 {
            UInt16(min(255, max(0, Int((value * 255).rounded()))))
        }
        return Color(red8: component(color.redComponent), green8: component(color.greenComponent), blue8: component(color.blueComponent))
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { removeControlVPasteMonitor() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if inputEnabled { installControlVPasteMonitor() }
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
        if SwiftTermVTReplyFilter.isAutomaticResponse(data) {
            onDiscardedAutomaticReply?(data.count)
            return
        }
        terminalDelegate?.send(source: self, data: data)
    }

    /// Shared by the local event monitor and synthetic-event tests.
    func handleControlVPaste(event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isVKey = event.keyCode == 9 || event.charactersIgnoringModifiers?.lowercased() == "v"
        guard isVKey, modifiers.contains(.control), !modifiers.contains(.command) else { return false }
        _ = pasteFromClipboard(trigger: .controlV)
        return true
    }

    func setInputEnabled(_ enabled: Bool) {
        guard inputEnabled != enabled else { return }
        inputEnabled = enabled
        if enabled { installControlVPasteMonitor() }
        else { removeControlVPasteMonitor() }
    }

    private func installControlVPasteMonitor() {
        removeControlVPasteMonitor()
        guard window != nil else { return }
        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated {
                event.window === self.window
                    && self.window?.firstResponder === self
                    && self.handleControlVPaste(event: event)
            }
            return consumed ? nil : event
        }) else { return }
        controlVPasteMonitor = LocalPasteMonitorToken(value: monitor)
    }

    private func removeControlVPasteMonitor() {
        if let controlVPasteMonitor {
            NSEvent.removeMonitor(controlVPasteMonitor.value)
            self.controlVPasteMonitor = nil
        }
    }

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
    static func isAutomaticResponse(_ data: ArraySlice<UInt8>) -> Bool {
        let bytes = Array(data)
        guard bytes.count >= 2, bytes[0] == 0x1b else { return false }
        if bytes[1] == 0x5d || bytes[1] == 0x50 { return true } // OSC and DCS replies
        guard bytes.count >= 3, bytes[1] == 0x5b else { return false }
        let final = bytes[bytes.count - 1]
        guard [0x6e, 0x63, 0x79, 0x74, 0x49, 0x4f, 0x52].contains(final) else { return false }
        return bytes[2..<(bytes.count - 1)].allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || [0x3b, 0x3f, 0x3e, 0x24].contains($0)
        }
    }
}
