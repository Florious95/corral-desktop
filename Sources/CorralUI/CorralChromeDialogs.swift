import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CorralContracts
import Darwin
import UniformTypeIdentifiers
import Vision

@MainActor
private final class CorralDialogOverlayView: NSView {
    var onOutsideClick: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // `.chr-scrim`: a tinted veil over a light 3pt blur, so the workspace stays recognisable behind the card.
        wantsLayer = true; layerUsesCoreImageFilters = true
        layer?.backgroundColor = CorralAestheticTokens.scrim.cgColor; layer?.masksToBounds = true
        layer?.backgroundFilters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 3])].compactMap { $0 }
    }
    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard event.window !== window || !subviews.contains(where: { $0.frame.contains(point) }) else { return }
        onOutsideClick?()
    }
}

public struct CorralAgentLauncher: Equatable, Sendable {
    public let provider: String
    public let displayName: String
    public let supportsBypass: Bool
    public init(provider: String, displayName: String, supportsBypass: Bool) {
        self.provider = provider; self.displayName = displayName; self.supportsBypass = supportsBypass
    }
}

public struct CorralNewAgentRequest: Equatable, Sendable {
    public let name: String
    public let provider: String
    public let bypass: Bool
    public init(name: String, provider: String, bypass: Bool) { self.name = name; self.provider = provider; self.bypass = bypass }
}

public struct CorralSettingsValues: Equatable, Sendable {
    public var theme: CorralThemeMode
    public var fontFamily: String
    public var fontSize: Double
    public var directoryTracking: Bool
    public init(theme: CorralThemeMode = .system, fontFamily: String = "Cascadia Code, Consolas, Fira Code, JetBrains Mono, Menlo, Monaco, monospace", fontSize: Double = 13, directoryTracking: Bool = false) {
        self.theme = theme; self.fontFamily = fontFamily; self.fontSize = min(24, max(10, fontSize)); self.directoryTracking = directoryTracking
    }
}

@MainActor
open class CorralDialogViewController: NSViewController {
    public private(set) weak var presentedWindow: NSWindow?
    public private(set) var focusTraversalCount = 0
    private var overlayView: CorralDialogOverlayView?
    private weak var previousFirstResponder: NSResponder?
    private var eventMonitor: Any?
    private var sizesToContent = false
    open var canDismissWithEscape: Bool { true }
    open var initialFirstResponder: NSView? { focusableControls(in: view).first }

    public init() { super.init(nibName: nil, bundle: nil) }
    public required init?(coder: NSCoder) { nil }

    public func present(over window: NSWindow? = NSApp.keyWindow) {
        guard let window, let container = window.contentView else { return }
        loadViewIfNeeded()
        previousFirstResponder = window.firstResponder
        let overlay = CorralDialogOverlayView(frame: container.bounds)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.onOutsideClick = { [weak self] in guard let self, self.canDismissWithEscape else { return }; self.handleEscape() }
        overlay.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.centerXAnchor.constraint(equalTo: overlay.centerXAnchor), view.centerYAnchor.constraint(equalTo: overlay.centerYAnchor), view.widthAnchor.constraint(equalToConstant: view.frame.width)])
        if !sizesToContent { view.heightAnchor.constraint(equalToConstant: view.frame.height).isActive = true }
        container.addSubview(overlay)
        NSLayoutConstraint.activate([overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor), overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor), overlay.topAnchor.constraint(equalTo: container.topAnchor), overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        overlayView = overlay; presentedWindow = window; window.makeFirstResponder(initialFirstResponder)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.presentedWindow?.isKeyWindow == true else { return event }
            if event.keyCode == 53, self.canDismissWithEscape { self.handleEscape(); return nil }
            if event.keyCode == 48 { self.cycleFocus(backward: event.modifierFlags.contains(.shift)); return nil }
            if event.keyCode == 9, event.modifierFlags.contains(.command), let text = NSPasteboard.general.string(forType: .string), self.handlePaste(text) { return nil }
            return event
        }
    }

    open func handleEscape() { dismiss() }
    open func handlePaste(_ text: String) -> Bool { false }

    private func cycleFocus(backward: Bool) {
        guard let window = presentedWindow else { return }
        let controls = focusableControls(in: view)
        guard !controls.isEmpty else { return }
        let current = window.firstResponder as? NSView
        let currentOwner = (current as? NSTextView)?.delegate as? NSView ?? current
        let index = controls.firstIndex { $0 === currentOwner } ?? (backward ? 0 : -1)
        let next = (index + (backward ? -1 : 1) + controls.count) % controls.count
        window.makeFirstResponder(controls[next])
        focusTraversalCount += 1
    }

    private func focusableControls(in root: NSView) -> [NSView] {
        var found: [NSView] = []
        func visit(_ view: NSView) {
            if let control = view as? NSControl, control.isEnabled, !control.isHidden, control.acceptsFirstResponder { found.append(control) }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found
    }

    public func closeDialog() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        overlayView?.removeFromSuperview(); overlayView = nil
        if let previousView = previousFirstResponder as? NSView, previousView.window === presentedWindow { _ = presentedWindow?.makeFirstResponder(previousView) }
        previousFirstResponder = nil; presentedWindow = nil
    }

    public func rootView(size: NSSize) -> NSView { CorralDialogCardView(frame: NSRect(origin: .zero, size: size)) }

    /// `.chr-dialog` block flow: rows separated by their CSS bottom margins inside 20pt padding.
    /// The 420pt card hugs its rows, so it grows with a validation message instead of reserving a void.
    public func cardLayout(_ rows: [(view: NSView, marginBottom: CGFloat)]) -> NSView {
        let card = rootView(size: NSSize(width: 420, height: 0))
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20); stack.translatesAutoresizingMaskIntoConstraints = false
        for row in rows {
            stack.addArrangedSubview(row.view); stack.setCustomSpacing(row.marginBottom, after: row.view)
            row.view.widthAnchor.constraint(equalToConstant: 380).isActive = true
        }
        card.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: card.leadingAnchor), stack.trailingAnchor.constraint(equalTo: card.trailingAnchor), stack.topAnchor.constraint(equalTo: card.topAnchor), stack.bottomAnchor.constraint(equalTo: card.bottomAnchor), stack.widthAnchor.constraint(equalToConstant: 420)])
        card.setFrameSize(NSSize(width: 420, height: stack.fittingSize.height))
        sizesToContent = true
        return card
    }

    /// `.chr-actions`: right-aligned buttons with an 8pt gap.
    public func actionsRow(_ buttons: [NSButton]) -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 8
        buttons.forEach { row.addView($0, in: .trailing) }
        return row
    }

    public func addHeader(to root: NSView, title: String, subtitle: String? = nil, top: CGFloat = 26) -> CGFloat {
        let titleLabel = NSTextField(labelWithString: title); titleLabel.font = .systemFont(ofSize: 16, weight: .semibold); titleLabel.textColor = CorralAestheticTokens.text; titleLabel.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(titleLabel)
        NSLayoutConstraint.activate([titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: top)])
        guard let subtitle else { return top + 28 }
        let sub = NSTextField(labelWithString: subtitle); sub.font = .systemFont(ofSize: 11); sub.textColor = CorralAestheticTokens.textMuted; sub.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(sub)
        NSLayoutConstraint.activate([sub.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor), sub.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor), sub.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5)])
        return top + 47
    }

    public func addLabel(_ text: String, to root: NSView, x: CGFloat = 24, y: CGFloat, width: CGFloat = 400) -> NSTextField {
        let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 11, weight: .medium); label.textColor = CorralAestheticTokens.textSecondary; label.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: x), label.topAnchor.constraint(equalTo: root.topAnchor, constant: y), label.widthAnchor.constraint(lessThanOrEqualToConstant: width)])
        return label
    }

    public func addTextField(to root: NSView, placeholder: String, y: CGFloat, secure: Bool = false) -> NSTextField {
        let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
        field.placeholderString = placeholder; field.font = .systemFont(ofSize: 12); field.textColor = CorralAestheticTokens.text; field.backgroundColor = CorralAestheticTokens.surface0; field.isBezeled = true; field.bezelStyle = .roundedBezel; field.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(field)
        NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), field.topAnchor.constraint(equalTo: root.topAnchor, constant: y), field.heightAnchor.constraint(equalToConstant: 32)])
        return field
    }

    @discardableResult public func addActionButtons(to root: NSView, cancel: Selector, primary: Selector, primaryTitle: String = "完成", primaryEnabled: Bool = true) -> (cancel: NSButton, primary: NSButton) {
        let cancelButton = NSButton(title: "取消", target: self, action: cancel); cancelButton.bezelStyle = .rounded; cancelButton.translatesAutoresizingMaskIntoConstraints = false
        let primaryButton = NSButton(title: primaryTitle, target: self, action: primary); primaryButton.bezelStyle = .rounded; primaryButton.keyEquivalent = "\r"; primaryButton.isEnabled = primaryEnabled; primaryButton.translatesAutoresizingMaskIntoConstraints = false
        stylePrimary(primaryButton)
        root.addSubview(cancelButton); root.addSubview(primaryButton)
        NSLayoutConstraint.activate([cancelButton.trailingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: -8), cancelButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20), cancelButton.widthAnchor.constraint(equalToConstant: 74), primaryButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), primaryButton.bottomAnchor.constraint(equalTo: cancelButton.bottomAnchor), primaryButton.widthAnchor.constraint(equalToConstant: 84)])
        return (cancelButton, primaryButton)
    }

    public func stylePrimary(_ button: NSButton) {
        // `.chr-btn-primary`: action-primary fill, 8px radius, no bezel.
        button.isBordered = false; button.wantsLayer = true; button.layer?.backgroundColor = CorralAestheticTokens.actionPrimaryBackground.cgColor; button.layer?.cornerRadius = 8; button.layer?.borderWidth = 0
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [.foregroundColor: CorralAestheticTokens.actionPrimaryForeground, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        button.contentTintColor = CorralAestheticTokens.actionPrimaryForeground
    }

    public func dismiss() { closeDialog() }
}

