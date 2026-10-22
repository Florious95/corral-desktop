import AppKit

/// One display row of a structured conversation. Built from native items by the coordinator; the view never
/// infers roles, completion or tool pairing on its own.
public struct CorralConversationRow: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case user, assistant, reasoning, tool, notice, other(String) }
    public enum Body: Hashable, Sendable {
        /// `text` is the whole native content.
        case complete
        /// `text` is a bounded summary; the full body is fetched on demand.
        case summary
        case loading
        case failed(String)
    }

    public let id: String
    public let revision: UInt64
    public let kind: Kind
    public let text: String
    public let body: Body
    public let streaming: Bool
    /// The view attached after this item started; its earlier content is not shown.
    public let observedSuffix: Bool
    public let imageCount: Int
    public let redacted: Bool
    public let toolName: String?
    public let toolPhase: String?
    /// Tool body `{"arguments":…,"output":"…"}` once completely loaded.
    public let toolArguments: String?
    public let toolOutput: String?

    public init(id: String, revision: UInt64, kind: Kind, text: String, body: Body = .complete, streaming: Bool = false,
                observedSuffix: Bool = false, imageCount: Int = 0, redacted: Bool = false, toolName: String? = nil,
                toolPhase: String? = nil, toolArguments: String? = nil, toolOutput: String? = nil) {
        self.id = id
        self.revision = revision
        self.kind = kind
        self.text = text
        self.body = body
        self.streaming = streaming
        self.observedSuffix = observedSuffix
        self.imageCount = imageCount
        self.redacted = redacted
        self.toolName = toolName
        self.toolPhase = toolPhase
        self.toolArguments = toolArguments
        self.toolOutput = toolOutput
    }

    /// Long text rows load their body as soon as they are on screen; cards wait until expanded.
    var loadsBodyWhenVisible: Bool {
        switch kind {
        case .user, .assistant, .notice, .other: body == .summary
        case .reasoning, .tool: false
        }
    }
}

public struct CorralConversationPaneState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case connecting
        case loadingHistory
        case ready
        case historyFailed(String)
        case reconnecting(String)
        case unavailable(String)
    }
    public enum Older: Equatable, Sendable { case available, loading, failed(String), complete, limit, partial }

    public var title: String
    public var provider: String?
    public var modelLabel: String?
    public var phase: Phase
    /// nil while no authoritative run state has arrived; never shown as idle.
    public var running: Bool?
    public var queued: Int
    public var older: Older
    public var rows: [CorralConversationRow]

    public init(title: String, provider: String? = nil, modelLabel: String? = nil, phase: Phase = .connecting, running: Bool? = nil,
                queued: Int = 0, older: Older = .complete, rows: [CorralConversationRow] = []) {
        self.title = title
        self.provider = provider
        self.modelLabel = modelLabel
        self.phase = phase
        self.running = running
        self.queued = queued
        self.older = older
        self.rows = rows
    }
}

/// Theme values for the structured conversation surface, derived from the shell tokens at read time.
@MainActor
enum CorralConversationStyle {
    private static func tone(_ dark: UInt32, _ light: UInt32) -> NSColor {
        CorralAestheticTokens.color(CorralAestheticTokens.isDark ? dark : light)
    }
    static var paneBackground: NSColor { CorralAestheticTokens.background }
    static var userBubble: NSColor { tone(0x232C39, 0xEEEAE3) }
    static var cardBackground: NSColor { CorralAestheticTokens.isDark ? NSColor.white.withAlphaComponent(0.035) : NSColor.black.withAlphaComponent(0.025) }
    static var cardBorder: NSColor { CorralAestheticTokens.isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.08) }
    static var codeBackground: NSColor { tone(0x0A0C10, 0xF3F0EB) }
    static var codeHeader: NSColor { CorralAestheticTokens.isDark ? NSColor.white.withAlphaComponent(0.04) : NSColor.black.withAlphaComponent(0.035) }
    static var inlineCodeBackground: NSColor { CorralAestheticTokens.isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.055) }
    static var inlineCodeText: NSColor { tone(0xE7CFA6, 0x9A4B28) }
    static var rule: NSColor { CorralAestheticTokens.isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.14) }
    static var tableHeader: NSColor { CorralAestheticTokens.isDark ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.04) }
    static var bodyFont: NSFont { NSFont.systemFont(ofSize: 14) }

    static var markdown: CorralMarkdown.Style {
        CorralMarkdown.Style(font: bodyFont, color: CorralAestheticTokens.text, secondaryColor: CorralAestheticTokens.textSecondary,
                             linkColor: CorralAestheticTokens.accent, codeColor: inlineCodeText, codeBackground: inlineCodeBackground,
                             ruleColor: rule, tableHeaderBackground: tableHeader)
    }

    static var reasoningMarkdown: CorralMarkdown.Style {
        var style = markdown
        style.font = NSFont.systemFont(ofSize: 13)
        style.color = CorralAestheticTokens.textSecondary
        style.lineHeightMultiple = 1.28
        return style
    }

    static var codePalette: CorralCodeHighlighter.Palette {
        CorralCodeHighlighter.Palette(plain: tone(0xD5DCE6, 0x3A3835), keyword: tone(0xC6A8F0, 0x7A3E9D), string: tone(0xA3D3A6, 0x2F7D4F),
                                      number: tone(0xE6B98A, 0xA4542E), comment: tone(0x6E7A8B, 0x9A968E), type: tone(0x8EBBEA, 0x2E5898))
    }
}

