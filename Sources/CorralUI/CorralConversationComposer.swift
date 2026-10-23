import AppKit
import QuartzCore

public struct CorralComposerState: Equatable, Sendable {
    public var ready: Bool
    public var running: Bool?
    public var sending: Bool
    public var stopping: Bool
    public var message: String?
    public var isError: Bool
    public init(ready: Bool = false, running: Bool? = nil, sending: Bool = false, stopping: Bool = false,
                message: String? = nil, isError: Bool = false) {
        self.ready = ready; self.running = running; self.sending = sending; self.stopping = stopping
        self.message = message; self.isError = isError
    }
}

public struct CorralComposerSuggestion: Equatable, Sendable {
    public let id, title, detail, text: String
    public init(id: String, title: String, detail: String, text: String) { self.id = id; self.title = title; self.detail = detail; self.text = text }
}

/// TextKit owns composition/undo/paste. Navigation is intercepted only outside marked text.
@MainActor
public final class CorralComposerTextView: NSTextView {
    public var onSubmit: (() -> Void)?
    public var onFocus: (() -> Void)?
    public var onCompletionKey: ((UInt16) -> Bool)?
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) { onFocus?(); super.mouseDown(with: event) }
    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if modifiers.isEmpty, !hasMarkedText() {
            if onCompletionKey?(event.keyCode) == true { return }
            if event.keyCode == 36 || event.keyCode == 76 { if !event.isARepeat { onSubmit?() }; return }
        }
        super.keyDown(with: event)
    }
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            ("发送消息，输入 / 查看命令…" as NSString).draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height),
                withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: CorralAestheticTokens.textMuted])
        }
    }
}

