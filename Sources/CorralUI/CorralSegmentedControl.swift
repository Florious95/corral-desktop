import AppKit

/// The Corral segmented choice (settings `主题模式` style): an inset track with one raised selected pill.
/// Segments are real buttons in a radio group, so keyboard focus, VoiceOver and AX presses all work.
@MainActor
public final class CorralSegmentedControl: NSView {
    public struct Segment: Equatable {
        public let id: String
        public let title: String
        public let icon: CorralLegacyIcon?
        public init(id: String, title: String, icon: CorralLegacyIcon? = nil) { self.id = id; self.title = title; self.icon = icon }
    }

    public enum Size { case regular, compact }

    public var onSelect: ((String) -> Void)?
    public private(set) var segments: [Segment]
    public private(set) var buttons: [NSButton] = []
    public var selectedID: String? { didSet { refresh() } }
    /// A segment whose change is in flight shows a spinner instead of its icon.
    public var pendingID: String? { didSet { refresh() } }
    public var isEnabled = true { didSet { refresh() } }
    private let size: Size
    private var spinners: [String: NSProgressIndicator] = [:]

    public init(segments: [Segment], size: Size = .regular, identifier: String) {
        self.segments = segments
        self.size = size
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityIdentifier(identifier)
        for segment in segments {
            let button = CorralSegmentButton(title: segment.title, target: self, action: #selector(pressed(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(segment.id)
            button.isBordered = false
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.wantsLayer = true
            button.focusRingType = .default
            button.setButtonType(.onOff)
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityIdentifier("\(identifier).\(segment.id)")
            addSubview(button)
            buttons.append(button)
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            addSubview(spinner)
            spinners[segment.id] = spinner
        }
        refresh()
    }

    public required init?(coder: NSCoder) { fatalError("CorralSegmentedControl is created programmatically") }

    private var height: CGFloat { size == .compact ? 26 : 38 }
    private var inset: CGFloat { 3 }
    private var fontSize: CGFloat { size == .compact ? 11.5 : 12.5 }

    public override var intrinsicContentSize: NSSize {
        let widths = segments.map { segmentWidth($0) }
        let width = size == .compact ? widths.reduce(0, +) : (widths.max() ?? 60) * CGFloat(segments.count)
        return NSSize(width: width + inset * 2 + CGFloat(max(0, segments.count - 1)) * 2, height: height)
    }

    private func segmentWidth(_ segment: Segment) -> CGFloat {
        let text = (segment.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)]).width
        return ceil(text) + (segment.icon == nil ? 0 : 18) + (size == .compact ? 18 : 28)
    }

    public override func layout() {
        super.layout()
        let available = bounds.width - inset * 2 - CGFloat(max(0, segments.count - 1)) * 2
        let natural = segments.map { segmentWidth($0) }
        let total = natural.reduce(0, +)
        var x = inset
        for (index, button) in buttons.enumerated() {
            let width = size == .compact && total > 0 ? floor(available * natural[index] / total) : floor(available / CGFloat(buttons.count))
            button.frame = CGRect(x: x, y: inset, width: width, height: bounds.height - inset * 2)
            if let spinner = spinners[segments[index].id] {
                spinner.frame = CGRect(x: x + 7, y: (bounds.height - 16) / 2, width: 16, height: 16)
            }
            x += width + 2
        }
    }

    public func refreshTheme() { refresh() }

    private func refresh() {
        let radius: CGFloat = size == .compact ? 7 : 8
        layer?.cornerRadius = radius
        layer?.backgroundColor = CorralAestheticTokens.surface0.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = CorralAestheticTokens.borderSubtle.cgColor
        for (index, button) in buttons.enumerated() {
            let segment = segments[index]
            let active = segment.id == selectedID
            let pending = segment.id == pendingID
            button.isEnabled = isEnabled && pendingID == nil
            button.state = active ? .on : .off
            button.setAccessibilitySelected(active)
            button.layer?.cornerRadius = radius - 2
            button.layer?.backgroundColor = active ? CorralAestheticTokens.surface3.cgColor : NSColor.clear.cgColor
            button.layer?.borderWidth = active ? 1 : 0
            button.layer?.borderColor = CorralAestheticTokens.borderSubtle.cgColor
            let color = active ? CorralAestheticTokens.text : (isEnabled ? CorralAestheticTokens.textSecondary : CorralAestheticTokens.textMuted)
            button.contentTintColor = color
            button.image = pending ? nil : segment.icon.flatMap { CorralLegacyIcon.image($0, size: size == .compact ? 12 : 14) }
            let title = pending ? "    " + segment.title : segment.title
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: color, .font: NSFont.systemFont(ofSize: fontSize, weight: active ? .semibold : .regular)])
            if pending { spinners[segment.id]?.startAnimation(nil) } else { spinners[segment.id]?.stopAnimation(nil) }
        }
        setAccessibilityEnabled(isEnabled)
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        sender.state = id == selectedID ? .on : .off
        guard id != selectedID, isEnabled, pendingID == nil else { return }
        onSelect?(id)
    }
}

/// Segments receive the first click of an inactive window, like the terminal and split chrome do.
@MainActor
private final class CorralSegmentButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
