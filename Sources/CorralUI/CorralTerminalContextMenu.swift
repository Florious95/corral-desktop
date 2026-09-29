import AppKit

@MainActor
public final class CorralTerminalContextMenu: NSMenu {
    @MainActor
    public struct WorkspaceActions {
        public let onAdapt: () -> Void
        public let onClosePane: () -> Void

        public init(onAdapt: @escaping () -> Void, onClosePane: @escaping () -> Void) {
            self.onAdapt = onAdapt
            self.onClosePane = onClosePane
        }
    }

    private let copy: () -> Void
    private let paste: () -> Void
    private let clear: () -> Void
    private let selectAll: (() -> Void)?
    private let workspaceActions: WorkspaceActions?

    public init(
        onCopy: @escaping () -> Void,
        onPaste: @escaping () -> Void,
        onClear: @escaping () -> Void,
        onSelectAll: (() -> Void)? = nil,
        selectAllMenuItem: NSMenuItem? = nil,
        workspaceActions: WorkspaceActions? = nil
    ) {
        copy = onCopy
        paste = onPaste
        clear = onClear
        selectAll = onSelectAll
        self.workspaceActions = workspaceActions
        super.init(title: "Terminal")
        autoenablesItems = false
        if workspaceActions != nil {
            addItem("适应当前窗口", action: #selector(adaptCurrentWindow))
            addItem("关闭此分屏", action: #selector(closePane))
            addItem(.separator())
        }
        addItem("复制", action: #selector(copySelection))
        addItem("粘贴", action: #selector(pasteClipboard))
        if let selectAllMenuItem { addItem(selectAllMenuItem) }
        else if selectAll != nil { addItem("全选", action: #selector(selectAllItems)) }
        addItem(.separator())
        addItem("清屏", action: #selector(clearScreen))
    }

    public required init(coder: NSCoder) { fatalError("CorralTerminalContextMenu is created programmatically") }

    private func addItem(_ title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        addItem(item)
    }

    @objc private func adaptCurrentWindow() { workspaceActions?.onAdapt() }
    @objc private func closePane() { workspaceActions?.onClosePane() }
    @objc private func copySelection() { copy() }
    @objc private func pasteClipboard() { paste() }
    @objc private func selectAllItems() { selectAll?() }
    @objc private func clearScreen() { clear() }
}