/// A stable native editor with an inline completion shelf; showing choices never steals IME focus.
@MainActor
public final class CorralConversationComposer: NSView, NSTextViewDelegate, NSTableViewDataSource {
    public let editor = CorralComposerTextView()
    public let actionButton = NSButton()
    public let stopButton = NSButton()
    public let slashButton = NSButton(title: "/", target: nil, action: nil)
    public let shortcutsButton = NSButton(title: "⚡", target: nil, action: nil)
    public let attachButton = NSButton(title: "+", target: nil, action: nil)
    public let statusLabel = NSTextField(labelWithString: "")
    public let scrollView = NSScrollView()
    public var onSubmit: (() -> Void)?
    public var onAbort: (() -> Void)?
    public var onDraftChange: ((String) -> Void)?
    public var onHeightChange: (() -> Void)?
    public var onFocus: (() -> Void)?
    public var onSlash: (() -> Void)?
    public var onShortcuts: (() -> Void)?
    public var onAttach: (() -> Void)?
    public var onManageTemplates: (() -> Void)?
    public var onRemoveAttachment: ((UUID) -> Void)?
    public var onChooseSuggestion: ((CorralComposerSuggestion) -> Void)?
    public var onDismissSuggestions: (() -> Void)?
    public private(set) var state = CorralComposerState()
    public private(set) var preferredHeight: CGFloat = 88
    public private(set) var suggestions: [CorralComposerSuggestion] = []
    public private(set) var attachments: [CorralComposerAttachment] = []
    private let card = NSView()
    private let choicesScroll = NSScrollView()
    private let choices = NSTableView()
    private let choicesTitle = NSTextField(labelWithString: "")
    private let manage = NSButton(title: "管理模板…", target: nil, action: nil)
    private let attachmentScroll = NSScrollView()
    private let attachmentStack = NSStackView()
    private var suggestionsVisible = false
    private var canManageSuggestions = false
    private var sendImage: NSImage?
    private let stopImage = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "停止")
    private var measuredWidth: CGFloat = 0
    private var contentHeight: CGFloat = 26
    public var draft: String { editor.string }
    public override var isFlipped: Bool { true }
    private var hasContent: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }
    private var stoppingRole: Bool { state.running == true && !hasContent }
    private var shelfHeight: CGFloat { suggestionsVisible ? 28 + CGFloat(min(5, suggestions.count)) * 38 : 0 }
    private var attachmentsHeight: CGFloat { attachments.isEmpty ? 0 : 36 }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("corral.conversation.composer")
        card.wantsLayer = true; card.layer?.cornerRadius = 14; card.layer?.cornerCurve = .continuous; card.layer?.borderWidth = 1
        addSubview(card)
        scrollView.drawsBackground = false; scrollView.hasVerticalScroller = true; scrollView.autohidesScrollers = true
        editor.delegate = self; editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true; editor.drawsBackground = false
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.minSize = NSSize(width: 0, height: 26); editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]; editor.textContainerInset = NSSize(width: 0, height: 3)
        editor.textContainer?.lineFragmentPadding = 0; editor.textContainer?.widthTracksTextView = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.setAccessibilityLabel("会话消息输入框"); editor.setAccessibilityIdentifier("corral.composer.editor")
        editor.onSubmit = { [weak self] in self?.submit() }
        editor.onFocus = { [weak self] in self?.onFocus?() }
        editor.onCompletionKey = { [weak self] in self?.completionKey($0) ?? false }
        scrollView.documentView = editor; addSubview(scrollView)
        for (button, id, label, selector) in [
            (actionButton, "action", "发送消息", #selector(actionClicked)), (stopButton, "stop", "停止生成", #selector(stopClicked)),
            (slashButton, "slash", "斜杠命令", #selector(slashClicked)), (shortcutsButton, "shortcuts", "快捷指令与模板", #selector(shortcutsClicked)),
            (attachButton, "attach", "添加文件或图片", #selector(attachClicked))] {
            button.isBordered = false; button.target = self; button.action = selector
            button.setAccessibilityIdentifier("corral.composer." + id); button.setAccessibilityLabel(label); button.toolTip = label
            button.font = .systemFont(ofSize: 17, weight: .medium); addSubview(button)
        }
        actionButton.wantsLayer = true; actionButton.layer?.cornerRadius = 10; actionButton.imagePosition = .imageOnly
        stopButton.image = stopImage; stopButton.imagePosition = .imageOnly
        statusLabel.font = .systemFont(ofSize: 10.5); statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityIdentifier("corral.composer.status"); addSubview(statusLabel)
        choices.addTableColumn(NSTableColumn(identifier: .init("choice"))); choices.headerView = nil; choices.rowHeight = 36
        choices.intercellSpacing = NSSize(width: 0, height: 2); choices.dataSource = self
        choices.target = self; choices.action = #selector(chooseSuggestion); choices.backgroundColor = .clear
        choices.setAccessibilityIdentifier("corral.composer.suggestions")
        choicesScroll.documentView = choices; choicesScroll.hasVerticalScroller = true; choicesScroll.drawsBackground = false
        choicesTitle.font = .systemFont(ofSize: 11); choicesTitle.textColor = CorralAestheticTokens.textMuted
        manage.isBordered = false; manage.target = self; manage.action = #selector(manageTemplates)
        manage.setAccessibilityIdentifier("corral.composer.manage-prompts")
        for view in [choicesScroll, choicesTitle, manage] { addSubview(view); view.isHidden = true }
        attachmentStack.orientation = .horizontal; attachmentStack.spacing = 6
        attachmentScroll.documentView = attachmentStack; attachmentScroll.drawsBackground = false
        attachmentScroll.hasHorizontalScroller = true; attachmentScroll.autohidesScrollers = true
        addSubview(attachmentScroll); attachmentScroll.isHidden = true
        refreshTheme(); updateControls()
    }
    public required init?(coder: NSCoder) { nil }

    public func restoreDraft(_ text: String) {
        guard editor.string != text, !editor.hasMarkedText() else { return }
        editor.string = text; editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        editor.undoManager?.removeAllActions(); editor.needsDisplay = true; measure(); updateControls()
    }
    public func textDidChange(_ notification: Notification) { onDraftChange?(editor.string); editor.needsDisplay = true; measure(); updateControls() }
    public func apply(_ state: CorralComposerState) {
        guard state != self.state else { return }
        let changesRole = (self.state.running == true) != (state.running == true)
        self.state = state
        if changesRole, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition(); fade.type = .fade; fade.duration = 0.14; actionButton.layer?.add(fade, forKey: "composer.action")
        }
        updateControls()
    }
    public func setSuggestions(_ entries: [CorralComposerSuggestion], title: String, visible: Bool, canManage: Bool = false) {
        suggestions = entries; suggestionsVisible = visible; canManageSuggestions = canManage
        choicesTitle.stringValue = title; choicesTitle.isHidden = !visible; choicesScroll.isHidden = !visible || entries.isEmpty
        manage.isHidden = !visible || !canManage
        choices.reloadData(); if !entries.isEmpty { choices.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        measure(); needsLayout = true
    }
    public func setAttachments(_ values: [CorralComposerAttachment]) {
        guard values != attachments else { return }; attachments = values
        attachmentStack.arrangedSubviews.forEach { attachmentStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for value in values {
            let button = NSButton(title: value.url.lastPathComponent + "  ×", target: self, action: #selector(removeAttachment(_:)))
            button.identifier = .init(value.id.uuidString); button.toolTip = "移除附件：" + value.url.lastPathComponent
            button.setAccessibilityIdentifier("corral.composer.attachment." + value.id.uuidString)
            button.image = value.preview.flatMap(NSImage.init(data:)) ?? NSImage(systemSymbolName: value.isImage ? "photo" : "doc", accessibilityDescription: nil)
            button.image?.size = NSSize(width: 22, height: 22); button.imagePosition = .imageLeading
            button.lineBreakMode = .byTruncatingMiddle; button.font = .systemFont(ofSize: 11)
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
            attachmentStack.addArrangedSubview(button)
        }
        attachmentScroll.isHidden = values.isEmpty; measure(); updateControls(); needsLayout = true
    }
    public func numberOfRows(in tableView: NSTableView) -> Int { suggestions.count }
    public func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        suggestions[row].title + "   " + suggestions[row].detail
    }
    private func completionKey(_ key: UInt16) -> Bool {
        guard suggestionsVisible else { return false }
        if key == 53 { onDismissSuggestions?(); return true }
        if key == 125 || key == 126, !suggestions.isEmpty {
            let next = min(suggestions.count - 1, max(0, choices.selectedRow + (key == 125 ? 1 : -1)))
            choices.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false); choices.scrollRowToVisible(next); return true
        }
        if key == 36 || key == 76 || key == 48, !suggestions.isEmpty { chooseSuggestion(); return true }
        return false
    }
    @objc private func chooseSuggestion() { guard !editor.hasMarkedText(), suggestions.indices.contains(choices.selectedRow) else { return }; onChooseSuggestion?(suggestions[choices.selectedRow]) }
    @objc private func removeAttachment(_ button: NSButton) { if let id = button.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) { onRemoveAttachment?(id) } }
    @objc private func slashClicked() { onSlash?() }
    @objc private func shortcutsClicked() { onShortcuts?() }
    @objc private func attachClicked() { onAttach?() }
    @objc private func manageTemplates() { onManageTemplates?() }
    @objc private func stopClicked() { if stopButton.isEnabled { onAbort?() } }
    private func updateControls() {
        actionButton.image = stoppingRole ? stopImage : sendImage
        actionButton.contentTintColor = CorralAestheticTokens.actionPrimaryForeground
        actionButton.layer?.backgroundColor = (stoppingRole ? CorralAestheticTokens.warning : CorralAestheticTokens.actionPrimaryBackground).cgColor
        actionButton.isEnabled = state.ready && (stoppingRole ? !state.stopping : state.running != nil && !state.sending && !state.stopping && !editor.hasMarkedText() && hasContent)
        actionButton.alphaValue = actionButton.isEnabled ? 1 : 0.45
        actionButton.setAccessibilityLabel(stoppingRole ? "停止生成" : state.running == true ? "发送中途指令" : "发送消息")
        actionButton.toolTip = stoppingRole ? "停止当前生成或工具执行" : state.running == true ? "Enter 发送中途指令（steer）" : "Enter 发送 · Shift+Enter 换行"
        stopButton.isHidden = state.running != true || !hasContent
        stopButton.isEnabled = state.ready && !state.stopping
        stopButton.contentTintColor = CorralAestheticTokens.warning
        statusLabel.stringValue = state.message ?? (!state.ready ? "连接就绪后可发送 · 草稿已保留" : state.stopping ? "正在停止…" : state.sending ? "正在确认发送…" : state.running == true ? "生成中 · 可发送中途指令" : "Enter 发送 · Shift+Enter 换行")
        statusLabel.textColor = state.isError ? CorralAestheticTokens.warnText : CorralAestheticTokens.textMuted
        statusLabel.toolTip = statusLabel.stringValue; needsLayout = true
    }
    private func submit() {
        guard state.ready, state.running != nil, !state.sending, !state.stopping, !editor.hasMarkedText(), hasContent else { return }
        onSubmit?()
    }
    @objc private func actionClicked() { guard actionButton.isEnabled else { return }; if stoppingRole { onAbort?() } else { submit() } }
    public func refreshTheme() {
        sendImage = CorralLegacyIcon.image(.arrowUp, size: 17)
        card.layer?.backgroundColor = CorralAestheticTokens.fieldBackground.cgColor; card.layer?.borderColor = CorralConversationStyle.cardBorder.cgColor
        editor.font = .systemFont(ofSize: 14); editor.textColor = CorralAestheticTokens.text; editor.insertionPointColor = CorralAestheticTokens.accent
        for button in [slashButton, shortcutsButton, attachButton] { button.contentTintColor = CorralAestheticTokens.textSecondary }
        updateControls(); editor.needsDisplay = true
    }
    public override func layout() {
        super.layout()
        let width = max(1, bounds.width - 48)
        let shelfHeight = min(self.shelfHeight, max(0, bounds.height - 88 - attachmentsHeight))
        choicesTitle.isHidden = !suggestionsVisible || shelfHeight < 24
        choicesScroll.isHidden = !suggestionsVisible || suggestions.isEmpty || shelfHeight <= 28
        manage.isHidden = !suggestionsVisible || !canManageSuggestions || shelfHeight < 24
        choicesTitle.frame = CGRect(x: 24, y: 2, width: max(0, width - (manage.isHidden ? 0 : 100)), height: 22)
        manage.frame = CGRect(x: bounds.width - 124, y: 0, width: 100, height: 24)
        choicesScroll.frame = CGRect(x: 24, y: 26, width: width, height: max(0, shelfHeight - 28))
        choices.tableColumns.first?.width = width
        card.frame = CGRect(x: 12, y: shelfHeight, width: max(0, bounds.width - 24), height: max(0, bounds.height - shelfHeight - 12))
        attachmentScroll.frame = CGRect(x: 24, y: shelfHeight + 5, width: width, height: attachmentsHeight)
        attachmentStack.layoutSubtreeIfNeeded(); attachmentStack.setFrameSize(NSSize(width: max(width, attachmentStack.fittingSize.width), height: 28))
        scrollView.frame = CGRect(x: 24, y: shelfHeight + attachmentsHeight + 10, width: width, height: max(0, card.frame.height - attachmentsHeight - 50))
        if abs(width - measuredWidth) > 0.5 {
            measuredWidth = width; editor.setFrameSize(NSSize(width: width, height: max(26, editor.frame.height)))
            editor.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            measure()
        }
        let bottom = card.frame.maxY - 36
        slashButton.frame = CGRect(x: 22, y: bottom, width: 26, height: 26)
        shortcutsButton.frame = CGRect(x: 52, y: bottom, width: 26, height: 26)
        attachButton.frame = CGRect(x: 82, y: bottom, width: 26, height: 26)
        actionButton.frame = CGRect(x: card.frame.maxX - 40, y: bottom - 1, width: 30, height: 30)
        stopButton.frame = CGRect(x: actionButton.frame.minX - 34, y: bottom, width: 28, height: 28)
        statusLabel.frame = CGRect(x: 118, y: bottom + 7, width: max(0, (stopButton.isHidden ? actionButton.frame.minX : stopButton.frame.minX) - 126), height: 15)
    }
    private func measure() {
        if let container = editor.textContainer, let manager = editor.layoutManager, measuredWidth > 0 {
            manager.ensureLayout(for: container)
            contentHeight = max(26, ceil(manager.usedRect(for: container).height) + editor.textContainerInset.height * 2)
            editor.setFrameSize(NSSize(width: measuredWidth, height: contentHeight))
        }
        let height = min(144, contentHeight) + 62 + shelfHeight + attachmentsHeight
        if abs(preferredHeight - height) > 0.5 { preferredHeight = height; onHeightChange?() }
    }
}