// MARK: - Legacy `.chr-*` / `.nad-*` dialog primitives (chrome.css §4.3 / §4.4)

/// WebKit lays `-apple-system`/PingFang text out on 1.4em `normal` line boxes with the baseline 1.06em down.
/// TextKit puts a fixed-height line's baseline ceil(descender) above its bottom, so lift the glyphs by the difference.
@MainActor
func chrText(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, lineHeight: CGFloat = 1.4, alignment: NSTextAlignment = .natural) -> NSAttributedString {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let line = size * lineHeight
    let style = NSMutableParagraphStyle(); style.minimumLineHeight = line; style.maximumLineHeight = line; style.alignment = alignment
    let cssBaseline = (line - 1.4 * size) / 2 + 1.06 * size
    return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style, .baselineOffset: line - ceil(-font.descender) - cssBaseline])
}

/// A `chrText` label laid out on whole CSS line boxes; NSTextField alone rounds each label up to 0.5pt.
@MainActor
final class CorralDialogLabel: NSTextField {
    var lineHeight: CGFloat = 0
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if lineHeight > 0 { size.height = max(1, (size.height / lineHeight).rounded()) * lineHeight }
        return size
    }
}

@MainActor
func chrLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, lineHeight: CGFloat = 1.4) -> NSTextField {
    let label = CorralDialogLabel(wrappingLabelWithString: "")
    label.attributedStringValue = chrText(text, size: size, weight: weight, color: color, lineHeight: lineHeight)
    label.lineHeight = size * lineHeight; label.isSelectable = false; label.preferredMaxLayoutWidth = 380
    return label
}

/// `.chr-dialog` shell: 14pt glass card with the `--shadow-dialog` ring and soft drop shadow.
@MainActor
final class CorralDialogCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let dark = CorralAestheticTokens.isDark
        wantsLayer = true
        layer?.backgroundColor = CorralAestheticTokens.dialogBackground.cgColor; layer?.cornerRadius = 14
        layer?.borderWidth = dark ? 1 : 0.5; layer?.borderColor = CorralAestheticTokens.dialogRing.cgColor
        let drop = NSShadow(); drop.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.44 : 0.3)
        // CSS blur radii are twice the Gaussian spread AppKit takes (`0 24px 70px` / `0 24px 64px`).
        drop.shadowOffset = NSSize(width: 0, height: -24); drop.shadowBlurRadius = dark ? 32 : 35
        shadow = drop
    }
    required init?(coder: NSCoder) { nil }
}

/// `.chr-btn` (borderless, hover fill), `.chr-btn-primary` and `.cad-danger`: 8pt radius around a 7pt-padded 13pt line.
@MainActor
final class CorralDialogButton: NSButton {
    enum Kind { case plain, primary, danger }
    let kind: Kind
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String, kind: Kind, target: AnyObject?, action: Selector?) {
        self.kind = kind
        super.init(frame: .zero)
        self.title = title; self.target = target; self.action = action
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { nil }

    override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.5; hovering = hovering && isEnabled } }
    override var intrinsicContentSize: NSSize {
        let width = ceil(chrText(title, size: 13, weight: .semibold, color: .black).size().width)
        return NSSize(width: width + (kind == .plain ? 28 : 32), height: 32.2)
    }
    override func mouseEntered(with event: NSEvent) { hovering = isEnabled }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }
    override var focusRingMaskBounds: NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = isHighlighted && isEnabled
        let (fill, ink): (NSColor, NSColor) = switch kind {
        case .plain: (hovering || pressed ? CorralAestheticTokens.hover : .clear, CorralAestheticTokens.iconStrong)
        case .primary: (pressed ? CorralAestheticTokens.actionPrimaryPressed : hovering ? CorralAestheticTokens.actionPrimaryHover : CorralAestheticTokens.actionPrimaryBackground, CorralAestheticTokens.actionPrimaryForeground)
        case .danger: (hovering || pressed ? CorralAestheticTokens.dangerFillHover : CorralAestheticTokens.dangerFill, .white)
        }
        fill.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let line = NSRect(x: 0, y: (bounds.height - 18.2) / 2, width: bounds.width, height: 18.2)
        chrText(title, size: 13, weight: .semibold, color: ink, alignment: .center).draw(with: line, options: [.usesLineFragmentOrigin])
    }
}

/// `.chr-input` text: borderless; the surrounding `CorralDialogInputBox` draws its frame and focus ring.
@MainActor
public final class CorralDialogTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?
    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }
    public override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification); onFocusChange?(false)
    }
}

/// `.chr-input` frame: 8pt radius, 1pt border and a 3pt focus ring drawn outside its alignment rect.
@MainActor
final class CorralDialogInputBox: NSView {
    private static let ring: CGFloat = 3
    private var focused = false { didSet { needsDisplay = true } }

    init(field: CorralDialogTextField, placeholder: String) {
        super.init(frame: .zero)
        field.isBordered = false; field.isBezeled = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 13); field.textColor = CorralAestheticTokens.text
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: CorralAestheticTokens.textFaint])
        field.usesSingleLineMode = true; field.cell?.isScrollable = true; field.cell?.wraps = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.onFocusChange = { [weak self] in self?.focused = $0 }
        addSubview(field)
        // 1pt border + 10pt padding, less the field cell's own 2pt text inset.
        NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant: 36.2), field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9), field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9), field.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { nil }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: Self.ring, left: Self.ring, bottom: Self.ring, right: Self.ring) }
    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: Self.ring, dy: Self.ring)
        if focused { CorralAestheticTokens.inputFocusRing.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 8 + Self.ring, yRadius: 8 + Self.ring).fill() }
        CorralAestheticTokens.fieldBackground.setFill(); NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        let border = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.5, yRadius: 7.5); border.lineWidth = 1
        (focused ? CorralAestheticTokens.inputFocus : CorralAestheticTokens.inputBorder).setStroke(); border.stroke()
    }
}

/// `.nad-tile`: a 9pt-radius provider card (20pt icon over its 10.5pt name) with the tile ring drawn outside the box.
@MainActor
final class CorralProviderTileButton: NSButton {
    static let ring: CGFloat = 1.5
    override class var cellClass: AnyClass? { get { CorralProviderTileCell.self } set {} }
    private var hovering = false { didSet { needsDisplay = true } }

