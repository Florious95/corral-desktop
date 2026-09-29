import AppKit

@MainActor
public final class CorralTerminalContextMenu: NSMenu, NSMenuDelegate {
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
        delegate = self
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

    public func menuNeedsUpdate(_ menu: NSMenu) { removeAutoFillItems(from: menu) }
    public func menuWillOpen(_ menu: NSMenu) { removeAutoFillItems(from: menu) }

    private func removeAutoFillItems(from menu: NSMenu) {
        for index in menu.items.indices.reversed() {
            let item = menu.items[index]
            let hasAutoFillTitle = Self.isAutoFillTitle(item.title)
                || item.submenu.map { Self.isAutoFillTitle($0.title) } == true
            if hasAutoFillTitle {
                menu.removeItem(at: index)
            } else if let submenu = item.submenu {
                removeAutoFillItems(from: submenu)
            }
        }
    }

    private static func isAutoFillTitle(_ title: String) -> Bool {
        title.localizedCaseInsensitiveContains("autofill")
            || title.localizedCaseInsensitiveContains("auto fill")
            || title.localizedCaseInsensitiveContains("自动填充")
    }

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
