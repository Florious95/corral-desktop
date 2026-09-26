import AppKit

@MainActor
public final class CorralProviderIconView: NSImageView {
    public let provider: String
    public let isActive: Bool

    public init(provider: String, size: CGFloat = 18, active: Bool = false) {
        self.provider = provider
        isActive = active
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        imageScaling = .scaleProportionallyUpOrDown
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size)])
        if let data = Self.data(for: provider), let image = NSImage(data: data) {
            self.image = image
            image.isTemplate = Self.isMonochrome(provider)
            contentTintColor = CorralAestheticTokens.text
            alphaValue = active ? 1 : CorralAestheticTokens.providerIdleOpacity
        } else {
            let mark = String(provider.prefix(1)).uppercased()
            let tint = Self.fallbackTint(for: provider, active: active)
            let fallback = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                tint.setStroke()
                let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)); circle.lineWidth = 1.5; circle.stroke()
                (mark as NSString).draw(at: NSPoint(x: rect.midX - 3, y: rect.midY - 4), withAttributes: [.font: NSFont.systemFont(ofSize: size * 0.5, weight: .bold), .foregroundColor: tint])
                return true
            }
            fallback.isTemplate = true
            self.image = fallback
            contentTintColor = tint
        }
        setAccessibilityLabel(provider)
    }

    public required init?(coder: NSCoder) { nil }
    public func refreshTheme() {
        if Self.data(for: provider) != nil {
            contentTintColor = CorralAestheticTokens.text
            alphaValue = isActive ? 1 : CorralAestheticTokens.providerIdleOpacity
        } else {
            contentTintColor = Self.fallbackTint(for: provider, active: isActive)
            alphaValue = 1
        }
    }

    private static func data(for provider: String) -> Data? {
        let encoded: String?
        switch provider.lowercased() {
        case "claude", "claude-code", "claude_code": encoded = CorralProviderAssetData.claudeCodeSVG
        case "codex", "openai": encoded = CorralProviderAssetData.codexSVG
        case "copilot": encoded = CorralProviderAssetData.copilotPNG
        case "grok": encoded = CorralProviderAssetData.grokPNG
        case "cursor": encoded = CorralProviderAssetData.cursorSVG
        case "pi": encoded = CorralProviderAssetData.piPNG
        default: encoded = nil
        }
        return encoded.flatMap { Data(base64Encoded: $0) }
    }

    private static func isMonochrome(_ provider: String) -> Bool {
        ["codex", "openai", "cursor", "pi", "grok"].contains(provider.lowercased())
    }

    private static func fallbackTint(for provider: String, active: Bool) -> NSColor {
        guard active else { return CorralAestheticTokens.textMuted }
        return switch provider.lowercased() {
        case "claude", "claude-code", "claude_code": CorralAestheticTokens.color(0xD97757)
        case "grok": CorralAestheticTokens.color(0x3A3835)
        case "opencode": CorralAestheticTokens.color(0x7A8A6E)
        case "zai", "z-code", "glm": CorralAestheticTokens.color(0x6B83B5)
        case "kimi": CorralAestheticTokens.color(0x8A713D)
        default: CorralAestheticTokens.textSecondary
        }
    }
}