    init(launcher: CorralAgentLauncher, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        title = launcher.displayName; toolTip = launcher.displayName; identifier = NSUserInterfaceItemIdentifier(launcher.provider)
        image = CorralProviderIconView(provider: launcher.provider, size: 20, active: true).image
        setButtonType(.pushOnPushOff); isBordered = false; tag = launcher.supportsBypass ? 1 : 0
        self.target = target; self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 58.7).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: Self.ring, left: Self.ring, bottom: Self.ring, right: Self.ring) }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.5; hovering = hovering && isEnabled } }
    override func mouseEntered(with event: NSEvent) { hovering = isEnabled }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds.insetBy(dx: Self.ring, dy: Self.ring), xRadius: 9, yRadius: 9).fill() }
    override var focusRingMaskBounds: NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: Self.ring, dy: Self.ring)
        let selected = state == .on
        (selected ? CorralAestheticTokens.hover : hovering ? CorralAestheticTokens.hoverTile : .clear).setFill()
        NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9).fill()
        // `--ring-tile` / `--ring-tile-sel` are box-shadow spreads: they sit outside the 9pt box.
        let width: CGFloat = selected ? 1.5 : 0.5
        let ring = NSBezierPath(roundedRect: box.insetBy(dx: -width / 2, dy: -width / 2), xRadius: 9 + width / 2, yRadius: 9 + width / 2)
        ring.lineWidth = width; (selected ? CorralAestheticTokens.ringTileSelected : CorralAestheticTokens.ringTile).setStroke(); ring.stroke()
        if let image, let cell { icon(image).draw(in: cell.imageRect(forBounds: bounds), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
        let name = NSMutableAttributedString(attributedString: chrText(title, size: 10.5, color: CorralAestheticTokens.iconStrong, alignment: .center))
        if let style = (name.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            style.lineBreakMode = .byTruncatingTail; name.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: name.length))
        }
        name.draw(with: cell?.titleRect(forBounds: bounds) ?? .zero, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Monochrome marks keep their black artwork in light mode; dark mode mirrors `invert(.88) brightness(1.1)`.
    private func icon(_ image: NSImage) -> NSImage {
        guard image.isTemplate, CorralAestheticTokens.isDark else { return image }
        return NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect); CorralAestheticTokens.color(0xF7F7F7).set(); rect.fill(using: .sourceAtop); return true
        }
    }
}

/// `.nad-tile` geometry: 10pt top padding, 20pt icon, 6pt gap, then a 1.4em name line inside 4pt side padding.
@MainActor
private final class CorralProviderTileCell: NSButtonCell {
    override func imageRect(forBounds rect: NSRect) -> NSRect {
        let box = rect.insetBy(dx: CorralProviderTileButton.ring, dy: CorralProviderTileButton.ring)
        return NSRect(x: box.midX - 10, y: box.minY + 10, width: 20, height: 20)
    }
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let box = rect.insetBy(dx: CorralProviderTileButton.ring + 4, dy: CorralProviderTileButton.ring)
        return NSRect(x: box.minX, y: box.minY + 36, width: box.width, height: 10.5 * 1.4)
    }
}

/// `.nad-switch`: 38×23 pill (`--toggle-off` / `--brand`) with a 19pt white knob.
@MainActor
public final class CorralDialogSwitch: NSButton {
    public init() {
        super.init(frame: .zero)
        setButtonType(.toggle); isBordered = false; title = ""
        setAccessibilityRole(.checkBox); setAccessibilitySubrole(.switch)
        translatesAutoresizingMaskIntoConstraints = false
    }
    public required init?(coder: NSCoder) { nil }
    public override var intrinsicContentSize: NSSize { NSSize(width: 38, height: 23) }
    public override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    public override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.5 } }
    public override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill() }
    public override var focusRingMaskBounds: NSRect { bounds }
    public override func draw(_ dirtyRect: NSRect) {
        let on = state == .on
        (on ? CorralAestheticTokens.brand : CorralAestheticTokens.toggleOff).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        NSGraphicsContext.saveGraphicsState()
        let knobShadow = NSShadow(); knobShadow.shadowColor = NSColor.black.withAlphaComponent(CorralAestheticTokens.isDark ? 0.36 : 0.25)
        knobShadow.shadowOffset = NSSize(width: 0, height: -1); knobShadow.shadowBlurRadius = 3; knobShadow.set()
        NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: on ? 17 : 2, y: 2, width: 19, height: 19)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
public final class NewAgentDialogViewController: CorralDialogViewController, NSTextFieldDelegate {
    public required init?(coder: NSCoder) { nil }
    public override var initialFirstResponder: NSView? { nameField }
    public let spaceName: String
    public let launchers: [CorralAgentLauncher]
    public let nameField = CorralDialogTextField()
    public let bypassSwitch = CorralDialogSwitch()
    public private(set) var selectedProvider: String?
    public private(set) var validationMessage: String?
    public override var canDismissWithEscape: Bool { !isLoading }
    public var isLoading = false { didSet { updateControls() } }
    public var onCreate: ((CorralNewAgentRequest) -> Void)?
    public var onCancel: (() -> Void)?
    public private(set) weak var cancelButton: NSButton?
    public private(set) weak var createButton: NSButton?
    private let errorLabel = chrLabel("", size: 11, color: CorralAestheticTokens.danger)
    private let loadingLabel = chrLabel("\u{00A0}", size: 11.5, color: CorralAestheticTokens.textSecondary)
    private lazy var nameBox = CorralDialogInputBox(field: nameField, placeholder: "任务名称")
    private let bypassRow = NSView()
    private weak var cardStack: NSStackView?
    private var launcherButtons: [NSButton] = []

    public init(spaceName: String, launchers: [CorralAgentLauncher] = [], onCreate: ((CorralNewAgentRequest) -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        let advertised = launchers.isEmpty ? [
            CorralAgentLauncher(provider: "claude_code", displayName: "Claude Code", supportsBypass: true),
            CorralAgentLauncher(provider: "codex", displayName: "Codex", supportsBypass: true),
            CorralAgentLauncher(provider: "cursor", displayName: "Cursor", supportsBypass: false),
            CorralAgentLauncher(provider: "grok", displayName: "Grok", supportsBypass: false),
            CorralAgentLauncher(provider: "pi", displayName: "Pi", supportsBypass: true)
        ] : launchers
        self.spaceName = spaceName; self.launchers = advertised; self.onCreate = onCreate; self.onCancel = onCancel; selectedProvider = advertised.first?.provider
        super.init()
    }

    // Mirrors `NewAgentDialog.jsx`: title, task name, 4-column provider grid, bypass card, reserved status line, actions.
    public override func loadView() {
        nameField.delegate = self
        let cancel = CorralDialogButton(title: "取消", kind: .plain, target: self, action: #selector(cancel))
        let create = CorralDialogButton(title: "创建", kind: .primary, target: self, action: #selector(create)); create.keyEquivalent = "\r"
        cancelButton = cancel; createButton = create
        errorLabel.isHidden = true
        view = cardLayout([
            (chrLabel("新建 Agent", size: 15, weight: .bold, color: CorralAestheticTokens.text), 2),
            (chrLabel("在「\(spaceName)」中创建", size: 12, color: CorralAestheticTokens.textMuted), 14),
            (chrLabel("任务名称", size: 11.5, weight: .semibold, color: CorralAestheticTokens.textMuted), 6),
            (nameBox, 14),
            (errorLabel, 12),
            (chrLabel("选择 Agent", size: 11.5, weight: .semibold, color: CorralAestheticTokens.textMuted), 8),
            (launcherGrid(), 14),
            (bypassCard(), 16),
            (loadingLabel, 12),
            (actionsRow([cancel, create]), 0)
        ])
        cardStack = view.subviews.first as? NSStackView
        updateControls()
    }

    /// `.nad-grid`: four equal columns with 8pt gaps; extra launchers wrap onto further rows.
    private func launcherGrid() -> NSView {
        let grid = NSStackView(); grid.orientation = .vertical; grid.alignment = .leading; grid.spacing = 8
        for start in stride(from: 0, to: launchers.count, by: 4) {
            let row = NSStackView(); row.orientation = .horizontal; row.distribution = .fillEqually; row.spacing = 8
            for launcher in launchers[start..<min(start + 4, launchers.count)] {
                let tile = CorralProviderTileButton(launcher: launcher, target: self, action: #selector(selectLauncher(_:)))
                row.addArrangedSubview(tile); launcherButtons.append(tile)
            }
            for _ in row.arrangedSubviews.count..<4 { row.addArrangedSubview(NSView()) }
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        return grid
    }

    /// `.nad-bypass`: 9pt-radius `--fill-subtle` card; dimmed when the selected launcher cannot bypass.
    private func bypassCard() -> NSView {
        bypassRow.wantsLayer = true; bypassRow.layer?.backgroundColor = CorralAestheticTokens.fillSubtle.cgColor; bypassRow.layer?.cornerRadius = 9
        let title = chrLabel("Bypass permissions", size: 12.5, weight: .semibold, color: CorralAestheticTokens.warnText)
        let detail = chrLabel("允许 Agent 不经确认执行 shell 命令", size: 11, color: CorralAestheticTokens.textMuted)
        bypassSwitch.target = self; bypassSwitch.action = #selector(toggleBypass); bypassSwitch.setAccessibilityLabel("Bypass permissions")
        bypassSwitch.identifier = NSUserInterfaceItemIdentifier("corral.newagent.bypass")
        for view in [title, detail, bypassSwitch] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; bypassRow.addSubview(view) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: bypassRow.topAnchor, constant: 10), title.leadingAnchor.constraint(equalTo: bypassRow.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: bypassSwitch.leadingAnchor, constant: -10),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1), detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: bypassSwitch.leadingAnchor, constant: -10),
            detail.bottomAnchor.constraint(equalTo: bypassRow.bottomAnchor, constant: -10),
            bypassSwitch.trailingAnchor.constraint(equalTo: bypassRow.trailingAnchor, constant: -12), bypassSwitch.centerYAnchor.constraint(equalTo: bypassRow.centerYAnchor)
        ])
        return bypassRow
    }

