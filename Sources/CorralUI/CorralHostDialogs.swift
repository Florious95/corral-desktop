import AppKit
import CorralContracts
import CorralServices
import QuartzCore

/// A host's channel as a capsule: tinted dot + "Tailscale 100.x" / "局域网 192.168.x" / "本机".
/// `active` marks the route the live connection runs over with a filled, glowing dot.
@MainActor
public final class CorralRouteChip: NSView {
    public let route: ApprovedEndpoint.Route
    public let label = NSTextField(labelWithString: "")
    public var active: Bool { didSet { needsDisplay = true; refresh() } }

    public init(route: ApprovedEndpoint.Route, address: String?, active: Bool = false) {
        self.route = route; self.active = active
        super.init(frame: .zero)
        wantsLayer = true
        label.stringValue = [Self.title(route), route == .loopback ? nil : address].compactMap { $0 }.joined(separator: " ")
        label.font = .systemFont(ofSize: 10.5, weight: .medium); label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        refresh()
    }
    required init?(coder: NSCoder) { nil }

    public static func title(_ route: ApprovedEndpoint.Route) -> String {
        switch route { case .tailnet: "Tailscale"; case .lan: "局域网"; case .loopback: "本机" }
    }

    public static func tint(_ route: ApprovedEndpoint.Route) -> NSColor {
        switch route {
        case .tailnet: CorralAestheticTokens.accent
        case .lan: CorralAestheticTokens.successDeep
        case .loopback: CorralAestheticTokens.textMuted
        }
    }

    private func refresh() {
        label.textColor = route == .loopback ? CorralAestheticTokens.textSecondary : Self.tint(route)
        setAccessibilityLabel(label.stringValue + (active ? "，当前连接" : ""))
    }

    public override func draw(_ dirtyRect: NSRect) {
        let tint = Self.tint(route)
        tint.withAlphaComponent(CorralAestheticTokens.isDark ? 0.16 : 0.11).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let dot = NSRect(x: 6, y: bounds.midY - 2.5, width: 5, height: 5)
        if active {
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow(); glow.shadowColor = tint.withAlphaComponent(0.7); glow.shadowBlurRadius = 3; glow.shadowOffset = .zero; glow.set()
            tint.setFill(); NSBezierPath(ovalIn: dot).fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.6, dy: 0.6)); ring.lineWidth = 1.2
            tint.withAlphaComponent(0.8).setStroke(); ring.stroke()
        }
    }
}

/// Sonar pulse for "searching": a solid core with two rings that expand and fade. Static under Reduce Motion.
@MainActor
public final class CorralScanPulseView: NSView {
    public var isAnimating = false { didSet { if isAnimating != oldValue { updateAnimation() } } }
    private let core = CAShapeLayer()
    private let rings = [CAShapeLayer(), CAShapeLayer()]
    private let diameter: CGFloat

    public init(diameter: CGFloat) {
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: diameter), heightAnchor.constraint(equalToConstant: diameter)])
        for ring in rings { layer?.addSublayer(ring) }
        layer?.addSublayer(core)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    public override func layout() {
        super.layout()
        let bounds = self.bounds
        let tint = CorralAestheticTokens.accent.cgColor
        let coreSize = max(6, diameter * 0.22)
        core.frame = bounds
        core.path = CGPath(ellipseIn: CGRect(x: bounds.midX - coreSize / 2, y: bounds.midY - coreSize / 2, width: coreSize, height: coreSize), transform: nil)
        core.fillColor = tint
        for (index, ring) in rings.enumerated() {
            ring.frame = bounds
            ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
            ring.fillColor = CorralAestheticTokens.accent.withAlphaComponent(0.10).cgColor
            ring.strokeColor = CorralAestheticTokens.accent.withAlphaComponent(0.55).cgColor
            ring.lineWidth = 1
            if !isAnimating { ring.transform = CATransform3DMakeScale(index == 0 ? 0.62 : 1, index == 0 ? 0.62 : 1, 1); ring.opacity = index == 0 ? 0.9 : 0.45 }
        }
    }

    private func updateAnimation() {
        for (index, ring) in rings.enumerated() {
            ring.removeAllAnimations()
            guard isAnimating, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { continue }
            let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 0.25; scale.toValue = 1
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.95; fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]; group.duration = 1.8; group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.beginTime = CACurrentMediaTime() + Double(index) * 0.9
            group.isRemovedOnCompletion = false
            ring.add(group, forKey: "pulse")
        }
        needsLayout = true
    }
}

