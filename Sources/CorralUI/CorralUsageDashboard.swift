import AppKit

/// Provider-neutral session metrics. Missing context is unknown, never an empty context or account quota.
/// The provider adapter supplies its authoritative cumulative totals, not a sum of visible transcript rows.
public struct CorralSessionUsage: Decodable, Equatable, Sendable {
    public struct Tokens: Decodable, Equatable, Sendable {
        public let input, output, cacheRead, cacheWrite, total: UInt64
    }
    public struct Context: Decodable, Equatable, Sendable {
        public let tokens: UInt64?
        public let contextWindow: UInt64
        public let percent: Double?
        public var knownPercent: Double? { tokens == nil ? nil : percent }
    }
    public let tokens: Tokens
    public let cost: Double
    public let contextUsage: Context?

    public var isValid: Bool {
        cost.isFinite && cost >= 0 && (contextUsage?.percent.map { $0.isFinite && $0 >= 0 } ?? true)
    }
}

/// An independent read-only surface. It contains no transport, provider names, or conversation mutations.
@MainActor
public final class CorralUsageDashboardController: CorralDialogViewController {
    public enum State: Equatable {
        case loading
        case ready(CorralSessionUsage, Date)
        case failed(String)
        case unavailable(String)
    }
    public private(set) var state: State = .loading
    public var onRefresh: (() -> Void)?
    public var onClose: (() -> Void)?
    private let sessionTitle: String
    private let total = UsageMetricCard(title: "累计 TOKEN", identifier: "total")
    private let cost = UsageMetricCard(title: "记录费用 · USD", identifier: "cost")
    private let contextValue = NSTextField(labelWithString: "—")
    private let contextDetail = NSTextField(labelWithString: "")
    private let contextMeter = NSProgressIndicator()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let refresh = NSButton(title: "刷新", target: nil, action: nil)
    private var tokenLabels: [NSTextField] = []

    public init(sessionTitle: String) {
        self.sessionTitle = sessionTitle
        super.init()
    }
    public required init?(coder: NSCoder) { nil }