    public var isCreateEnabled: Bool { validationMessage == nil && !nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedLauncher != nil && !isLoading }
    public func submit() {
        validateName(); guard isCreateEnabled, let launcher = selectedLauncher else { return }
        onCreate?(CorralNewAgentRequest(name: nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), provider: launcher.provider, bypass: launcher.supportsBypass && bypassSwitch.state == .on))
    }
    private var selectedLauncher: CorralAgentLauncher? { launchers.first { $0.provider == selectedProvider } }
    public func controlTextDidChange(_ notification: Notification) { validateName(); updateControls() }
    @objc private func selectLauncher(_ sender: NSButton) { selectedProvider = sender.identifier?.rawValue; if sender.tag == 0 { bypassSwitch.state = .off }; updateControls() }
    @objc private func toggleBypass() { updateControls() }
    public override func handleEscape() { guard !isLoading else { return }; onCancel?(); dismiss() }
    @objc private func cancel() { guard !isLoading else { return }; onCancel?(); dismiss() }
    @objc private func create() { submit() }
    private func validateName() {
        let name = nameField.stringValue
        validationMessage = name.unicodeScalars.count > 64 ? "名称不能超过 64 个字符" : name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? "名称不能包含控制字符" : nil
        guard isViewLoaded else { return }
        // `.nad-error` pulls up 10pt into the input's 14pt margin.
        errorLabel.attributedStringValue = chrText(validationMessage ?? "", size: 11, color: CorralAestheticTokens.danger)
        errorLabel.isHidden = validationMessage == nil
        cardStack?.setCustomSpacing(validationMessage == nil ? 14 : 4, after: nameBox)
    }
    private func updateControls() {
        guard isViewLoaded else { return }
        let bypassSupported = selectedLauncher?.supportsBypass == true
        bypassSwitch.isEnabled = !isLoading && bypassSupported
        bypassRow.alphaValue = bypassSupported ? 1 : 0.5
        for button in launcherButtons {
            button.isEnabled = !isLoading; button.state = button.identifier?.rawValue == selectedProvider ? .on : .off
            button.setAccessibilitySelected(button.state == .on)
        }
        nameField.isEnabled = !isLoading
        cancelButton?.isEnabled = !isLoading
        createButton?.isEnabled = isCreateEnabled
        createButton?.title = isLoading ? "创建中…" : "创建"
        loadingLabel.attributedStringValue = chrText(isLoading ? "正在创建 Agent…" : "\u{00A0}", size: 11.5, color: CorralAestheticTokens.textSecondary)
    }
}

@MainActor
public final class SettingsDialogViewController: CorralDialogViewController {
    public required init?(coder: NSCoder) { nil }
    public private(set) var values: CorralSettingsValues
    public var onChange: ((CorralSettingsValues) -> Void)?
    public var onClose: (() -> Void)?
    /// `TERMINAL_FONT_FAMILIES` presets; each pill is labelled with its primary family.
    public static let fontPresets = ["Cascadia Code, Consolas", "JetBrains Mono, \"Andale Mono\", Menlo, \"Lucida Console\"", "Fira Code, Monaco, \"Courier New\"", "Menlo, \"Segoe UI Mono\"", "Consolas, \"Andale Mono\"", "Courier New"]
    public private(set) var themeButtons: [NSButton] = []
    public private(set) var fontPresetButtons: [NSButton] = []
    public let fontFamilyField = NSTextField(string: "")
    public let fontSizeSlider = NSSlider(value: 13, minValue: 10, maxValue: 24, target: nil, action: nil)
    public let fontSizeField = NSTextField(string: "13")
    public let fontSizeDecrementButton = NSButton(title: "−", target: nil, action: nil)
    public let fontSizeIncrementButton = NSButton(title: "+", target: nil, action: nil)
    public let directoryTrackingSwitch = NSSwitch()
    public private(set) var fontPreviewLabel: NSTextField?
    private let previewSizeCaption = NSTextField(labelWithString: "")
    public static let width: CGFloat = 560

