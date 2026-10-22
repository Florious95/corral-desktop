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

/// A real TextKit editor: composition, selection, undo and paste remain owned by AppKit.
/// Intercept only a plain Return with no marked text. The Return that commits an IME candidate never sends.
@MainActor
public final class CorralComposerTextView: NSTextView {
    public var onSubmit: (() -> Void)?
    public var onFocus: (() -> Void)?
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) { onFocus?(); super.mouseDown(with: event) }
    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if (event.keyCode == 36 || event.keyCode == 76), modifiers.isEmpty, !hasMarkedText() {
            if !event.isARepeat { onSubmit?() }
            return
        }
        super.keyDown(with: event)
    }
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            ("发送消息…" as NSString).draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height),
                                       withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: CorralAestheticTokens.textMuted])
        }
    }
}

/// Provider-neutral composer. Streaming updates only touch button/status presentation, never the editor's text.
@MainActor
public final class CorralConversationComposer: NSView, NSTextViewDelegate {
    public let editor = CorralComposerTextView()
    public let actionButton = NSButton()
    public let statusLabel = NSTextField(labelWithString: "")
    public let scrollView = NSScrollView()
    public var onSubmit: (() -> Void)?
    public var onAbort: (() -> Void)?
    public var onDraftChange: ((String) -> Void)?
    public var onHeightChange: (() -> Void)?
    public var onFocus: (() -> Void)?
    public private(set) var state = CorralComposerState()
    public private(set) var preferredHeight: CGFloat = 88
    private let card = NSView()
    private var sendImage: NSImage?
    private let stopImage = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "停止")
    private var measuredWidth: CGFloat = 0
    private var contentHeight: CGFloat = 26
    public var draft: String { editor.string }
    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("corral.conversation.composer")
        card.wantsLayer = true; card.layer?.cornerRadius = 14; card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        addSubview(card)
        scrollView.drawsBackground = false; scrollView.hasVerticalScroller = true; scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        editor.delegate = self
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
        editor.drawsBackground = false
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.minSize = NSSize(width: 0, height: 26); editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 0, height: 3)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.setAccessibilityLabel("会话消息输入框")
        editor.setAccessibilityIdentifier("corral.composer.editor")
        editor.onSubmit = { [weak self] in self?.submit() }
        editor.onFocus = { [weak self] in self?.onFocus?() }
        scrollView.documentView = editor
        addSubview(scrollView)
        actionButton.isBordered = false; actionButton.bezelStyle = .circular
        actionButton.wantsLayer = true; actionButton.layer?.cornerRadius = 10
        actionButton.imagePosition = .imageOnly
        actionButton.target = self; actionButton.action = #selector(actionClicked)
        actionButton.setAccessibilityIdentifier("corral.composer.action")
        addSubview(actionButton)
        statusLabel.font = .systemFont(ofSize: 10.5); statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityIdentifier("corral.composer.status")
        addSubview(statusLabel)
        refreshTheme(); updateControls()
    }
    public required init?(coder: NSCoder) { nil }

    /// Called only for restoration or an acknowledged unchanged draft, never during stream rendering.
    public func restoreDraft(_ text: String) {
        guard editor.string != text, !editor.hasMarkedText() else { return }
        editor.string = text
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        editor.undoManager?.removeAllActions()
        editor.needsDisplay = true
        measure(); updateControls()
    }

    public func textDidChange(_ notification: Notification) {
        onDraftChange?(editor.string)
        editor.needsDisplay = true
        measure(); updateControls()
    }

    public func apply(_ state: CorralComposerState) {
        guard state != self.state else { return }
        let changesRole = (self.state.running == true) != (state.running == true)
        self.state = state
        if changesRole, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition(); fade.type = .fade; fade.duration = 0.14
            actionButton.layer?.add(fade, forKey: "composer.action")
        }
        updateControls()
    }

    private func updateControls() {
        let stoppingRole = state.running == true
        actionButton.image = stoppingRole ? stopImage : sendImage
        actionButton.contentTintColor = CorralAestheticTokens.actionPrimaryForeground
        actionButton.layer?.backgroundColor = (stoppingRole ? CorralAestheticTokens.warning : CorralAestheticTokens.actionPrimaryBackground).cgColor
        actionButton.isEnabled = state.ready && (stoppingRole ? !state.stopping : state.running == false && !state.sending && !editor.hasMarkedText() && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        actionButton.alphaValue = actionButton.isEnabled ? 1 : 0.45
        actionButton.setAccessibilityLabel(stoppingRole ? "停止生成" : "发送消息")
        actionButton.toolTip = stoppingRole ? "停止当前生成或工具执行" : "Enter 发送 · Shift+Enter 换行"
        statusLabel.stringValue = state.message ?? (!state.ready ? "连接就绪后可发送 · 草稿已保留" : state.stopping ? "正在停止…" : state.sending ? "正在确认发送…" : stoppingRole ? "正在运行 · 可继续编辑草稿" : state.running == nil ? "等待会话状态…" : "Enter 发送 · Shift+Enter 换行")
        statusLabel.textColor = state.isError ? CorralAestheticTokens.warnText : CorralAestheticTokens.textMuted
        statusLabel.toolTip = statusLabel.stringValue
    }

    private func submit() {
        // Enter never maps to Abort: composing a draft while the agent works must be harmless.
        guard state.ready, state.running == false, !state.sending, !editor.hasMarkedText(),
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSubmit?()
    }
    @objc private func actionClicked() {
        guard actionButton.isEnabled else { return }
        if state.running == true { onAbort?() } else { submit() }
    }

    public func refreshTheme() {
        sendImage = CorralLegacyIcon.image(.arrowUp, size: 17)
        card.layer?.backgroundColor = CorralAestheticTokens.fieldBackground.cgColor
        card.layer?.borderColor = CorralConversationStyle.cardBorder.cgColor
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = CorralAestheticTokens.text; editor.insertionPointColor = CorralAestheticTokens.accent
        updateControls(); editor.needsDisplay = true
    }

    public override func layout() {
        super.layout()
        card.frame = CGRect(x: 12, y: 0, width: max(0, bounds.width - 24), height: max(0, bounds.height - 12))
        let width = max(1, card.frame.width - 24)
        scrollView.frame = CGRect(x: card.frame.minX + 12, y: 10, width: width, height: max(0, card.frame.height - 50))
        if abs(width - measuredWidth) > 0.5 {
            measuredWidth = width
            editor.setFrameSize(NSSize(width: width, height: max(26, editor.frame.height)))
            editor.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            measure()
        }
        actionButton.frame = CGRect(x: max(0, card.frame.maxX - 40), y: max(0, card.frame.maxY - 38), width: 28, height: 28)
        statusLabel.frame = CGRect(x: card.frame.minX + 12, y: actionButton.frame.midY - 7, width: max(0, width - 42), height: 14)
    }

    private func measure() {
        guard measuredWidth > 0, let manager = editor.layoutManager, let container = editor.textContainer else { return }
        manager.ensureLayout(for: container)
        contentHeight = max(26, ceil(manager.usedRect(for: container).height) + editor.textContainerInset.height * 2)
        editor.setFrameSize(NSSize(width: measuredWidth, height: contentHeight))
        let height = min(144, contentHeight) + 62
        if abs(preferredHeight - height) > 0.5 { preferredHeight = height; onHeightChange?() }
    }
}
