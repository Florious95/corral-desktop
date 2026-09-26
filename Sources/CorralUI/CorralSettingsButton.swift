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

    private func configure() {
        image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        bezelStyle = .regularSquare
        contentTintColor = CorralAestheticTokens.text
        toolTip = "Settings"
        setAccessibilityLabel("Settings")
        wantsLayer = true
        layer?.backgroundColor = CorralAestheticTokens.surface2.cgColor
        layer?.cornerRadius = 5
        layer?.borderColor = CorralAestheticTokens.border.cgColor
        layer?.borderWidth = 1
    }
}