/// The native structured view that replaces a Pi terminal inside a split pane: header, virtualized transcript
/// and explicit loading, empty, failure and reconnect states. It sends typed intents only.
@MainActor
public final class CorralConversationPaneView: NSView {
    public var onFocus: (() -> Void)?
    public var onLoadOlder: (() -> Void)?
    public var onNeedBodies: (([String]) -> Void)?
    public var onRetry: (() -> Void)?

    public private(set) var state = CorralConversationPaneState(title: "")
    /// Right-edge space kept clear for the split pane's own close button.
    public var trailingChromeInset: CGFloat = 0 { didSet { if oldValue != trailingChromeInset { needsLayout = true } } }

    public let header = CorralConversationHeaderView()
    public let transcript = CorralConversationTranscriptView()
    private let overlay = CorralConversationStateOverlay()

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { false }
    /// Like the terminal, the first click into an inactive window already reaches the pane.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("corral.conversation.pane")
        addSubview(transcript)
        addSubview(header)
        addSubview(overlay)
        transcript.onLoadOlder = { [weak self] in self?.onLoadOlder?() }
        transcript.onNeedBodies = { [weak self] ids in self?.onNeedBodies?(ids) }
        transcript.onRetryOlder = { [weak self] in self?.onLoadOlder?() }
        overlay.onRetry = { [weak self] in self?.onRetry?() }
        refreshTheme()
    }

    public required init?(coder: NSCoder) { fatalError("CorralConversationPaneView is created programmatically") }

    public func apply(_ state: CorralConversationPaneState) {
        let previous = self.state
        self.state = state
        if previous.title != state.title || previous.provider != state.provider || previous.modelLabel != state.modelLabel
            || previous.running != state.running || previous.queued != state.queued || previous.phase != state.phase {
            header.apply(title: state.title, provider: state.provider, model: state.modelLabel, running: state.running,
                         queued: state.queued, phase: state.phase)
        }
        overlay.apply(phase: state.phase, isEmpty: state.rows.isEmpty)
        transcript.apply(rows: state.rows, older: state.rows.isEmpty ? .complete : state.older)
        setAccessibilityLabel("\(state.title) 结构化会话")
    }

    /// Keyboard focus for reading, copying and scrolling; never a terminal or PTY responder.
    public var preferredFirstResponder: NSView { transcript.documentResponder }

    public func refreshTheme() {
        layer?.backgroundColor = CorralConversationStyle.paneBackground.cgColor
        header.refreshTheme()
        overlay.refreshTheme()
        transcript.refreshTheme()
    }

    public override func layout() {
        super.layout()
        let headerHeight = CorralConversationHeaderView.height
        header.trailingInset = trailingChromeInset
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        transcript.frame = CGRect(x: 0, y: headerHeight, width: bounds.width, height: max(0, bounds.height - headerHeight))
        overlay.frame = transcript.frame
    }

    public override func mouseDown(with event: NSEvent) { onFocus?() }
}

