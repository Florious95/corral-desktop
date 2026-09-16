import AppKit

/// N1 material slot. N2 replaces this solid chrome backing with system glass.
/// Layer order is material -> WKWebView -> sparse native drag hit targets.
@MainActor
public final class GlassChrome: NSView {
    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class DragSurfaceView: NSView {
    var geometry = SurfaceGeometry()
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard let window, geometry.isDraggable(local, bounds: bounds, backingScale: window.backingScaleFactor, flipped: isFlipped) else { return nil }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, let window, event.window === window,
              geometry.isDraggable(convert(event.locationInWindow, from: nil), bounds: bounds,
                                   backingScale: window.backingScaleFactor, flipped: isFlipped) else { return }
        // This is the original AppKit dispatch event, before any async boundary.
        window.performDrag(with: event)
    }
    override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize { geometry.invalidate() }
        super.setFrameSize(newSize)
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        geometry.invalidate()
    }
}
