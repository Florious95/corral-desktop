import AppKit
import CorralContracts

public enum CorralThemeMode: String, CaseIterable, Sendable {
    case light, dark, system
}

@MainActor
public enum CorralAestheticTokens {
    public static var themeMode: CorralThemeMode = .dark
    private static var isDark: Bool {
        switch themeMode {
        case .dark: true
        case .light: false
        case .system: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }
    public static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    private static func palette(_ dark: UInt32, _ light: UInt32) -> NSColor { color(isDark ? dark : light) }
    public static var background: NSColor { palette(0x0F1115, 0xFBFAF8) }
    public static var surface0: NSColor { palette(0x171B22, 0xF5F3EF) }
    public static var surface1: NSColor { palette(0x1E242D, 0xFDFCFB) }
    public static var surface2: NSColor { palette(0x272F3A, 0xFFFFFF) }
    public static var surface3: NSColor { palette(0x323D4B, 0xE8E5E0) }
    public static var text: NSColor { palette(0xE5E7EB, 0x3A3835) }
    public static var textSecondary: NSColor { palette(0xB7C0CD, 0x6D6A63) }
    public static var textMuted: NSColor { palette(0x9DAABB, 0x8A867E) }
    public static var borderSubtle: NSColor { isDark ? color(0x2A323E) : NSColor.black.withAlphaComponent(0.06) }
    public static var border: NSColor { isDark ? color(0x3A4554) : NSColor.black.withAlphaComponent(0.07) }
    public static var inputBorder: NSColor { isDark ? color(0x6D7B90) : NSColor.black.withAlphaComponent(0.12) }
    public static var tabActiveBackground: NSColor { isDark ? color(0x272F3A) : color(0xFBFAF8).withAlphaComponent(0.94) }
    public static var tabActiveBorder: NSColor { isDark ? color(0x3A4554) : NSColor.black.withAlphaComponent(0.12) }
    public static var icon: NSColor { palette(0xAAB6C5, 0x8A867E) }
    public static var hover: NSColor { isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.06) }
    public static var hoverSubtle: NSColor { isDark ? NSColor.white.withAlphaComponent(0.04) : NSColor.black.withAlphaComponent(0.04) }
    public static var fieldBackground: NSColor { palette(0x171B22, 0xFFFFFF) }
    public static var cardBackground: NSColor { isDark ? color(0x272F3A).withAlphaComponent(0.98) : color(0xFCFBF9).withAlphaComponent(0.85) }
    public static var dialogBackground: NSColor { isDark ? color(0x1E242D).withAlphaComponent(0.98) : color(0xFCFBF9).withAlphaComponent(0.92) }
    public static var previewBackground: NSColor { palette(0x0F1115, 0x3A3835) }
    public static var previewForeground: NSColor { palette(0xD5DCE6, 0xFBFAF8) }
    public static var previewCaption: NSColor { palette(0x9DAABB, 0xC4C0B7) }
    public static var choiceSelectedBackground: NSColor { palette(0x28374C, 0x3A3835) }
    public static var choiceSelectedForeground: NSColor { palette(0xDCE8FF, 0xFFFFFF) }
    public static var choiceSelectedBorder: NSColor { palette(0x5C79A3, 0x3A3835) }
    public static var actionPrimaryBackground: NSColor { palette(0x8FAADC, 0x3A3835) }
    public static var actionPrimaryForeground: NSColor { palette(0x111722, 0xFFFFFF) }
    public static var fillSubtle: NSColor { isDark ? color(0x1E242D) : NSColor.black.withAlphaComponent(0.04) }
    public static var selectionBackground: NSColor { isDark ? color(0x28374C) : NSColor.black.withAlphaComponent(0.07) }
    public static var accent: NSColor { palette(0x8FAADC, 0x2E5898) }
    /// `--pane-active-border`: the focused split pane outline (light falls back to `--input-focus`).
    public static var paneActiveBorder: NSColor { palette(0x5C79A3, 0xB8A273) }
    public static var success: NSColor { palette(0x72BE93, 0x34C759) }
    public static var successDeep: NSColor { palette(0x72BE93, 0x3F7A4C) }
    public static var warning: NSColor { palette(0xD8B57B, 0xF0B429) }
    public static var danger: NSColor { palette(0xF08A93, 0xC42B1C) }
    public static var idleDot: NSColor { palette(0x8291A5, 0xB8B4AB) }
    public static var unknownDot: NSColor { palette(0x8291A5, 0x201E1D) }
    public static var remoteBadgeBackground: NSColor { isDark ? warning.withAlphaComponent(0.15) : color(0xF1E8D8) }
    public static var remoteBadgeForeground: NSColor { palette(0xD8B57B, 0x8A713D) }
    public static var providerIdleOpacity: CGFloat { isDark ? 0.65 : 0.4 }
    public static let multiDeviceBadgeMaximumWidth = CGFloat(DesignTokens.multiDeviceBadgeMaximumWidthPixels)