/// A tinted capsule label ("已配对", "当前").
@MainActor
final class CorralPillLabel: NSTextField {
    init(text: String, tint: NSColor) {
        super.init(frame: .zero)
        stringValue = text; isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
        font = .systemFont(ofSize: 10.5, weight: .semibold); textColor = tint; alignment = .center
        wantsLayer = true; layer?.cornerRadius = 9; layer?.backgroundColor = tint.withAlphaComponent(CorralAestheticTokens.isDark ? 0.16 : 0.11).cgColor
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { let size = super.intrinsicContentSize; return NSSize(width: size.width + 14, height: 18) }
    override func draw(_ dirtyRect: NSRect) {
        let text = attributedStringValue, size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// One discovered host: monitor tile, name, route chips and a trailing state ("已配对" or a selection check).
@MainActor
final class NearbyHostRowView: NSView {
    static let height: CGFloat = 54
    let host: NearbyHost
    var onSelect: ((String) -> Void)?
    var isSelected = false { didSet { needsDisplay = true; check.isHidden = !isSelected; setAccessibilitySelected(isSelected) } }
    private var hovering = false { didSet { needsDisplay = true } }
    private let check = NSImageView()

    init(host: NearbyHost, paired: Bool) {
        self.host = host
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let tile = NSView(); tile.wantsLayer = true
        tile.layer?.cornerRadius = 8; tile.layer?.backgroundColor = CorralAestheticTokens.hoverTile.cgColor
        tile.layer?.borderWidth = 0.5; tile.layer?.borderColor = CorralAestheticTokens.ringTile.cgColor
        let glyph = NSImageView(image: CorralLegacyIcon.image(.monitor, size: 16, tint: CorralAestheticTokens.iconStrong) ?? NSImage())
        glyph.contentTintColor = CorralAestheticTokens.iconStrong
        let title = NSTextField(labelWithString: host.name)
        title.font = .systemFont(ofSize: 13, weight: .semibold); title.textColor = CorralAestheticTokens.text; title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chips = NSStackView(views: host.routes.reduce(into: [ApprovedEndpoint.Route: String]()) { $0[$1.route] = $0[$1.route] ?? $1.host }
            .sorted { $0.key < $1.key }.map { CorralRouteChip(route: $0.key, address: $0.value) })
        chips.orientation = .horizontal; chips.spacing = 5
        if chips.arrangedSubviews.isEmpty { chips.addArrangedSubview(CorralRouteChip(route: .loopback, address: nil)) }
        let text = NSStackView(views: [title, chips]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 4
        text.setHuggingPriority(.init(1), for: .horizontal)
        let badge = CorralPillLabel(text: "已配对", tint: CorralAestheticTokens.successDeep); badge.isHidden = !paired
        check.image = CorralLegacyIcon.image(.check, size: 14, tint: CorralAestheticTokens.accent); check.contentTintColor = CorralAestheticTokens.accent
        check.isHidden = true
        let trailing = NSStackView(views: [badge, check]); trailing.orientation = .horizontal; trailing.spacing = 8
        trailing.setHuggingPriority(.required, for: .horizontal)
        for view in [tile, glyph, text, trailing] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 32), tile.heightAnchor.constraint(equalToConstant: 32),
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor), glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 11), text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), trailing.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel([host.name, paired ? "已配对" : nil].compactMap { $0 }.joined(separator: "，"))
        setAccessibilityIdentifier("corral.nearby.host")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || hovering else { return }
        let box = bounds.insetBy(dx: 1, dy: 1)
        let selection = CorralAestheticTokens.isDark ? CorralAestheticTokens.selectionBackground : CorralAestheticTokens.accent.withAlphaComponent(0.08)
        (isSelected ? selection : CorralAestheticTokens.hoverSubtle).setFill()
        NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9).fill()
        guard isSelected else { return }
        let ring = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 8.5, yRadius: 8.5); ring.lineWidth = 1
        CorralAestheticTokens.accent.withAlphaComponent(0.55).setStroke(); ring.stroke()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect?(host.hostID) } }
    override func accessibilityPerformPress() -> Bool { onSelect?(host.hostID); return true }
}