/// 40pt pane header: provider, native session title, model and authoritative run state.
@MainActor
public final class CorralConversationHeaderView: NSView {
    public static let height: CGFloat = 40
    var trailingInset: CGFloat = 0 { didSet { if oldValue != trailingInset { needsLayout = true } } }
    private var iconView: CorralProviderIconView?
    private var provider: String?
    public let titleLabel = NSTextField(labelWithString: "")
    private let modelChip = CorralChipLabel()
    private let statusDot = CorralStatusIndicatorView()
    public let statusLabel = NSTextField(labelWithString: "")
    private let separator = NSView()

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityIdentifier("corral.conversation.header")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityIdentifier("corral.conversation.title")
        statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabel.alignment = .right
        statusLabel.setAccessibilityIdentifier("corral.conversation.status")
        statusDot.fillsIdle = true
        separator.wantsLayer = true
        for view in [titleLabel, modelChip, statusDot, statusLabel, separator] { addSubview(view) }
        refreshTheme()
    }

    public required init?(coder: NSCoder) { fatalError("CorralConversationHeaderView is created programmatically") }

    /// Labels are decoration; a click anywhere except a real control focuses the pane.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        if let hit = super.hitTest(point), hit is NSControl, !(hit is NSTextField) { return hit }
        return self
    }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) { notifyConversationPaneInteraction() }

    func apply(title: String, provider: String?, model: String?, running: Bool?, queued: Int, phase: CorralConversationPaneState.Phase) {
        titleLabel.stringValue = title
        titleLabel.toolTip = title
        if provider != self.provider {
            self.provider = provider
            iconView?.removeFromSuperview()
            iconView = provider.map { CorralProviderIconView(provider: $0, size: 16, active: true) }
            if let iconView { iconView.translatesAutoresizingMaskIntoConstraints = true; addSubview(iconView) }
        }
        modelChip.text = model ?? ""
        modelChip.isHidden = model?.isEmpty ?? true
        modelChip.toolTip = model
        switch phase {
        case .connecting:
            statusDot.status = .unknown; statusLabel.stringValue = "连接中…"
        case .reconnecting:
            statusDot.status = .unknown; statusLabel.stringValue = "正在重新连接…"
        case .unavailable:
            statusDot.status = .offline; statusLabel.stringValue = "不可用"
        case .loadingHistory, .ready, .historyFailed:
            switch running {
            case .some(true):
                statusDot.status = .working
                statusLabel.stringValue = queued > 0 ? "运行中 · 排队 \(queued)" : "运行中"
            case .some(false):
                statusDot.status = .idle
                statusLabel.stringValue = queued > 0 ? "空闲 · 排队 \(queued)" : "空闲"
            case .none:
                statusDot.status = .unknown; statusLabel.stringValue = "状态未知"
            }
        }
        statusLabel.setAccessibilityLabel("会话状态：\(statusLabel.stringValue)")
        needsLayout = true
    }

    func refreshTheme() {
        layer?.backgroundColor = CorralConversationStyle.paneBackground.cgColor
        separator.layer?.backgroundColor = CorralAestheticTokens.borderSubtle.cgColor
        titleLabel.textColor = CorralAestheticTokens.text
        statusLabel.textColor = CorralAestheticTokens.textMuted
        modelChip.refreshTheme()
        statusDot.refreshTheme()
        iconView?.refreshTheme()
    }

    public override func layout() {
        super.layout()
        let midY = bounds.height / 2
        var x: CGFloat = 16
        if let iconView {
            iconView.frame = CGRect(x: x, y: midY - 8, width: 16, height: 16)
            x += 24
        }
        let right = bounds.width - 14 - trailingInset
        let statusWidth = min(170, TranscriptRowView.width(of: statusLabel))
        statusLabel.frame = CGRect(x: right - statusWidth, y: midY - 8, width: statusWidth, height: 16)
        statusDot.frame = CGRect(x: statusLabel.frame.minX - 13, y: midY - 4, width: 8, height: 8)
        let available = max(0, statusDot.frame.minX - 14 - x)
        let chipWidth = modelChip.text.isEmpty ? 0 : min(modelChip.intrinsicContentSize.width, max(0, available * 0.5))
        let titleWidth = min(TranscriptRowView.width(of: titleLabel), max(0, available - (chipWidth > 0 ? chipWidth + 8 : 0)))
        titleLabel.frame = CGRect(x: x, y: midY - 9, width: titleWidth, height: 18)
        modelChip.frame = CGRect(x: titleLabel.frame.maxX + 8, y: midY - 10, width: chipWidth, height: 20)
        modelChip.isHidden = modelChip.text.isEmpty || chipWidth < 36
        separator.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }
}

/// Rounded secondary label (model name, counters).
@MainActor
final class CorralChipLabel: NSView {
    private let label = NSTextField(labelWithString: "")
    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; invalidateIntrinsicContentSize(); needsLayout = true }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        refreshTheme()
    }
    required init?(coder: NSCoder) { fatalError("CorralChipLabel is created programmatically") }
    override var intrinsicContentSize: NSSize { NSSize(width: TranscriptRowView.width(of: label) + 16, height: 20) }
    override func layout() {
        super.layout()
        label.frame = CGRect(x: 7, y: (bounds.height - 14) / 2, width: max(0, bounds.width - 14), height: 14)
    }
    func refreshTheme() {
        layer?.backgroundColor = CorralAestheticTokens.hoverSubtle.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = CorralConversationStyle.cardBorder.cgColor
        label.textColor = CorralAestheticTokens.textSecondary
    }
}

