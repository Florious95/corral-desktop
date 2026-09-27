import AppKit
import CorralMetalTerminal
@preconcurrency import SwiftTerm

private struct LocalPasteMonitorToken: @unchecked Sendable {
    let value: Any
}

@MainActor
final class CorralNativeTerminalView: TerminalView {
    private let pasteboard: NSPasteboard
    private var controlVPasteMonitor: LocalPasteMonitorToken?

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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { removeControlVPasteMonitor() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installControlVPasteMonitor()
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
        let menu = NSMenu(title: "Terminal")
        for (title, action) in [
            ("Copy", #selector(copy(_:))),
            ("Paste", #selector(paste(_:))),
            ("Select All", #selector(selectAll(_:)))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clearItem = NSMenuItem(title: "Clear Buffer", action: #selector(clearTerminalBuffer(_:)), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
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
        guard !SwiftTermVTReplyFilter.isAutomaticResponse(data) else { return }
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
