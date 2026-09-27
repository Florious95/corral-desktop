import AppKit

@MainActor
public final class CorralTerminalContextMenu: NSMenu {
    private let copy: () -> Void
    private let paste: () -> Void
    private let clear: () -> Void

    public init(onCopy: @escaping () -> Void, onPaste: @escaping () -> Void, onClear: @escaping () -> Void) {
        copy = onCopy
        paste = onPaste
        clear = onClear
        super.init(title: "Terminal")
        autoenablesItems = false
        addItem("复制", action: #selector(copySelection))
        addItem("粘贴", action: #selector(pasteClipboard))
        addItem(.separator())
        addItem("清屏", action: #selector(clearScreen))
    }

    public required init(coder: NSCoder) { fatalError("CorralTerminalContextMenu is created programmatically") }

    private func addItem(_ title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        addItem(item)
    }

    @objc private func copySelection() { copy() }
    @objc private func pasteClipboard() { paste() }
    @objc private func clearScreen() { clear() }
}