    public static func remap(_ source: NSColor) -> NSColor {
        guard let resolved = source.usingColorSpace(.sRGB) else { return source }
        let pairs: [(NSColor, NSColor)] = [
            (color(0x0F1115), color(0xFBFAF8)), (color(0x171B22), color(0xF5F3EF)),
            (color(0x1E242D), color(0xFDFCFB)), (color(0x272F3A), color(0xFFFFFF)),
            (color(0x323D4B), color(0xE8E5E0)), (color(0xE5E7EB), color(0x3A3835)),
            (color(0xB7C0CD), color(0x6D6A63)), (color(0x9DAABB), color(0x8A867E)),
            (color(0x2A323E), NSColor.black.withAlphaComponent(0.06)),
            (color(0x3A4554), NSColor.black.withAlphaComponent(0.07)),
            (color(0x6D7B90), NSColor.black.withAlphaComponent(0.12)),
            (color(0x8FAADC), color(0x2E5898)), (color(0x72BE93), color(0x34C759)),
            (color(0xD8B57B), color(0xF0B429)), (color(0xF08A93), color(0xC42B1C)),
            (color(0x8291A5), color(0xB8B4AB)), (color(0x8291A5), color(0x201E1D)),
            (color(0x272F3A), color(0xFBFAF8).withAlphaComponent(0.94)),
            (color(0x28374C), NSColor.black.withAlphaComponent(0.07)),
            (color(0xD8B57B).withAlphaComponent(0.15), color(0xF1E8D8))
        ]
        for (dark, light) in pairs {
            let darkValue = dark.usingColorSpace(.sRGB)!
            let lightValue = light.usingColorSpace(.sRGB)!
            if matches(resolved, darkValue) || matches(resolved, lightValue) { return isDark ? dark : light }
        }
        return source
    }

    private static func matches(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) < 0.002 && abs(lhs.greenComponent - rhs.greenComponent) < 0.002 && abs(lhs.blueComponent - rhs.blueComponent) < 0.002 && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.002
    }
}

@MainActor
public final class CorralDeviceBadgeView: NSView {
    public let titleLabel = NSTextField(labelWithString: "")
    public private(set) var fullDeviceName = ""
    public static let maximumAllowedWidth = CGFloat(DesignTokens.multiDeviceBadgeMaximumWidthPixels)
    public var maximumWidth: CGFloat { Self.maximumAllowedWidth }
    public var displayedText: String { titleLabel.stringValue }
    public func update(deviceName: String, deviceCount: Int) { configure(deviceName: deviceName, deviceCount: deviceCount) }
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = CorralAestheticTokens.remoteBadgeBackground.cgColor
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = CorralAestheticTokens.remoteBadgeForeground
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.maximumAllowedWidth),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    public required init?(coder: NSCoder) { fatalError("CorralDeviceBadgeView is created programmatically") }
    public override var intrinsicContentSize: NSSize { NSSize(width: min(Self.maximumAllowedWidth, titleLabel.intrinsicContentSize.width + 12), height: 18) }
    public func configure(deviceName: String, deviceCount: Int) {
        fullDeviceName = deviceName
        isHidden = deviceCount <= 1
        toolTip = isHidden ? nil : deviceName
        titleLabel.toolTip = isHidden ? nil : deviceName
        titleLabel.stringValue = deviceName
        refreshTheme()
    }
    public func refreshTheme() {
        layer?.backgroundColor = CorralAestheticTokens.remoteBadgeBackground.cgColor
        titleLabel.textColor = CorralAestheticTokens.remoteBadgeForeground
    }
}

@MainActor
public final class CorralStatusIndicatorView: NSView {
    public enum Status: String, Sendable { case working, idle, blocked, done, offline, unknown }
    public var status: Status = .idle { didSet { needsDisplay = true; updatePulse() } }
    /// Tab lamps (`.tb-tab-lamp.is-idle`) render idle as a filled dot; sidebar dots stay hollow.
    public var fillsIdle = false { didSet { needsDisplay = true } }
    public override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }
    public override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true; updatePulse() }
    public required init?(coder: NSCoder) { fatalError("CorralStatusIndicatorView is created programmatically") }
    public override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: NSRect(origin: .zero, size: bounds.size))
        switch status {
        case .working, .blocked, .done:
            let color = switch status { case .working: CorralAestheticTokens.success; case .blocked: CorralAestheticTokens.warning; default: CorralAestheticTokens.successDeep }
            color.setFill(); circle.fill()
        case .idle where fillsIdle:
            CorralAestheticTokens.idleDot.setFill(); circle.fill()
        case .idle, .offline:
            CorralAestheticTokens.idleDot.setStroke(); circle.lineWidth = 1.2; circle.stroke()
        case .unknown:
            CorralAestheticTokens.unknownDot.setStroke(); circle.lineWidth = 1.5; circle.stroke()
        }
    }
    public func refreshTheme() { needsDisplay = true; updatePulse() }
    private func updatePulse() {
        layer?.removeAnimation(forKey: "workingPulse")
        layer?.opacity = 1
        switch status {
        case .working:
            layer?.shadowColor = CorralAestheticTokens.success.cgColor
            layer?.shadowOpacity = 0.45
            layer?.shadowRadius = 5
        case .blocked:
            layer?.shadowColor = CorralAestheticTokens.warning.cgColor
            layer?.shadowOpacity = 0.45
            layer?.shadowRadius = 5
        case .done, .idle, .offline, .unknown:
            layer?.shadowOpacity = 0
        }
    }
}

@MainActor
public final class CorralInlineRenameField: NSTextField {
    public var onCommit: ((String) -> Void)?
    public var onCancel: (() -> Void)?
    private var didFinish = false
    public func beginEditing() { didFinish = false }
    public static func shouldCommitReturn(hasMarkedText: Bool) -> Bool { !hasMarkedText }
    public func finish(commit: Bool) {
        guard !didFinish else { return }
        didFinish = true
        if commit { onCommit?(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) } else { onCancel?() }
    }
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if !Self.shouldCommitReturn(hasMarkedText: (currentEditor() as? NSTextView)?.hasMarkedText() == true) { super.keyDown(with: event) }
            else { finish(commit: true) }
        } else if event.keyCode == 53 { finish(commit: false) }
        else { super.keyDown(with: event) }
    }
}