    public init(values: CorralSettingsValues = CorralSettingsValues(), onChange: ((CorralSettingsValues) -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.values = values; self.onChange = onChange; self.onClose = onClose; super.init()
    }

    // Mirrors `SettingsDialog.jsx`: header, three titled cards (界面外观 / 终端外观 / 工作区行为), footer.
    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 600))
        root.wantsLayer = true; root.layer?.backgroundColor = CorralAestheticTokens.dialogBackground.cgColor; root.layer?.cornerRadius = 18
        root.setAccessibilityIdentifier("corral.settings.dialog")

        let title = label("设置", size: 20, weight: .semibold, color: CorralAestheticTokens.text)
        let subtitle = label("微调终端外观，让工作区更顺手。", size: 12, color: CorralAestheticTokens.textSecondary)
        let heading = vertical([title, subtitle], spacing: 6)
        let closeButton = NSButton(image: CorralLegacyIcon.image(.close, size: 12) ?? NSImage(), target: self, action: #selector(close))
        closeButton.isBordered = false; closeButton.focusRingType = .none; closeButton.contentTintColor = CorralAestheticTokens.textSecondary; closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = CorralAestheticTokens.fillSubtle.cgColor; closeButton.layer?.cornerRadius = 15
        closeButton.setAccessibilityLabel("关闭设置"); closeButton.setAccessibilityIdentifier("corral.settings.close")
        pin(closeButton, width: 30, height: 30)
        let header = horizontal([heading, spacer(), closeButton], alignment: .top)

        let modes: [(CorralThemeMode, String, CorralLegacyIcon)] = [(.light, "浅色", .sun), (.dark, "深色", .moon), (.system, "跟随系统", .monitor)]
        themeButtons = modes.map { mode, title, icon in
            let button = NSButton(title: title, image: CorralLegacyIcon.image(icon, size: 14) ?? NSImage(), target: self, action: #selector(themeButtonPressed(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(mode.rawValue); button.setAccessibilityIdentifier("corral.settings.theme.\(mode.rawValue)")
            button.isBordered = false; button.imagePosition = .imageLeading; button.imageHugsTitle = true; button.wantsLayer = true; button.layer?.cornerRadius = 6
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            return button
        }
        let segmented = horizontal(themeButtons, spacing: 4, distribution: .fillEqually)
        segmented.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        segmented.wantsLayer = true; segmented.layer?.backgroundColor = CorralAestheticTokens.surface0.cgColor; segmented.layer?.cornerRadius = 8
        segmented.layer?.borderWidth = 1; segmented.layer?.borderColor = CorralAestheticTokens.borderSubtle.cgColor
        let themeCard = card([fieldHeading("主题模式", hint: "浅色、深色或跟随系统外观"), segmented])

        fontPresetButtons = Self.fontPresets.map { preset in
            let name = Self.primaryFamily(preset)
            let button = NSButton(title: name, target: self, action: #selector(fontPresetPressed(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(preset); button.setAccessibilityIdentifier("corral.settings.font.\(name)")
            button.isBordered = false; button.wantsLayer = true; button.layer?.cornerRadius = 14; button.layer?.borderWidth = 1
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            return button
        }
        let presetRows = stride(from: 0, to: fontPresetButtons.count, by: 3).map { horizontal(Array(fontPresetButtons[$0..<min($0 + 3, fontPresetButtons.count)]), spacing: 7, distribution: .fillEqually) }
        let customLabel = label("自定义字体栈", size: 11, color: CorralAestheticTokens.textSecondary)
        fontFamilyField.font = .monospacedSystemFont(ofSize: 11, weight: .regular); fontFamilyField.textColor = CorralAestheticTokens.text
        fontFamilyField.isBezeled = false; fontFamilyField.drawsBackground = false; fontFamilyField.lineBreakMode = .byTruncatingTail; fontFamilyField.cell?.usesSingleLineMode = true
        fontFamilyField.target = self; fontFamilyField.action = #selector(fontFieldCommitted); fontFamilyField.setAccessibilityIdentifier("corral.settings.font.custom")
        let fontInput = inputBox(fontFamilyField, insets: NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10))

        fontSizeSlider.target = self; fontSizeSlider.action = #selector(sizeChanged); fontSizeSlider.setAccessibilityIdentifier("corral.settings.fontsize.slider")
        for (button, action, name) in [(fontSizeDecrementButton, #selector(decrementSize), "减小字号"), (fontSizeIncrementButton, #selector(incrementSize), "增大字号")] {
            button.isBordered = false; button.font = .systemFont(ofSize: 15); button.target = self; button.action = action; button.setAccessibilityLabel(name)
            pin(button, width: 26, height: 26)
        }
        fontSizeField.isBezeled = false; fontSizeField.drawsBackground = false; fontSizeField.alignment = .center; fontSizeField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        fontSizeField.textColor = CorralAestheticTokens.text; fontSizeField.target = self; fontSizeField.action = #selector(sizeFieldChanged); fontSizeField.setAccessibilityIdentifier("corral.settings.fontsize")
        fontSizeField.widthAnchor.constraint(equalToConstant: 26).isActive = true
        let unit = label("px", size: 11, color: CorralAestheticTokens.textSecondary)
        let stepper = inputBox(horizontal([fontSizeDecrementButton, fontSizeField, unit, fontSizeIncrementButton], spacing: 2), insets: NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2))
        stepper.setContentHuggingPriority(.required, for: .horizontal)
        let sizeRow = horizontal([fontSizeSlider, stepper], spacing: 20)
        let divider = NSView(); divider.wantsLayer = true; divider.layer?.backgroundColor = CorralAestheticTokens.border.cgColor
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let previewTitle = label("即时预览", size: 10, color: CorralAestheticTokens.previewCaption)
        previewSizeCaption.font = .systemFont(ofSize: 10); previewSizeCaption.textColor = CorralAestheticTokens.previewCaption
        let sample = NSTextField(labelWithString: ""); sample.lineBreakMode = .byTruncatingTail; fontPreviewLabel = sample
        let preview = vertical([horizontal([previewTitle, spacer(), previewSizeCaption]), sample], spacing: 8, insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
        preview.wantsLayer = true; preview.layer?.backgroundColor = CorralAestheticTokens.previewBackground.cgColor; preview.layer?.cornerRadius = 8
        preview.layer?.borderWidth = 1; preview.layer?.borderColor = CorralAestheticTokens.borderSubtle.cgColor
        preview.setAccessibilityIdentifier("corral.settings.preview")

        let typographyCard = card([fieldHeading("字体", hint: "使用本机已安装的字体"), vertical(presetRows, spacing: 7), customLabel, fontInput, divider, fieldHeading("字号", hint: "10–24 px"), sizeRow, preview],
                                  spacing: [10, 10, 6, 10, 10, 8, 10])

        let trackingTitle = label("目录跟踪", size: 13, weight: .semibold, color: CorralAestheticTokens.text)
        let trackingHint = label("切换 Agent 时，自动定位并展开左侧目录。", size: 11, color: CorralAestheticTokens.textSecondary)
        directoryTrackingSwitch.target = self; directoryTrackingSwitch.action = #selector(trackingChanged); directoryTrackingSwitch.setAccessibilityIdentifier("corral.settings.tracking")
        let trackingCard = card([horizontal([vertical([trackingTitle, trackingHint], spacing: 4), spacer(), directoryTrackingSwitch])])

        let body = vertical([section("界面外观", themeCard), section("终端外观", typographyCard), section("工作区行为", trackingCard)], spacing: 12)
        let top = vertical([header, body], spacing: 14, insets: NSEdgeInsets(top: 18, left: 24, bottom: 14, right: 24))

        let savedIcon = NSImageView(image: CorralLegacyIcon.image(.check, size: 12) ?? NSImage()); savedIcon.contentTintColor = CorralAestheticTokens.success
        let saved = horizontal([savedIcon, label("修改即时保存", size: 11, color: CorralAestheticTokens.textSecondary)], spacing: 6)
        let done = NSButton(title: "完成", target: self, action: #selector(close)); done.keyEquivalent = "\r"; done.setAccessibilityIdentifier("corral.settings.done")
        stylePrimary(done); pin(done, width: 76, height: 32)
        let footer = horizontal([saved, spacer(), done])
        footer.edgeInsets = NSEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
        let footerBorder = NSView(); footerBorder.wantsLayer = true; footerBorder.layer?.backgroundColor = CorralAestheticTokens.borderSubtle.cgColor
        footerBorder.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let content = vertical([top, footerBorder, footer], spacing: 0)
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: root.leadingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor), content.topAnchor.constraint(equalTo: root.topAnchor), content.widthAnchor.constraint(equalToConstant: Self.width)])
        root.setFrameSize(NSSize(width: Self.width, height: ceil(content.fittingSize.height)))
        view = root
        syncControls()
    }

    public func setTheme(_ theme: CorralThemeMode) { values.theme = theme; syncControls(); apply() }
    public func setFontFamily(_ family: String) { values.fontFamily = family; syncControls(); apply() }
    public func setFontSize(_ size: Double) { values.fontSize = min(24, max(10, size.rounded())); syncControls(); apply() }
    public func setDirectoryTracking(_ enabled: Bool) { values.directoryTracking = enabled; syncControls(); apply() }

    public static func primaryFamily(_ stack: String) -> String {
        (stack.split(separator: ",", maxSplits: 1).first.map(String.init) ?? stack).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
    public var selectedFontPreset: String? { Self.fontPresets.first { Self.primaryFamily($0).lowercased() == Self.primaryFamily(values.fontFamily).lowercased() } }

    @objc private func themeButtonPressed(_ sender: NSButton) { setTheme(CorralThemeMode(rawValue: sender.identifier?.rawValue ?? "") ?? .system) }
    @objc private func fontPresetPressed(_ sender: NSButton) { setFontFamily(sender.identifier?.rawValue ?? Self.fontPresets[0]) }
    @objc private func fontFieldCommitted() { let stack = fontFamilyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); if !stack.isEmpty { setFontFamily(stack) } }
    @objc private func sizeChanged() { setFontSize(fontSizeSlider.doubleValue) }
    @objc private func sizeFieldChanged() { setFontSize(Double(fontSizeField.stringValue) ?? values.fontSize) }
    @objc private func decrementSize() { setFontSize(values.fontSize - 1) }
    @objc private func incrementSize() { setFontSize(values.fontSize + 1) }
    @objc private func trackingChanged() { setDirectoryTracking(directoryTrackingSwitch.state == .on) }
    public override func handleEscape() { onClose?(); dismiss() }
    @objc private func close() { onClose?(); dismiss() }
    private func apply() { CorralAestheticTokens.themeMode = values.theme; onChange?(values) }

    private func syncControls() {
        for button in themeButtons {
            let active = button.identifier?.rawValue == values.theme.rawValue
            button.layer?.backgroundColor = active ? CorralAestheticTokens.surface3.cgColor : NSColor.clear.cgColor
            button.layer?.borderWidth = active ? 1 : 0; button.layer?.borderColor = CorralAestheticTokens.borderSubtle.cgColor
            let color = active ? CorralAestheticTokens.text : CorralAestheticTokens.textSecondary
            button.contentTintColor = color; button.state = active ? .on : .off; button.setAccessibilitySelected(active)
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 12.5, weight: active ? .semibold : .regular)])
        }
        let selectedPreset = selectedFontPreset
        for button in fontPresetButtons {
            let preset = button.identifier?.rawValue ?? ""
            let active = preset == selectedPreset
            button.state = active ? .on : .off; button.setAccessibilitySelected(active)
            button.layer?.backgroundColor = (active ? CorralAestheticTokens.choiceSelectedBackground : CorralAestheticTokens.fieldBackground).cgColor
            button.layer?.borderColor = (active ? CorralAestheticTokens.choiceSelectedBorder : CorralAestheticTokens.inputBorder).cgColor
            let font = NSFont(name: Self.primaryFamily(preset), size: 11).map { active ? NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) : $0 } ?? .monospacedSystemFont(ofSize: 11, weight: active ? .semibold : .regular)
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [.foregroundColor: active ? CorralAestheticTokens.choiceSelectedForeground : CorralAestheticTokens.text, .font: font])
        }
        if fontFamilyField.currentEditor() == nil { fontFamilyField.stringValue = values.fontFamily }
        fontSizeSlider.doubleValue = values.fontSize
        fontSizeField.stringValue = String(Int(values.fontSize))
        fontSizeDecrementButton.isEnabled = values.fontSize > 10; fontSizeIncrementButton.isEnabled = values.fontSize < 24
        previewSizeCaption.stringValue = "\(Int(values.fontSize)) px"
        directoryTrackingSwitch.state = values.directoryTracking ? .on : .off
        let previewFont = NSFont(name: Self.primaryFamily(values.fontFamily), size: CGFloat(values.fontSize)) ?? .monospacedSystemFont(ofSize: values.fontSize, weight: .regular)
        let sample = NSMutableAttributedString(string: "❯ ", attributes: [.foregroundColor: CorralAestheticTokens.success, .font: previewFont])
        sample.append(NSAttributedString(string: "Aa Bb 012345 · 清晰可见", attributes: [.foregroundColor: CorralAestheticTokens.previewForeground, .font: previewFont]))
        fontPreviewLabel?.attributedStringValue = sample
        fontPreviewLabel?.font = previewFont
    }

    // MARK: Layout helpers (`.settings-*` tokens)
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color; return field
    }
    private func spacer() -> NSView { let view = NSView(); view.setContentHuggingPriority(.init(1), for: .horizontal); return view }
    private func pin(_ view: NSView, width: CGFloat, height: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: width), view.heightAnchor.constraint(equalToConstant: height)])
    }
    private func horizontal(_ views: [NSView], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .centerY, distribution: NSStackView.Distribution = .fill) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.alignment = alignment; stack.spacing = spacing; stack.distribution = distribution; return stack
    }
    private func vertical(_ views: [NSView], spacing: CGFloat, insets: NSEdgeInsets = NSEdgeInsets()) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing; stack.edgeInsets = insets
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true }
        return stack
    }
    private func fieldHeading(_ title: String, hint: String) -> NSView {
        horizontal([label(title, size: 13, weight: .semibold, color: CorralAestheticTokens.text), spacer(), label(hint, size: 11, color: CorralAestheticTokens.textSecondary)])
    }
    private func section(_ title: String, _ card: NSView) -> NSView {
        let heading = label(title, size: 12, weight: .semibold, color: CorralAestheticTokens.textSecondary)
        let stack = vertical([heading, card], spacing: 9)
        return stack
    }
    private func card(_ rows: [NSView], spacing: [CGFloat] = []) -> NSView {
        let stack = NSStackView(views: rows); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        for (index, value) in spacing.enumerated() where index < rows.count - 1 { stack.setCustomSpacing(value, after: rows[index]) }
        stack.wantsLayer = true; stack.layer?.backgroundColor = CorralAestheticTokens.cardBackground.cgColor; stack.layer?.cornerRadius = 12
        stack.layer?.borderWidth = 1; stack.layer?.borderColor = CorralAestheticTokens.borderSubtle.cgColor
        stack.shadow = NSShadow(); stack.layer?.shadowColor = NSColor.black.cgColor; stack.layer?.shadowOpacity = 0.08; stack.layer?.shadowRadius = 1; stack.layer?.shadowOffset = NSSize(width: 0, height: -1)
        return stack
    }
    private func inputBox(_ content: NSView, insets: NSEdgeInsets) -> NSStackView {
        let box = NSStackView(views: [content]); box.orientation = .horizontal; box.edgeInsets = insets
        box.wantsLayer = true; box.layer?.backgroundColor = CorralAestheticTokens.fieldBackground.cgColor; box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1; box.layer?.borderColor = CorralAestheticTokens.inputBorder.cgColor
        return box
    }
}