    public override func loadView() {
        view = rootView(size: NSSize(width: 560, height: 486))
        view.setAccessibilityIdentifier("corral.usage.dashboard")
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = UsageDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        view.addSubview(scroll)
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ])
        func row(_ child: NSView, height: CGFloat) {
            stack.addArrangedSubview(child)
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            child.heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        let heading = NSTextField(labelWithString: "用量与额度")
        heading.font = .systemFont(ofSize: 21, weight: .semibold)
        heading.textColor = CorralAestheticTokens.text
        row(heading, height: 26)
        let subtitle = NSTextField(labelWithString: sessionTitle)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = CorralAestheticTokens.textMuted
        subtitle.lineBreakMode = .byTruncatingMiddle; subtitle.toolTip = sessionTitle
        row(subtitle, height: 16)
        stack.setCustomSpacing(6, after: heading)

        let metrics = NSStackView(views: [total, cost])
        metrics.orientation = .horizontal; metrics.spacing = 12; metrics.distribution = .fillEqually
        row(metrics, height: 88)
        let breakdown = NSStackView()
        breakdown.orientation = .horizontal; breakdown.distribution = .fillEqually; breakdown.spacing = 8
        for (name, id) in [("输入", "input"), ("输出", "output"), ("缓存读取", "cacheRead"), ("缓存写入", "cacheWrite")] {
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 11); label.textColor = CorralAestheticTokens.textMuted
            let value = NSTextField(labelWithString: "—")
            value.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
            value.textColor = CorralAestheticTokens.text
            value.setAccessibilityIdentifier("corral.usage.\(id)")
            let column = NSStackView(views: [label, value]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 5
            breakdown.addArrangedSubview(column); tokenLabels.append(value)
        }
        row(breakdown, height: 40)

        let context = NSStackView(); context.orientation = .vertical; context.alignment = .leading; context.spacing = 8
        let contextTitle = NSTextField(labelWithString: "上下文水位")
        contextTitle.font = .systemFont(ofSize: 13, weight: .semibold); contextTitle.textColor = CorralAestheticTokens.text
        contextValue.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        contextValue.textColor = CorralAestheticTokens.text
        contextValue.setAccessibilityIdentifier("corral.usage.context.percent")
        let contextHeading = NSStackView(); contextHeading.orientation = .horizontal
        contextHeading.addView(contextTitle, in: .leading); contextHeading.addView(contextValue, in: .trailing)
        context.addArrangedSubview(contextHeading)
        contextMeter.style = .bar; contextMeter.isIndeterminate = false; contextMeter.minValue = 0; contextMeter.maxValue = 100
        contextMeter.setAccessibilityIdentifier("corral.usage.context.meter")
        context.addArrangedSubview(contextMeter)
        contextDetail.font = .systemFont(ofSize: 11); contextDetail.textColor = CorralAestheticTokens.textMuted
        contextDetail.setAccessibilityIdentifier("corral.usage.context.detail")
        context.addArrangedSubview(contextDetail)
        for child in context.arrangedSubviews { child.widthAnchor.constraint(equalTo: context.widthAnchor).isActive = true }
        row(context, height: 74)

        let note = NSTextField(wrappingLabelWithString: "账户额度 · 未提供\n会话用量不等于套餐剩余额度；费用为模型记录值，并非最终账单。")
        note.font = .systemFont(ofSize: 11); note.textColor = CorralAestheticTokens.textMuted
        note.setAccessibilityIdentifier("corral.usage.quota")
        row(note, height: 34)
        status.font = .systemFont(ofSize: 11); status.textColor = CorralAestheticTokens.textMuted
        status.setAccessibilityIdentifier("corral.usage.status")
        row(status, height: 30)
        refresh.target = self; refresh.action = #selector(refreshClicked)
        refresh.setAccessibilityIdentifier("corral.usage.refresh")
        let close = NSButton(title: "关闭", target: self, action: #selector(closeClicked))
        close.setAccessibilityIdentifier("corral.usage.close")
        let footer = actionsRow([close], leading: [refresh])
        footer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            footer.heightAnchor.constraint(equalToConstant: 28), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor)
        ])
        apply(state)
    }

    public override func present(over window: NSWindow? = NSApp.keyWindow) {
        guard let window, let content = window.contentView else { return }
        loadViewIfNeeded()
        // A narrow split/window still gets a usable surface; metrics scroll, dismissal stays visible.
        view.setFrameSize(NSSize(width: min(560, max(280, content.bounds.width - 32)),
                                 height: min(486, max(240, content.bounds.height - 32))))
        super.present(over: window)
    }

    public func apply(_ state: State) {
        self.state = state
        guard isViewLoaded else { return }
        var usage: CorralSessionUsage?
        refresh.isEnabled = true
        status.textColor = CorralAestheticTokens.textMuted
        switch state {
        case .loading:
            status.stringValue = "正在读取当前会话的原生统计…"; refresh.isEnabled = false
        case let .ready(value, date):
            usage = value
            status.stringValue = "会话累计快照 · 更新于 \(date.formatted(date: .omitted, time: .standard))\n运行中的新增用量，请点击刷新读取。"
        case let .failed(reason):
            status.stringValue = reason; status.textColor = CorralAestheticTokens.danger
        case let .unavailable(reason):
            status.stringValue = reason; refresh.isEnabled = false
        }
        total.value.stringValue = usage.map { Self.count($0.tokens.total) } ?? "—"
        cost.value.stringValue = usage.map { String(format: "$%.4f", $0.cost) } ?? "—"
        let tokens = usage.map { [$0.tokens.input, $0.tokens.output, $0.tokens.cacheRead, $0.tokens.cacheWrite] }
        for (index, label) in tokenLabels.enumerated() { label.stringValue = tokens.map { Self.count($0[index]) } ?? "—" }
        let context = usage?.contextUsage
        let percent = context.flatMap { $0.contextWindow > 0 ? $0.knownPercent : nil }
        contextValue.stringValue = percent.map { String(format: "%.1f%%", $0) } ?? "未知"
        contextValue.textColor = (percent ?? 0) >= 90 ? CorralAestheticTokens.warnText : CorralAestheticTokens.text
        contextMeter.doubleValue = min(100, percent ?? 0)
        contextMeter.isHidden = percent == nil
        if let context, context.contextWindow > 0 {
            contextDetail.stringValue = "\(context.tokens.map(Self.count) ?? "未知") / \(Self.count(context.contextWindow)) tokens · 当前上下文估算"
        } else { contextDetail.stringValue = "当前来源未提供上下文水位" }
    }

    private static func count(_ value: UInt64) -> String { value.formatted(.number.locale(Locale(identifier: "en_US"))) }
    @objc private func refreshClicked() { onRefresh?() }
    @objc private func closeClicked() { handleEscape() }
    public override func handleEscape() { closeDialog(); onClose?() }
}

@MainActor
private final class UsageDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class UsageMetricCard: NSView {
    let value = NSTextField(labelWithString: "—")
    init(title: String, identifier: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CorralAestheticTokens.hoverSubtle.cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = CorralAestheticTokens.borderSubtle.cgColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10, weight: .semibold); label.textColor = CorralAestheticTokens.textMuted
        value.font = .monospacedDigitSystemFont(ofSize: 25, weight: .semibold); value.textColor = CorralAestheticTokens.text
        value.lineBreakMode = .byTruncatingTail
        value.setAccessibilityIdentifier("corral.usage.\(identifier)")
        for child in [label, value] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), label.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            value.leadingAnchor.constraint(equalTo: label.leadingAnchor), value.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 7),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        ])
    }
    required init?(coder: NSCoder) { nil }
}
