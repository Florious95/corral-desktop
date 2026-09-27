import AppKit

@MainActor
public final class CorralSettingsButton: NSButton {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    public required init?(coder: NSCoder) {
        fatalError("CorralSettingsButton is created programmatically")
    }

    public func refreshTheme() { configure() }

    private func configure() {
        image = CorralLegacyIcon.image(.gear, size: 16, tint: CorralAestheticTokens.icon)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        bezelStyle = .regularSquare
        contentTintColor = CorralAestheticTokens.icon
        toolTip = "Settings"
        setAccessibilityLabel("Settings")
        wantsLayer = true
        layer?.backgroundColor = isHovered ? CorralAestheticTokens.hover.cgColor : NSColor.clear.cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 0
    }

    private var isHovered = false { didSet { configure() } }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }
    public override func mouseEntered(with event: NSEvent) { isHovered = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false }
}