/// Discover Nearby Hosts: Bonjour and Tailscale hosts as one list. Choosing a host asks for its pairing
/// token (unless it is already paired); the coordinator proves every route with identify before saving.
@MainActor
public final class NearbyHostsDialogViewController: CorralDialogViewController, NSTextFieldDelegate {
    public enum Phase: Equatable { case idle, verifying, failed(String) }
    public static let visibleRows = 4

    public required init?(coder: NSCoder) { nil }
    public private(set) var hosts: [NearbyHost] = []
    public private(set) var selectedHostID: String?
    public var pairedHostIDs: Set<String> { didSet { if isViewLoaded { reloadRows() } } }
    public var isScanning = false { didSet { if isViewLoaded { updateControls() } } }
    public var phase: Phase = .idle { didSet { if isViewLoaded { updateControls() } } }
    public let tokenField = CorralDialogSecureTextField()
    public var onConnect: ((NearbyHost, String?) -> Void)?
    public var onRescan: (() -> Void)?
    public var onAddManually: (() -> Void)?
    public var onCancel: (() -> Void)?
    public private(set) weak var connectButton: NSButton?
    public private(set) weak var rescanButton: NSButton?
    public override var canDismissWithEscape: Bool { phase != .verifying }
    public override var initialFirstResponder: NSView? { nil }

    private let subtitle = chrLabel("\u{00A0}", size: 12, color: CorralAestheticTokens.textMuted)
    private let headerPulse = CorralScanPulseView(diameter: 18)
    private let emptyPulse = CorralScanPulseView(diameter: 56)
    private let emptyTitle = chrLabel("\u{00A0}", size: 13, weight: .semibold, color: CorralAestheticTokens.text)
    private let emptyDetail = chrLabel("请确认对方 Mac 已运行 Corral 服务，\n并与本机处于同一局域网或 Tailscale 网络。", size: 11.5, color: CorralAestheticTokens.textMuted, lineHeight: 1.45)
    private let emptyState = NSView()
    private let listWell = NSView()
    private let listScroll = NSScrollView()
    private let listStack = NSStackView()
    private var listHeight: NSLayoutConstraint?
    private let tokenSection = NSStackView()
    private let tokenTitle = chrLabel("\u{00A0}", size: 11.5, weight: .semibold, color: CorralAestheticTokens.textMuted)
    private lazy var tokenBox = CorralDialogInputBox(field: tokenField, placeholder: "粘贴主机的配对 Token")
    private let statusRow = NSStackView()
    private let spinner = NSProgressIndicator()
    private let statusLabel = chrLabel("\u{00A0}", size: 11.5, color: CorralAestheticTokens.textSecondary)
    private var rows: [NearbyHostRowView] = []

    public init(pairedHostIDs: Set<String> = []) {
        self.pairedHostIDs = pairedHostIDs
        super.init()
    }

