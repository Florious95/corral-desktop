import AppKit
import UniformTypeIdentifiers

public struct CorralSessionChoice: Equatable, Sendable {
    public let id, title, detail: String
    public let current: Bool
    public init(id: String, title: String, detail: String, current: Bool = false) {
        self.id = id; self.title = title; self.detail = detail; self.current = current
    }
}

/// Independent native selection/configuration/confirmation surfaces, never transcript messages or slash commands.
@MainActor
public final class CorralSessionActionPanel: CorralDialogViewController, NSTableViewDataSource, NSTableViewDelegate {
    public let action: CorralActionID
    public var onSubmit: ((String?, String) -> Void)?
    public var onReload: (() -> Void)?
    public var onClose: (() -> Void)?
    public private(set) var choices: [CorralSessionChoice] = []
    public let table = NSTableView()
    public let instructions = NSTextView()
    public let statusLabel = NSTextField(wrappingLabelWithString: "")
    public private(set) var busy = false
    public private(set) var completed = false
    public private(set) var requiresForce = false
    public private(set) var savePanel: NSSavePanel?
    public var selectedID: String? { choices.indices.contains(table.selectedRow) ? choices[table.selectedRow].id : nil }
    /// Only test harnesses replace the user response; production always presents this real NSSavePanel.
    public var savePanelPresenter: ((NSSavePanel, NSWindow?, @escaping (NSApplication.ModalResponse, URL?) -> Void) -> Void)?
    private let sessionTitle: String
    private var primary: NSButton!
    private var close: NSButton!
    private var reload: NSButton?
    private var allowsClose = true
    public override var canDismissWithEscape: Bool { allowsClose }
    private var isPicker: Bool { action == .history || action == .fork }

    public init(action: CorralActionID, sessionTitle: String) {
        self.action = action; self.sessionTitle = sessionTitle
        super.init()
    }
    public required init?(coder: NSCoder) { nil }

