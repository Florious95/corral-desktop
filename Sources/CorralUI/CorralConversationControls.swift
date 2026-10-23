import AppKit

public struct CorralModelChoice: Equatable, Sendable {
    public let id, provider, name: String
    public init(id: String, provider: String, name: String) { self.id = id; self.provider = provider; self.name = name }
}
public struct CorralCommandChoice: Equatable, Sendable {
    public let name, detail, source: String
    public init(name: String, detail: String, source: String) { self.name = name; self.detail = detail; self.source = source }
}
public struct CorralPromptTemplate: Codable, Equatable, Sendable {
    public let id: UUID
    public var title, text: String
    public init(id: UUID = UUID(), title: String, text: String) { self.id = id; self.title = title; self.text = text }
}
public struct CorralComposerAttachment: Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let isImage: Bool
    public var remotePath: String?
    public var preview: Data?
    public init(id: UUID = UUID(), url: URL, isImage: Bool, remotePath: String? = nil, preview: Data? = nil) {
        self.id = id; self.url = url; self.isImage = isImage; self.remotePath = remotePath; self.preview = preview
    }
}

/// A native popover whose controls are backed exclusively by the current model's native catalogs.
@MainActor
public final class CorralModelPickerController: NSViewController {
    public let modelButton = NSPopUpButton()
    public let thinkingButton = NSPopUpButton()
    public let statusLabel = NSTextField(wrappingLabelWithString: "")
    public var onModel: ((CorralModelChoice) -> Void)?
    public var onLevel: ((String) -> Void)?
    public var onRefresh: (() -> Void)?
    private var models: [CorralModelChoice] = []
    private var levels: [String] = []
    private var popover: NSPopover?
    private struct Snapshot: Equatable {
        let models: [CorralModelChoice]; let levels: [String]
        let provider, model, level: String?
        let enabled, pending: Bool
        let status: String
    }
    private var snapshot: Snapshot?
    private let refresh = NSButton(title: "刷新", target: nil, action: nil)
    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 370, height: 264))
        let heading = NSTextField(labelWithString: "模型与思考")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        let modelLabel = NSTextField(labelWithString: "模型 · Provider")
        let levelLabel = NSTextField(labelWithString: "思考强度 · 仅显示当前模型支持项")
        for label in [modelLabel, levelLabel] { label.font = .systemFont(ofSize: 11); label.textColor = CorralAestheticTokens.textMuted }
        modelButton.target = self; modelButton.action = #selector(selectModel)
        thinkingButton.target = self; thinkingButton.action = #selector(selectLevel)
        refresh.target = self; refresh.action = #selector(reload)
        modelButton.setAccessibilityIdentifier("corral.model.choices")
        thinkingButton.setAccessibilityIdentifier("corral.thinking.choices")
        refresh.setAccessibilityIdentifier("corral.model.refresh")
        statusLabel.setAccessibilityIdentifier("corral.model.status")
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = CorralAestheticTokens.textMuted
        statusLabel.maximumNumberOfLines = 3
        let stack = NSStackView(views: [heading, modelLabel, modelButton, levelLabel, thinkingButton, statusLabel, refresh])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14), stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -12)])
        for child in [modelButton, thinkingButton, statusLabel] as [NSView] { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        preferredContentSize = view.frame.size
    }
    public func present(relativeTo source: NSView) {
        guard source.window != nil else { return }
        loadViewIfNeeded()
        let panel = NSPopover(); panel.behavior = .transient; panel.contentViewController = self
        panel.contentSize = preferredContentSize; popover = panel
        panel.show(relativeTo: source.bounds, of: source, preferredEdge: .maxY)
    }
    public func close() { popover?.close(); popover = nil }
    public func apply(models: [CorralModelChoice], levels: [String], currentProvider: String?, currentModel: String?, currentLevel: String?, enabled: Bool, pending: Bool, status: String) {
        loadViewIfNeeded()
        let next = Snapshot(models: models, levels: levels, provider: currentProvider, model: currentModel, level: currentLevel, enabled: enabled, pending: pending, status: status)
        guard snapshot != next else { return }; snapshot = next
        self.models = models; self.levels = levels
        // NSPopUpButton.addItem(withTitle:) removes an existing equal title. Native models may share names.
        func append(_ button: NSPopUpButton, _ title: String) { button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: "")) }
        modelButton.menu = NSMenu(); modelButton.menu?.autoenablesItems = false
        append(modelButton, currentModel ?? "请选择模型"); modelButton.lastItem?.isEnabled = false
        for model in models { append(modelButton, "\(model.name) · \(model.provider)"); modelButton.lastItem?.toolTip = model.id }
        modelButton.selectItem(at: models.firstIndex(where: { $0.id == currentModel && $0.provider == currentProvider }).map { $0 + 1 } ?? 0)
        thinkingButton.menu = NSMenu(); thinkingButton.menu?.autoenablesItems = false
        append(thinkingButton, currentLevel.map { "当前：" + Self.levelTitle($0) } ?? "等待原生选项"); thinkingButton.lastItem?.isEnabled = false
        for level in levels { append(thinkingButton, Self.levelTitle(level)) }
        thinkingButton.selectItem(at: levels.firstIndex(of: currentLevel ?? "").map { $0 + 1 } ?? 0)
        modelButton.isEnabled = enabled && !pending && !models.isEmpty
        thinkingButton.isEnabled = enabled && !pending && !levels.isEmpty
        refresh.isEnabled = enabled && !pending; statusLabel.stringValue = status
    }
    public static func levelTitle(_ value: String) -> String {
        switch value { case "off": "关"; case "minimal": "最少"; case "low": "低"; case "medium": "中"; case "high": "高"; case "xhigh": "超高"; case "max": "最高"; default: value }
    }
    @objc private func selectModel() { let i = modelButton.indexOfSelectedItem - 1; if models.indices.contains(i) { onModel?(models[i]) } }
    @objc private func selectLevel() { let i = thinkingButton.indexOfSelectedItem - 1; if levels.indices.contains(i) { onLevel?(levels[i]) } }
    @objc private func reload() { onRefresh?() }
}

