import AppKit

/// Material slot shared by the native shell. macOS 26 uses system glass; older
/// systems and accessibility modes use a visible, opaque visual-effect fallback.
@MainActor
public final class GlassChrome: NSView {
    public private(set) var usesSystemGlass = false
    public private(set) var usesOpaqueFallback = false

    private let fallback = NSVisualEffectView()
    private let solidFallback = NSView()
    private var glassView: NSView?
    private var glassContainer: NSView?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        setupMaterial()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        accessibilityChanged()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }

    public override func layout() {
        super.layout()
        fallback.frame = bounds
        solidFallback.frame = bounds
        glassContainer?.frame = bounds
        glassView?.frame = bounds
    }

    private func setupMaterial() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        fallback.material = .sidebar
        fallback.blendingMode = .behindWindow
        fallback.state = .active
        fallback.autoresizingMask = [.width, .height]
        solidFallback.autoresizingMask = [.width, .height]
        solidFallback.wantsLayer = true
        addSubview(fallback)
        addSubview(solidFallback)

        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView(frame: bounds)
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = 0
            container.spacing = 0
            container.autoresizingMask = [.width, .height]
            glass.autoresizingMask = [.width, .height]
            container.contentView = glass
            addSubview(container)
            glassContainer = container
            glassView = glass
            usesSystemGlass = true
        }
    }

    @objc private func accessibilityChanged() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        usesOpaqueFallback = reduceTransparency || increaseContrast
        fallback.isHidden = usesOpaqueFallback
        glassContainer?.isHidden = !usesSystemGlass || usesOpaqueFallback
        solidFallback.isHidden = !usesOpaqueFallback
        solidFallback.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        solidFallback.layer?.borderColor = NSColor.separatorColor.cgColor
        solidFallback.layer?.borderWidth = usesOpaqueFallback ? 1 : 0
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        accessibilityChanged()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
public final class DragSurfaceView: NSView {
    var geometry = SurfaceGeometry()

    public override var isFlipped: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = superview != nil ? convert(point, from: superview) : point
        return acceptsDrag(at: localPoint) ? self : nil
    }

    func acceptsDrag(at point: NSPoint) -> Bool {
        guard let window else { return false }
        return geometry.isDraggable(point, bounds: bounds,
                                    backingScale: window.backingScaleFactor,
                                    flipped: isFlipped)
    }

    public override func mouseDown(with event: NSEvent) {
        beginDrag(with: event)
    }

    func beginDrag(with event: NSEvent) {
        guard event.type == .leftMouseDown,
              let window,
              event.window === window,
              acceptsDrag(at: convert(event.locationInWindow, from: nil)) else { return }
        // This is the original AppKit event, before any async boundary.
        window.performDrag(with: event)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize { geometry.invalidate() }
        super.setFrameSize(newSize)
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        geometry.invalidate()
    }
}