@MainActor
public final class ToastView: NSView {
    public enum Kind: String, Sendable { case info, success, warning, error }
    public let messageLabel = NSTextField(labelWithString: "")
    public init(message: String, kind: Kind = .info) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 44)); wantsLayer = true; layer?.cornerRadius = 8; layer?.backgroundColor = CorralAestheticTokens.surface2.cgColor; layer?.borderColor = CorralAestheticTokens.border.cgColor; layer?.borderWidth = 1
        let color: NSColor = switch kind { case .info: CorralAestheticTokens.text; case .success: CorralAestheticTokens.success; case .warning: CorralAestheticTokens.warning; case .error: CorralAestheticTokens.danger }
        messageLabel.stringValue = message; messageLabel.textColor = color; messageLabel.font = .systemFont(ofSize: 12); messageLabel.lineBreakMode = .byTruncatingTail; messageLabel.translatesAutoresizingMaskIntoConstraints = false; addSubview(messageLabel)
        NSLayoutConstraint.activate([messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    public required init?(coder: NSCoder) { nil }
}

@MainActor
public final class ToastManager {
    public static let shared = ToastManager()
    public private(set) var currentToast: ToastView?
    private var dismissal: DispatchWorkItem?
    public var duration: TimeInterval = 2.5
    private init() {}
    public func show(_ message: String, kind: ToastView.Kind = .info, in host: NSView? = nil) {
        dismissal?.cancel(); currentToast?.removeFromSuperview()
        let toast = ToastView(message: message, kind: kind); currentToast = toast
        if let host {
            toast.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(toast)
            NSLayoutConstraint.activate([toast.centerXAnchor.constraint(equalTo: host.centerXAnchor), toast.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -22), toast.widthAnchor.constraint(greaterThanOrEqualToConstant: 280), toast.widthAnchor.constraint(lessThanOrEqualToConstant: 420), toast.heightAnchor.constraint(equalToConstant: 44)])
        }
        let work = DispatchWorkItem { [weak self, weak toast] in toast?.removeFromSuperview(); if self?.currentToast === toast { self?.currentToast = nil } }
        dismissal = work; DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
    public func dismissCurrent() { dismissal?.cancel(); currentToast?.removeFromSuperview(); currentToast = nil }
}

public struct CorralAddDeviceRequest: Equatable, Sendable {
    public let name: String
    public let url: String
    public let token: String
    public let candidates: [String]
    public let pairingHostID: String?
    public init(name: String, url: String, token: String, candidates: [String] = [], pairingHostID: String? = nil) { self.name = name; self.url = url; self.token = token; self.candidates = candidates; self.pairingHostID = pairingHostID }
}

private struct ImportedPairing: Decodable {
    let v: Int
    let host_id: String
    let token: String
}

@MainActor
public final class AddDeviceDialogViewController: CorralDialogViewController {
    public required init?(coder: NSCoder) { nil }
    public override var initialFirstResponder: NSView? { addressField }
    public let nameField = NSTextField()
    public let addressField = NSTextField()
    public let tokenField = NSSecureTextField()
    public private(set) var candidates: [String] = []
    private var pairingHostID: String?
    public private(set) var validationMessage: String?
    public var onSubmit: ((CorralAddDeviceRequest) -> Void)?
    public var onCancel: (() -> Void)?
    private let errorLabel = NSTextField(labelWithString: "")
    public init(onSubmit: ((CorralAddDeviceRequest) -> Void)? = nil, onCancel: (() -> Void)? = nil) { self.onSubmit = onSubmit; self.onCancel = onCancel; super.init() }
    public override func loadView() {
        let root = rootView(size: NSSize(width: 460, height: 430)); view = root
        _ = addHeader(to: root, title: "添加设备", subtitle: "填写 agentmirrord 打印的地址与配对 Token")
        _ = addLabel("显示名称（可选）", to: root, y: 86); nameField.placeholderString = "Mac Studio @ Home"; style(nameField); place(nameField, in: root, y: 107)
        _ = addLabel("WebSocket 地址", to: root, y: 147); addressField.placeholderString = "ws://192.168.31.116:9900/ws"; style(addressField); place(addressField, in: root, y: 168)
        _ = addLabel("配对 Token", to: root, y: 208); tokenField.placeholderString = "粘贴配对 Token"; style(tokenField); place(tokenField, in: root, y: 229)
        let hint = NSTextField(labelWithString: "粘贴配对二维码里的 JSON 可自动填充"); hint.font = .systemFont(ofSize: 10); hint.textColor = CorralAestheticTokens.textMuted; hint.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(hint); hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24).isActive = true; hint.topAnchor.constraint(equalTo: tokenField.bottomAnchor, constant: 8).isActive = true
        errorLabel.font = .systemFont(ofSize: 10); errorLabel.textColor = CorralAestheticTokens.danger; errorLabel.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(errorLabel); errorLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24).isActive = true; errorLabel.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 6).isActive = true
        let actions = addActionButtons(to: root, cancel: #selector(cancel), primary: #selector(submit), primaryTitle: "添加")
        let importButton = NSButton(title: "导入二维码", target: self, action: #selector(importQRCode))
        importButton.bezelStyle = .rounded; importButton.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(importButton)
        NSLayoutConstraint.activate([importButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), importButton.bottomAnchor.constraint(equalTo: actions.cancel.bottomAnchor)])
        root.registerForDraggedTypes([.string])
    }
    public override func handlePaste(_ text: String) -> Bool { acceptPairingJSON(text) }
    public func acceptPairingJSON(_ text: String) -> Bool {
        pairingHostID = nil
        guard let data = text.data(using: .utf8), let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        var url = payload["url"] as? String ?? ""
        var importedCandidates = payload["candidates"] as? [String] ?? []
        if payload["host_id"] != nil {
            guard let pairing = try? JSONDecoder().decode(ImportedPairing.self, from: data), pairing.v == 1, !pairing.token.isEmpty else { return false }
            if url.isEmpty { url = importedCandidates.first ?? "" }
            guard let primary = URL(string: url), let endpoint = try? ApprovedEndpoint(url: primary, pairingHostID: pairing.host_id) else { return false }
            importedCandidates = ([endpoint.url.absoluteString] + importedCandidates).compactMap { value in
                guard let url = URL(string: value) else { return nil }
                return try? ApprovedEndpoint(url: url, pairingHostID: pairing.host_id).url.absoluteString
            }
            pairingHostID = pairing.host_id
            url = endpoint.url.absoluteString
        }
        addressField.stringValue = url
        if let token = payload["token"] as? String { tokenField.stringValue = token }
        if let name = payload["name"] as? String { nameField.stringValue = name }
        candidates = importedCandidates
        validate(); return true
    }
    @objc public func submit() {
        validate(); guard validationMessage == nil else { errorLabel.stringValue = validationMessage ?? ""; return }
        let url = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultName = URL(string: url)?.host ?? url
        onSubmit?(CorralAddDeviceRequest(name: nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultName : nameField.stringValue, url: url, token: tokenField.stringValue, candidates: candidates, pairingHostID: candidates.contains(url) ? pairingHostID : nil))
    }
    public override func handleEscape() { onCancel?(); dismiss() }
    @objc private func cancel() { onCancel?(); dismiss() }
    @objc private func importQRCode() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.qr]
                try VNImageRequestHandler(url: url, options: [:]).perform([request])
                let payloads = Set((request.results ?? []).compactMap(\.payloadStringValue))
                guard payloads.count == 1, let text = payloads.first, acceptPairingJSON(text), pairingHostID != nil else {
                    throw EndpointSafetyError.invalidEndpoint
                }
                submit()
            } catch {
                errorLabel.stringValue = "无法导入，请选择有效的 Corral 配对二维码"
            }
        }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    private func validate() {
        let url = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        validationMessage = url.hasPrefix("ws://") || url.hasPrefix("wss://") ? nil : "地址必须以 ws:// 或 wss:// 开头"
        if isViewLoaded { errorLabel.stringValue = validationMessage ?? "" }
    }
    private func style(_ field: NSTextField) { field.font = .systemFont(ofSize: 12); field.textColor = CorralAestheticTokens.text; field.backgroundColor = CorralAestheticTokens.surface0; field.isBezeled = true; field.bezelStyle = .roundedBezel; field.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(field) }
    private func place(_ field: NSTextField, in root: NSView, y: CGFloat) { NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), field.topAnchor.constraint(equalTo: root.topAnchor, constant: y), field.heightAnchor.constraint(equalToConstant: 32)]) }
}