/// Full-surface connecting, loading, empty and failure states; transparent to clicks when it shows nothing.
@MainActor
final class CorralConversationStateOverlay: NSView {
    var onRetry: (() -> Void)?
    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let retry = NSButton(title: "重试", target: nil, action: nil)
    private var showsContent = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.alignment = .center
        detail.font = .systemFont(ofSize: 12)
        detail.alignment = .center
        retry.bezelStyle = .rounded
        retry.controlSize = .regular
        retry.target = self
        retry.action = #selector(retryClicked)
        retry.setAccessibilityIdentifier("corral.conversation.retry")
        icon.imageScaling = .scaleProportionallyDown
        for view in [spinner, icon, title, detail, retry] { addSubview(view) }
        setAccessibilityIdentifier("corral.conversation.state")
        refreshTheme()
    }

    required init?(coder: NSCoder) { fatalError("CorralConversationStateOverlay is created programmatically") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard showsContent else { return nil }
        let hit = super.hitTest(point)
        return hit === retry ? hit : nil
    }

    func apply(phase: CorralConversationPaneState.Phase, isEmpty: Bool) {
        var showSpinner = false
        var iconName: CorralLegacyIcon?
        var heading = ""
        var message = ""
        var canRetry = false
        switch phase {
        case .connecting: showSpinner = true; heading = "正在连接 Pi 会话…"
        case .loadingHistory: showSpinner = isEmpty; heading = isEmpty ? "正在载入会话历史…" : ""
        case let .historyFailed(code):
            if isEmpty { iconName = .alert; heading = "会话历史载入失败"; message = Self.describe(code); canRetry = true }
        case let .reconnecting(reason):
            if isEmpty { showSpinner = true; heading = "正在重新连接…"; message = Self.describe(reason) }
        case let .unavailable(reason):
            iconName = .alert; heading = "结构化会话不可用"; message = Self.describe(reason); canRetry = true
        case .ready:
            if isEmpty { iconName = .message; heading = "还没有消息"; message = "Pi 的回复、思考过程与工具调用会显示在这里。" }
        }
        showsContent = !heading.isEmpty
        isHidden = !showsContent
        if showSpinner { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        icon.image = iconName.flatMap { CorralLegacyIcon.image($0, size: 26) }
        icon.isHidden = iconName == nil
        title.stringValue = heading
        detail.stringValue = message
        detail.isHidden = message.isEmpty
        retry.isHidden = !canRetry
        needsLayout = true
    }

    static func describe(_ code: String) -> String {
        switch code {
        case "network": "无法连接到主机的历史服务，请检查网络。"
        case "deadline": "主机响应超时。"
        case "busy": "主机正忙，请稍后重试。"
        case "stale_view", "cursor_expired": "会话视图已过期，正在重新建立。"
        case "source_unavailable", "source_changed": "会话来源已变化。"
        case "too_large": "内容超过单次传输上限。"
        case "exited": "Agent 进程已退出。"
        case "unavailable": "该窗格不是受管理的结构化会话。"
        case "lost", "gap", "credit_exhausted": "实时数据流中断，正在恢复。"
        case "": ""
        default: "错误代码：\(code)"
        }
    }

    func refreshTheme() {
        title.textColor = CorralAestheticTokens.textSecondary
        detail.textColor = CorralAestheticTokens.textMuted
        icon.contentTintColor = CorralAestheticTokens.textMuted
    }

    override func layout() {
        super.layout()
        let width = min(360, bounds.width - 40)
        var y = bounds.midY - 44
        if !spinner.isHidden || spinner.isDisplayedWhenStopped {
            spinner.frame = CGRect(x: bounds.midX - 8, y: y, width: 16, height: 16)
        }
        if !icon.isHidden { icon.frame = CGRect(x: bounds.midX - 13, y: y - 6, width: 26, height: 26) }
        y += 28
        title.frame = CGRect(x: bounds.midX - width / 2, y: y, width: width, height: 18)
        y += 24
        let detailHeight = detail.isHidden ? 0 : ceil(detail.sizeThatFits(NSSize(width: width, height: 200)).height)
        detail.frame = CGRect(x: bounds.midX - width / 2, y: y, width: width, height: detailHeight)
        y += detailHeight + (detail.isHidden ? 0 : 14)
        retry.sizeToFit()
        retry.frame = CGRect(x: bounds.midX - max(72, retry.frame.width) / 2, y: y, width: max(72, retry.frame.width), height: retry.frame.height)
    }

    @objc private func retryClicked() { onRetry?() }
}