    public override func loadView() {
        let height: CGFloat = isPicker ? 460 : action == .compact ? 362 : 264
        view = rootView(size: NSSize(width: 540, height: height))
        view.setAccessibilityIdentifier("corral.action.panel.\(action.rawValue)")
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
                                     stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
                                     stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24)])
        func row(_ child: NSView, _ height: CGFloat) {
            stack.addArrangedSubview(child)
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            child.heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        let title = NSTextField(labelWithString: CorralActionSpec.spec(action).title)
        title.font = .systemFont(ofSize: 20, weight: .semibold); title.textColor = CorralAestheticTokens.text
        row(title, 26)
        let subtitle = NSTextField(labelWithString: sessionTitle)
        subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = CorralAestheticTokens.textMuted
        subtitle.lineBreakMode = .byTruncatingMiddle; subtitle.toolTip = sessionTitle
        row(subtitle, 16); stack.setCustomSpacing(4, after: title)
        let description = NSTextField(wrappingLabelWithString: explanation)
        description.font = .systemFont(ofSize: 12); description.textColor = CorralAestheticTokens.textSecondary
        row(description, 40)
        if isPicker {
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.drawsBackground = false; scroll.borderType = .noBorder
            let column = NSTableColumn(identifier: .init("choice")); column.resizingMask = .autoresizingMask
            table.addTableColumn(column); table.headerView = nil; table.rowHeight = 54
            table.style = .plain; table.backgroundColor = .clear; table.intercellSpacing = NSSize(width: 0, height: 4)
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle; table.dataSource = self; table.delegate = self
            table.setAccessibilityIdentifier("corral.action.choices")
            scroll.documentView = table
            row(scroll, 196)
        } else if action == .compact {
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.wantsLayer = true; scroll.layer?.cornerRadius = 8; scroll.layer?.borderWidth = 1; scroll.layer?.borderColor = CorralAestheticTokens.border.cgColor
            instructions.isRichText = false; instructions.importsGraphics = false
            instructions.font = .systemFont(ofSize: 13); instructions.textColor = CorralAestheticTokens.text
            instructions.backgroundColor = CorralAestheticTokens.fieldBackground
            instructions.textContainerInset = NSSize(width: 10, height: 10)
            instructions.isHorizontallyResizable = false; instructions.isVerticallyResizable = true
            instructions.autoresizingMask = [.width]; instructions.textContainer?.widthTracksTextView = true
            instructions.setAccessibilityIdentifier("corral.action.instructions")
            instructions.setAccessibilityLabel("保留重点（可选）")
            scroll.documentView = instructions
            row(scroll, 98)
        }
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = CorralAestheticTokens.textMuted
        statusLabel.setAccessibilityIdentifier("corral.action.status")
        row(statusLabel, 34)
        primary = CorralDialogButton(title: submitTitle, kind: .primary, target: self, action: #selector(submitClicked))
        primary.setAccessibilityIdentifier("corral.action.submit")
        close = CorralDialogButton(title: "取消", kind: .plain, target: self, action: #selector(closeClicked))
        close.setAccessibilityIdentifier("corral.action.cancel")
        var leading: [NSButton] = []
        if isPicker {
            let refresh = CorralDialogButton(title: "刷新", kind: .secondary, target: self, action: #selector(reloadClicked))
            refresh.setAccessibilityIdentifier("corral.action.reload")
            reload = refresh; leading = [refresh]
        }
        row(actionsRow([close, primary], leading: leading), 33)
        updateButtons()
    }

    public override func present(over window: NSWindow? = NSApp.keyWindow) {
        guard let window, let content = window.contentView else { return }
        loadViewIfNeeded()
        let height = min(view.frame.height, max(280, content.bounds.height - 32))
        let difference = view.frame.height - height
        if difference > 0, let scroll = (isPicker ? table.enclosingScrollView : instructions.enclosingScrollView),
           let constraint = scroll.constraints.first(where: { $0.firstAttribute == .height && $0.secondItem == nil }) {
            constraint.constant = max(42, constraint.constant - difference)
        }
        view.setFrameSize(NSSize(width: min(540, max(280, content.bounds.width - 32)), height: height))
        super.present(over: window)
    }

    private var explanation: String {
        switch action {
        case .history: "选择主机原生历史会话并切换；原会话与各自草稿保留。只使用主机提供的会话身份，不接受文件路径。"
        case .fork: "选择一条用户消息，在它之前创建分叉；该消息原文将带回新会话草稿，原会话不变。"
        case .newSession: "在同一原生进程开始新会话，分配新的会话身份。当前历史与草稿保留，不会删除原会话。"
        case .clone: "复制当前完整原生会话上下文并切换到克隆；原会话保持不变。空会话可能无法克隆。"
        case .compact: "可填写需要保留的重点（最多 8192 UTF-8 字节），交由原生压缩器处理。不会编造节省比例或删除历史。"
        case .export: "导出原生会话 HTML，可能包含对话、工具输出与敏感信息。请选择可信的本地保存位置；不会上传或公开分享。"
        default: ""
        }
    }
    private var submitTitle: String {
        switch action {
        case .history: "切换会话"
        case .fork: "创建分叉"
        case .newSession: "开始新会话"
        case .clone: "克隆会话"
        case .compact: "开始压缩"
        case .export: "选择保存位置…"
        default: "确认"
        }
    }
    public func setChoices(_ rows: [CorralSessionChoice]) {
        choices = rows
        loadViewIfNeeded(); table.reloadData(); table.deselectAll(nil)
        updateButtons()
    }
    public func setStatus(_ text: String, busy: Bool = false, error: Bool = false, completed: Bool = false, requiresForce: Bool = false, allowsClose: Bool = true) {
        self.busy = busy; self.completed = completed; self.requiresForce = requiresForce; self.allowsClose = allowsClose
        loadViewIfNeeded()
        statusLabel.stringValue = text
        statusLabel.textColor = error ? CorralAestheticTokens.warnText : CorralAestheticTokens.textMuted
        statusLabel.toolTip = text
        updateButtons()
    }
    private func updateButtons() {
        guard isViewLoaded, primary != nil else { return }
        primary.title = completed ? "完成" : requiresForce ? "停止任务并继续" : submitTitle
        primary.isEnabled = !busy && (completed || !isPicker || selectedID != nil)
        close.isEnabled = allowsClose; close.title = completed ? "关闭" : "取消"
        reload?.isEnabled = !busy
        table.isEnabled = !busy; instructions.isEditable = !busy
    }
    public func numberOfRows(in tableView: NSTableView) -> Int { choices.count }
    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !busy && !choices[row].current }
    public func tableViewSelectionDidChange(_ notification: Notification) { requiresForce = false; updateButtons() }
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let choice = choices[row]
        let text = NSTextField(wrappingLabelWithString: "\(choice.current ? "当前 · " : "")\(choice.title)\n\(choice.detail)")
        text.font = .systemFont(ofSize: 12); text.textColor = choice.current ? CorralAestheticTokens.textMuted : CorralAestheticTokens.text
        text.maximumNumberOfLines = 3; text.lineBreakMode = .byTruncatingTail
        text.toolTip = choice.title + "\n" + choice.detail
        text.setAccessibilityIdentifier("corral.action.choice.\(choice.id)")
        return text
    }
    public func selectChoice(_ id: String) -> Bool {
        guard !busy, let index = choices.firstIndex(where: { $0.id == id && !$0.current }) else { return false }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        return true
    }
    @objc private func submitClicked() {
        guard primary.isEnabled else { return }
        if completed { handleEscape(); return }
        onSubmit?(selectedID, instructions.string)
    }
    @objc private func reloadClicked() { if !busy { onReload?() } }
    @objc private func closeClicked() { handleEscape() }
    public override func handleEscape() { guard allowsClose else { return }; closeDialog(); onClose?() }

    public func chooseExportDestination(_ completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.title = "导出原生会话"; panel.message = "HTML 可能包含对话、工具输出与敏感信息。"
        panel.allowedContentTypes = [.html]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Corral 会话.html"
        savePanel = panel
        let result: (NSApplication.ModalResponse, URL?) -> Void = { [weak self] response, url in
            self?.savePanel = nil
            completion(response == .OK ? url : nil)
        }
        if let savePanelPresenter { savePanelPresenter(panel, presentedWindow, result) }
        else if let window = presentedWindow { panel.beginSheetModal(for: window) { result($0, panel.url) } }
        else { completion(nil) }
    }
}