public struct CorralPairingPayload: Equatable, Sendable {
    public let url: String
    public let token: String
    public let name: String?
    public let candidates: [String]
    public let hostID: String?
    public let port: UInt16?
    public init(url: String, token: String = "", name: String? = nil, candidates: [String] = [], hostID: String? = nil, port: UInt16? = nil) { self.url = url; self.token = token; self.name = name; self.candidates = candidates; self.hostID = hostID; self.port = port }
}

@MainActor
public final class PairingDialogViewController: CorralDialogViewController {
    public required init?(coder: NSCoder) { nil }
    public override var initialFirstResponder: NSView? { payload.token.isEmpty ? tokenField : (isLoopback(payload.url) ? hostField : copyButton) }
    public let tokenField = NSSecureTextField()
    public let hostField = NSTextField()
    public override var canDismissWithEscape: Bool { true }
    public private(set) var qrImage: NSImage?
    public private(set) var pairingText: String?
    public var payload: CorralPairingPayload
    public var onCopied: ((String) -> Void)?
    public var onSaveToken: ((String) -> Void)?
    public var onCancel: (() -> Void)?
    private let imageView = NSImageView()
    private let copyButton = NSButton(title: "复制配对链接 / Token", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存二维码", target: nil, action: nil)
    /// Test-only presentation seam. The default path below remains the native
    /// NSSavePanel; tests inject only the user's response/selected URL so they
    /// can exercise the real export completion without driving the remote
    /// open-and-save-panel-service process.
    var savePanelPresenter: ((NSSavePanel, NSWindow?, (NSApplication.ModalResponse, URL?) -> Void) -> Void)?
    public init(payload: CorralPairingPayload, onCopied: ((String) -> Void)? = nil, onSaveToken: ((String) -> Void)? = nil, onCancel: (() -> Void)? = nil) { self.payload = payload; self.onCopied = onCopied; self.onSaveToken = onSaveToken; self.onCancel = onCancel; super.init() }
    public override func loadView() {
        let root = rootView(size: NSSize(width: 380, height: 570)); view = root
        _ = addHeader(to: root, title: "配对移动端", subtitle: "用手机扫描二维码，即可连接这台 Mac")
        tokenField.placeholderString = "粘贴 agentmirrord 配对 Token"; tokenField.isBezeled = true; tokenField.bezelStyle = .roundedBezel; tokenField.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(tokenField)
        hostField.placeholderString = "192.168.1.23，可用逗号分隔多个地址"; hostField.isBezeled = true; hostField.bezelStyle = .roundedBezel; hostField.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(hostField)
        let local = isLoopback(payload.url) && payload.hostID == nil
        tokenField.isHidden = !payload.token.isEmpty; hostField.isHidden = !local
        imageView.imageScaling = .scaleProportionallyUpOrDown; imageView.wantsLayer = true; imageView.layer?.backgroundColor = NSColor.white.cgColor; imageView.translatesAutoresizingMaskIntoConstraints = false; imageView.wantsLayer = true; imageView.layer?.cornerRadius = 10; root.addSubview(imageView)
        let help = NSTextField(labelWithString: payload.hostID.map { "主机 ID: \($0.prefix(8))…" } ?? "打开 Corral 移动端，选择扫码连接并对准此二维码"); help.font = .systemFont(ofSize: 10); help.textColor = CorralAestheticTokens.textMuted; help.alignment = .center; help.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(help)
        copyButton.target = self; copyButton.action = #selector(copyPairing); copyButton.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(copyButton)
        saveButton.target = self; saveButton.action = #selector(saveQRCode); saveButton.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(saveButton)
        let done = NSButton(title: "完成", target: self, action: #selector(cancel)); done.bezelStyle = .rounded; done.translatesAutoresizingMaskIntoConstraints = false; stylePrimary(done); root.addSubview(done)
        let credentialTop: NSLayoutYAxisAnchor = payload.token.isEmpty ? tokenField.bottomAnchor : root.topAnchor
        let qrTop: CGFloat = payload.token.isEmpty ? 18 : 88
        NSLayoutConstraint.activate([tokenField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), tokenField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), tokenField.topAnchor.constraint(equalTo: root.topAnchor, constant: 78), tokenField.heightAnchor.constraint(equalToConstant: 32), hostField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), hostField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), hostField.topAnchor.constraint(equalTo: root.topAnchor, constant: payload.token.isEmpty ? 118 : 78), hostField.heightAnchor.constraint(equalToConstant: 32), imageView.centerXAnchor.constraint(equalTo: root.centerXAnchor), imageView.topAnchor.constraint(equalTo: local ? hostField.bottomAnchor : credentialTop, constant: qrTop), imageView.widthAnchor.constraint(equalToConstant: 260), imageView.heightAnchor.constraint(equalToConstant: 260), help.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), help.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), help.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 10), copyButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), copyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22), done.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), done.bottomAnchor.constraint(equalTo: copyButton.bottomAnchor), done.widthAnchor.constraint(equalToConstant: 84), saveButton.leadingAnchor.constraint(equalTo: copyButton.trailingAnchor, constant: 8), saveButton.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -8), saveButton.bottomAnchor.constraint(equalTo: copyButton.bottomAnchor)])
        tokenField.target = self; tokenField.action = #selector(credentialsChanged); hostField.target = self; hostField.action = #selector(credentialsChanged)
        updateQR()
    }
    public func updateQR(token: String? = nil, hosts: String? = nil) {
        qrImage = nil; imageView.image = nil; pairingText = nil
        defer { saveButton.isEnabled = qrImage != nil }
        let actualToken = token ?? (payload.token.isEmpty ? tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : payload.token)
        let suppliedHosts = (hosts ?? hostField.stringValue).split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        let local = isLoopback(payload.url) && payload.hostID == nil
        guard !actualToken.isEmpty, !local || !suppliedHosts.isEmpty else { qrImage = nil; imageView.image = nil; pairingText = nil; return }
        let candidates = local ? suppliedHosts.map { reachableURL(host: $0, baseURL: payload.url) } : payload.candidates
        let url = candidates.first ?? payload.url
        var payloadObject: [String: Any] = ["v": 1, "url": url, "token": actualToken, "ts_authkey": "", "candidates": candidates]
        if let name = payload.name { payloadObject["name"] = name }
        if let hostID = payload.hostID { payloadObject["host_id"] = hostID }
        if let port = payload.port { payloadObject["port"] = Int(port) }
        guard let data = try? JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys]) else { qrImage = nil; imageView.image = nil; pairingText = nil; return }
        let text = String(data: data, encoding: .utf8) ?? ""
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage, let cg = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { return }
        qrImage = NSImage(cgImage: cg, size: NSSize(width: 224, height: 224)); imageView.image = qrImage; pairingText = text
    }
    @objc private func credentialsChanged() { updateQR() }
    @objc public func copyPairing() {
        guard let pairingText else { return }
        if payload.token.isEmpty { onSaveToken?(tokenField.stringValue) }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(pairingText, forType: .string); onCopied?("配对信息已复制")
    }
    @objc private func saveQRCode() {
        guard pairingText != nil, let cgImage = qrImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Corral-Pairing.png"
        let completion: (NSApplication.ModalResponse, URL?) -> Void = { [weak self] response, selectedURL in
            guard let self, response == .OK, let destination = selectedURL ?? panel.url else { return }
            do {
                let image = CIImage(cgImage: cgImage)
                let white = CIImage(color: .white).cropped(to: image.extent.insetBy(dx: -32, dy: -32))
                guard let png = CIContext().pngRepresentation(of: image.composited(over: white), format: .RGBA8,
                                                              colorSpace: CGColorSpaceCreateDeviceRGB()) else { return }
                let temporary = destination.deletingLastPathComponent().appendingPathComponent(".corral-qr-\(UUID().uuidString).tmp")
                let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
                guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
                try output.write(contentsOf: png)
                try output.synchronize()
                try output.close()
                guard Darwin.rename(temporary.path, destination.path) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                if payload.token.isEmpty { onSaveToken?(tokenField.stringValue) }
                ToastManager.shared.show("二维码已保存", kind: .success, in: view)
            } catch {
                ToastManager.shared.show("保存二维码失败", kind: .error, in: view)
            }
        }
        if let savePanelPresenter {
            savePanelPresenter(panel, view.window, completion)
        } else if let window = view.window {
            panel.beginSheetModal(for: window) { response in completion(response, panel.url) }
        } else {
            panel.begin { response in completion(response, panel.url) }
        }
    }
    public override func handleEscape() { onCancel?(); dismiss() }
    @objc private func cancel() { onCancel?(); dismiss() }
    private func isLoopback(_ value: String) -> Bool {
        guard let host = URLComponents(string: value)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost")
    }
    private func reachableURL(host: String, baseURL: String) -> String {
        guard var components = URLComponents(string: baseURL) else { return host }
        components.host = host; return components.string ?? host
    }
}