    public override func loadView() {
        let title = chrLabel("发现附近主机", size: 15, weight: .bold, color: CorralAestheticTokens.text)
        let heading = NSStackView(views: [title, subtitle]); heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 2
        heading.setHuggingPriority(.init(1), for: .horizontal)
        let rescan = CorralDialogButton(title: "重新扫描", kind: .plain, icon: .refresh, target: self, action: #selector(rescan))
        rescan.setAccessibilityIdentifier("corral.nearby.rescan"); rescanButton = rescan
        let header = NSStackView(views: [heading, headerPulse, rescan]); header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 8

        listStack.orientation = .vertical; listStack.alignment = .width; listStack.spacing = 2
        listStack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        let document = CorralFlippedView(); document.translatesAutoresizingMaskIntoConstraints = false
        listStack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(listStack)
        listScroll.documentView = document; listScroll.drawsBackground = false; listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true; listScroll.borderType = .noBorder; listScroll.scrollerStyle = .overlay
        listScroll.setAccessibilityIdentifier("corral.nearby.list")
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        Self.styleWell(listWell); listWell.addSubview(listScroll)
        let height = listWell.heightAnchor.constraint(equalToConstant: 0); listHeight = height
        NSLayoutConstraint.activate([
            height,
            listScroll.leadingAnchor.constraint(equalTo: listWell.leadingAnchor), listScroll.trailingAnchor.constraint(equalTo: listWell.trailingAnchor),
            listScroll.topAnchor.constraint(equalTo: listWell.topAnchor), listScroll.bottomAnchor.constraint(equalTo: listWell.bottomAnchor),
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor), listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: document.topAnchor), listStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: listScroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: listScroll.contentView.leadingAnchor)
        ])

        Self.styleWell(emptyState)
        emptyDetail.attributedStringValue = chrText(emptyDetail.stringValue, size: 11.5, color: CorralAestheticTokens.textMuted, lineHeight: 1.45, alignment: .center)
        for view in [emptyPulse, emptyTitle, emptyDetail] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; emptyState.addSubview(view) }
        NSLayoutConstraint.activate([
            emptyPulse.topAnchor.constraint(equalTo: emptyState.topAnchor, constant: 20), emptyPulse.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor),
            emptyTitle.topAnchor.constraint(equalTo: emptyPulse.bottomAnchor, constant: 12), emptyTitle.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor),
            emptyDetail.topAnchor.constraint(equalTo: emptyTitle.bottomAnchor, constant: 4),
            emptyDetail.leadingAnchor.constraint(equalTo: emptyState.leadingAnchor, constant: 28), emptyDetail.trailingAnchor.constraint(equalTo: emptyState.trailingAnchor, constant: -28),
            emptyDetail.bottomAnchor.constraint(equalTo: emptyState.bottomAnchor, constant: -20)
        ])
        emptyDetail.preferredMaxLayoutWidth = 324
        emptyState.setAccessibilityIdentifier("corral.nearby.empty")

        tokenField.delegate = self; tokenField.setAccessibilityIdentifier("corral.nearby.token")
        let tokenHint = chrLabel("主机上的 Corral 在「设备 → 配对移动端」中可复制；也可粘贴整段配对信息。", size: 11, color: CorralAestheticTokens.textMuted)
        tokenSection.orientation = .vertical; tokenSection.alignment = .leading; tokenSection.spacing = 6
        for view in [tokenTitle, tokenBox, tokenHint] as [NSView] { tokenSection.addArrangedSubview(view); view.widthAnchor.constraint(equalToConstant: 380).isActive = true }
        tokenSection.setCustomSpacing(6, after: tokenBox)

        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        statusRow.orientation = .horizontal; statusRow.alignment = .centerY; statusRow.spacing = 7
        statusRow.addArrangedSubview(spinner); statusRow.addArrangedSubview(statusLabel)
        statusLabel.preferredMaxLayoutWidth = 350

        let manual = CorralDialogButton(title: "手动添加…", kind: .plain, target: self, action: #selector(addManually))
        let cancel = CorralDialogButton(title: "取消", kind: .plain, target: self, action: #selector(cancelAction))
        let connect = CorralDialogButton(title: "连接", kind: .primary, target: self, action: #selector(connectAction))
        connect.keyEquivalent = "\r"; connect.setAccessibilityIdentifier("corral.nearby.connect"); connectButton = connect

        // The list and its empty state share one slot, so hiding either keeps the card's rhythm.
        let content = NSStackView(views: [listWell, emptyState]); content.orientation = .vertical; content.spacing = 0
        for view in [listWell, emptyState] { view.widthAnchor.constraint(equalToConstant: 380).isActive = true }
        subtitle.preferredMaxLayoutWidth = 270
        view = cardLayout([
            (header, 14),
            (content, 14),
            (tokenSection, 14),
            (statusRow, 14),
            (actionsRow([cancel, connect], leading: [manual]), 0)
        ])
        view.setAccessibilityIdentifier("corral.nearby.dialog")
        reloadRows()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        updateControls()
    }

    public func update(hosts: [NearbyHost]) {
        self.hosts = hosts
        if let selectedHostID, !hosts.contains(where: { $0.hostID == selectedHostID }) { self.selectedHostID = nil }
        if selectedHostID == nil, hosts.count == 1 { selectedHostID = hosts[0].hostID }
        if isViewLoaded { reloadRows() }
    }

    public func select(hostID: String) {
        guard phase != .verifying, hosts.contains(where: { $0.hostID == hostID }) else { return }
        selectedHostID = hostID
        if case .failed = phase { phase = .idle }
        rows.forEach { $0.isSelected = $0.host.hostID == hostID }
        updateControls()
        if needsToken { view.window?.makeFirstResponder(tokenField) }
    }

    public var selectedHost: NearbyHost? { hosts.first { $0.hostID == selectedHostID } }
    private var needsToken: Bool { selectedHost.map { !pairedHostIDs.contains($0.hostID) } ?? false }
    private var token: String { tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var isConnectEnabled: Bool { phase != .verifying && selectedHost != nil && (!needsToken || !token.isEmpty) }

    public func connect() {
        guard isConnectEnabled, let host = selectedHost else { return }
        onConnect?(host, needsToken ? token : nil)
    }

    /// A pasted pairing payload (QR JSON) fills the token when it belongs to the selected host.
    public override func handlePaste(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String, !token.isEmpty else { return false }
        if let hostID = object["host_id"] as? String, hosts.contains(where: { $0.hostID == hostID }) { select(hostID: hostID) }
        guard needsToken, (object["host_id"] as? String).map({ $0 == selectedHostID }) ?? true else { return false }
        tokenField.stringValue = token
        updateControls()
        return true
    }

    public func controlTextDidChange(_ obj: Notification) {
        if case .failed = phase { phase = .idle } else { updateControls() }
    }

    public override func handleEscape() { guard canDismissWithEscape else { return }; onCancel?(); dismiss() }
    @objc private func cancelAction() { handleEscape() }
    @objc private func connectAction() { connect() }
    @objc private func rescan() { guard phase != .verifying else { return }; onRescan?() }
    @objc private func addManually() { guard phase != .verifying else { return }; onAddManually?() }

    private func reloadRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = hosts.map { host in
            let row = NearbyHostRowView(host: host, paired: pairedHostIDs.contains(host.hostID))
            row.isSelected = host.hostID == selectedHostID
            row.onSelect = { [weak self] in self?.select(hostID: $0) }
            return row
        }
        rows.forEach { listStack.addArrangedSubview($0) }
        listHeight?.constant = hosts.isEmpty ? 0 : CGFloat(min(hosts.count, Self.visibleRows)) * (NearbyHostRowView.height + 2) + 6
        updateControls()
    }

    private func updateControls() {
        guard isViewLoaded else { return }
        let empty = hosts.isEmpty
        listWell.isHidden = empty
        emptyState.isHidden = !empty
        headerPulse.isHidden = !isScanning || empty
        headerPulse.isAnimating = isScanning && !empty
        emptyPulse.isAnimating = isScanning && empty
        rescanButton?.isHidden = isScanning
        let count = hosts.count
        subtitle.attributedStringValue = chrText(isScanning ? "正在搜索局域网与 Tailscale 上的 Corral 主机…"
            : count == 0 ? "未找到可用的主机" : "找到 \(count) 台主机 · 选择一台以连接", size: 12, color: CorralAestheticTokens.textMuted)
        emptyTitle.attributedStringValue = chrText(isScanning ? "正在扫描附近的主机…" : "附近没有发现 Corral 主机", size: 13, weight: .semibold,
                                                   color: CorralAestheticTokens.text, alignment: .center)
        tokenSection.isHidden = !needsToken
        if let host = selectedHost {
            tokenTitle.attributedStringValue = chrText("「\(host.name)」的配对 Token", size: 11.5, weight: .semibold, color: CorralAestheticTokens.textMuted)
        }
        switch phase {
        case .idle:
            statusRow.isHidden = true; spinner.stopAnimation(nil)
        case .verifying:
            statusRow.isHidden = false; spinner.isHidden = false; spinner.startAnimation(nil)
            statusLabel.attributedStringValue = chrText("正在验证主机身份…", size: 11.5, color: CorralAestheticTokens.textSecondary)
        case let .failed(message):
            statusRow.isHidden = false; spinner.isHidden = true; spinner.stopAnimation(nil)
            statusLabel.attributedStringValue = chrText(message, size: 11.5, color: CorralAestheticTokens.danger)
        }
        tokenField.isEnabled = phase != .verifying
        connectButton?.isEnabled = isConnectEnabled
        connectButton?.title = phase == .verifying ? "连接中…" : "连接"
    }
}

extension NearbyHostsDialogViewController {
    /// A recessed well (list or empty state): subtle fill, hairline ring, 11pt corners.
    static func styleWell(_ view: NSView) {
        view.wantsLayer = true; view.layer?.cornerRadius = 11; view.layer?.borderWidth = 1; view.layer?.masksToBounds = true
        view.layer?.borderColor = CorralAestheticTokens.ringTile.cgColor
        view.layer?.backgroundColor = (CorralAestheticTokens.isDark ? NSColor.black.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.03)).cgColor
    }
}

/// Top-left origin for stacked scroll content.
@MainActor
final class CorralFlippedView: NSView {
    override var isFlipped: Bool { true }
}