/// Local prompt CRUD; applying a template is always a separate explicit action, never a model send.
@MainActor
public final class CorralPromptLibraryController: CorralDialogViewController, NSTableViewDataSource, NSTableViewDelegate {
    public var onSave: (([CorralPromptTemplate]) -> Bool)?
    public var onUse: ((String) -> Void)?
    public private(set) var templates: [CorralPromptTemplate]
    public let titleField = NSTextField()
    public let editor = NSTextView()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private var editingID: UUID?
    public init(templates: [CorralPromptTemplate]) { self.templates = templates; super.init() }
    public required init?(coder: NSCoder) { nil }
    public override func loadView() {
        view = rootView(size: NSSize(width: 540, height: 490))
        view.setAccessibilityIdentifier("corral.prompts.library")
        let heading = NSTextField(labelWithString: "快捷指令与 Prompt 模板")
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        let list = NSScrollView(); list.hasVerticalScroller = true; list.documentView = table
        let column = NSTableColumn(identifier: .init("title")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 28; table.dataSource = self; table.delegate = self
        table.setAccessibilityIdentifier("corral.prompts.list")
        titleField.placeholderString = "模板名称"; titleField.setAccessibilityIdentifier("corral.prompts.title")
        editor.isRichText = false; editor.importsGraphics = false; editor.font = .systemFont(ofSize: 13)
        editor.textContainerInset = NSSize(width: 8, height: 8); editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityIdentifier("corral.prompts.editor")
        let text = NSScrollView(); text.hasVerticalScroller = true; text.documentView = editor
        let add = NSButton(title: "新增", target: self, action: #selector(addTemplate))
        let save = NSButton(title: "保存", target: self, action: #selector(saveTemplate))
        let delete = NSButton(title: "删除", target: self, action: #selector(deleteTemplate))
        let use = NSButton(title: "插入草稿", target: self, action: #selector(useTemplate))
        let close = NSButton(title: "关闭", target: self, action: #selector(closeLibrary))
        for (button, id) in [(add,"add"),(save,"save"),(delete,"delete"),(use,"use"),(close,"close")] { button.setAccessibilityIdentifier("corral.prompts." + id) }
        let buttons = NSStackView(views: [add, save, delete, use, close]); buttons.spacing = 8
        status.font = .systemFont(ofSize: 11); status.textColor = CorralAestheticTokens.textMuted
        let stack = NSStackView(views: [heading, list, titleField, text, status, buttons]); stack.orientation = .vertical; stack.spacing = 12; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20), list.heightAnchor.constraint(equalToConstant: 108), text.heightAnchor.constraint(equalToConstant: 184)])
        for child in [list, titleField, text, status] as [NSView] { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        status.stringValue = "保存在当前客户端；插入只追加草稿，不自动发送。"
    }
    public func numberOfRows(in tableView: NSTableView) -> Int { templates.count }
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { NSTextField(labelWithString: templates[row].title) }
    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard templates.indices.contains(table.selectedRow) else { return }
        let value = templates[table.selectedRow]; editingID = value.id; titleField.stringValue = value.title; editor.string = value.text
    }
    @objc private func addTemplate() { editingID = nil; table.deselectAll(nil); titleField.stringValue = ""; editor.string = ""; view.window?.makeFirstResponder(titleField) }
    @objc private func saveTemplate() {
        guard !editor.hasMarkedText(), (titleField.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        let name = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, !editor.string.isEmpty else { status.stringValue = "请填写名称（最多120字符）与内容。"; return }
        var updated = templates
        let item = CorralPromptTemplate(id: editingID ?? UUID(), title: name, text: editor.string)
        if let i = updated.firstIndex(where: { $0.id == item.id }) { updated[i] = item } else { updated.append(item) }
        guard onSave?(updated) == true else { status.stringValue = "未保存：最多100项、合计1MiB。"; return }
        templates = updated; editingID = item.id; table.reloadData(); status.stringValue = "已保存"
    }
    @objc private func deleteTemplate() {
        guard let editingID else { return }
        let updated = templates.filter { $0.id != editingID }
        guard onSave?(updated) == true else { return }
        templates = updated; table.reloadData(); addTemplate(); status.stringValue = "已删除"
    }
    @objc private func useTemplate() { guard !editor.hasMarkedText(), !editor.string.isEmpty else { return }; onUse?(editor.string); closeDialog() }
    @objc private func closeLibrary() { closeDialog() }
}