@MainActor
public final class CloseAgentDialogViewController: CorralDialogViewController {
    public required init?(coder: NSCoder) { nil }
    public let agentName: String
    public override var canDismissWithEscape: Bool { !isLoading }
    public var isLoading = false {
        didSet { confirmButton.isEnabled = !isLoading; confirmButton.title = isLoading ? "关闭中…" : "关闭 Agent"; cancelButton?.isEnabled = !isLoading }
    }
    public var onConfirm: (() -> Void)?
    public var onCancel: (() -> Void)?
    private lazy var confirmButton = CorralDialogButton(title: "关闭 Agent", kind: .danger, target: self, action: #selector(confirm))
    private weak var cancelButton: NSButton?
    public init(agentName: String, onConfirm: (() -> Void)? = nil, onCancel: (() -> Void)? = nil) { self.agentName = agentName; self.onConfirm = onConfirm; self.onCancel = onCancel; super.init() }
    // Mirrors `CloseAgentDialog.jsx`; the subtitle's 14pt margin collapses with the warning's 2pt top margin.
    public override func loadView() {
        let cancel = CorralDialogButton(title: "取消", kind: .plain, target: self, action: #selector(cancelAction)); cancelButton = cancel
        view = cardLayout([
            (chrLabel("关闭 Agent", size: 15, weight: .bold, color: CorralAestheticTokens.text), 2),
            (chrLabel("确定要关闭「\(agentName)」吗？", size: 12, color: CorralAestheticTokens.textMuted), 14),
            (chrLabel("这会终止当前 Agent 会话，未保存的工作可能会丢失。", size: 12, color: CorralAestheticTokens.textSecondary, lineHeight: 1.45), 18),
            (actionsRow([cancel, confirmButton]), 0)
        ])
    }
    public override func handleEscape() { guard !isLoading else { return }; onCancel?(); dismiss() }
    @objc private func cancelAction() { guard !isLoading else { return }; onCancel?(); dismiss() }
    public func confirmAction() { guard !isLoading else { return }; onConfirm?(); dismiss() }
    @objc private func confirm() { confirmAction() }
}
