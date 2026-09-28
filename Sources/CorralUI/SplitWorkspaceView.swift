import AppKit
import CorralContracts
import CorralServices

/// Pane chrome drawn over the shared Metal stage (legacy `terminal.css` §6.1): 6pt gaps, 8pt multi-pane cards,
/// the focused pane outline, hover close buttons, and draggable dividers. Frames come only from
/// `SplitLayout.project`, the same projection that places the Metal viewports, and the view has no constraints,
/// so panes can never size the window. Clicks inside the focused pane fall through to its terminal input.
@MainActor
public final class SplitWorkspaceView: NSView {
    public private(set) var root: WorkspaceLayoutNode?
    public private(set) var focusedSessionID: SessionID?
    public private(set) var projection = SplitLayout.Projection()
    public private(set) var closeButtons: [SessionID: NSButton] = [:]
    /// The hovered or dragged divider, highlighted with the accent line.
    public private(set) var activeDividerPath: String?
    public var splitterCount: Int { projection.dividers.count }
    /// Live layout while a divider is dragged; nil ends the preview without a change.
    public var onLayoutPreview: ((WorkspaceLayoutNode?) -> Void)?
    /// Committed once per gesture with a legacy resizer path ("root.first…") and a four-decimal ratio.
    public var onRatioChange: ((String, Double) -> Void)?
    public var onFocusPane: ((SessionID) -> Void)?
    /// Client-side pane close only; it never terminates the Agent.
    public var onClosePane: ((SessionID) -> Void)?

    private struct DividerDrag {
        let divider: SplitLayout.Divider
        let origin: CGPoint
        let bounds: CGRect
        var ratio: Double?
    }
    private var drag: DividerDrag?
    private var previewRoot: WorkspaceLayoutNode?
    private var hoveredPane: SessionID?
    private var dividerElements: [SplitDividerAccessibilityElement] = []

    public init(root: WorkspaceLayoutNode? = nil) {
        self.root = root
        super.init(frame: .zero)
        setAccessibilityRole(.splitGroup)
        setAccessibilityIdentifier("corral.split")
    }

    public required init?(coder: NSCoder) { fatalError("SplitWorkspaceView is created programmatically") }
    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public func update(root: WorkspaceLayoutNode?, focusedSessionID: SessionID?) {
        if root != self.root { endDrag(committing: false) }
        self.root = root
        self.focusedSessionID = focusedSessionID
        refresh()
    }

    public override func layout() {
        super.layout()
        if let drag, drag.bounds != bounds { endDrag(committing: false) }
        refresh()
    }

    private func refresh() {
        projection = SplitLayout.project(previewRoot ?? root, in: bounds)
        let closable = projection.panes.count > 1 ? projection.panes : []
        for id in closeButtons.keys where !closable.contains(where: { $0.sessionID == id }) {
            closeButtons.removeValue(forKey: id)?.removeFromSuperview()
        }
        for pane in closable {
            let button = closeButtons[pane.sessionID] ?? makeCloseButton(for: pane.sessionID)
            button.frame = CGRect(x: pane.frame.maxX - 28, y: pane.frame.minY + 6, width: 22, height: 22)
            button.alphaValue = pane.sessionID == hoveredPane ? 1 : 0
        }
        dividerElements = projection.dividers.map { SplitDividerAccessibilityElement(divider: $0, owner: self) }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func makeCloseButton(for sessionID: SessionID) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(closePane(_:)))
        button.isBordered = false
        button.image = CorralLegacyIcon.image(.close, size: 12)
        button.imagePosition = .imageOnly
        button.contentTintColor = CorralAestheticTokens.textMuted
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.toolTip = "关闭窗格"
        button.setAccessibilityLabel("关闭窗格")
        button.setAccessibilityIdentifier("corral.pane.close")
        addSubview(button)
        closeButtons[sessionID] = button
        return button
    }

    @objc private func closePane(_ sender: NSButton) {
        guard let id = closeButtons.first(where: { $0.value === sender })?.key else { return }
        onClosePane?(id)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard projection.panes.count > 1 else { return }
        CorralAestheticTokens.background.setFill()
        projection.dividers.forEach { $0.frame.fill() }
        for pane in projection.panes {
            let corners = NSBezierPath(rect: pane.frame)
            corners.append(NSBezierPath(roundedRect: pane.frame, xRadius: 8, yRadius: 8))
            corners.windingRule = .evenOdd
            CorralAestheticTokens.background.setFill()
            corners.fill()
            let outline = NSBezierPath(roundedRect: pane.frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.5, yRadius: 7.5)
            (pane.sessionID == focusedSessionID ? CorralAestheticTokens.paneActiveBorder : CorralAestheticTokens.borderSubtle).setStroke()
            outline.stroke()
        }
        // `.split-resizer::after`: a 2pt accent line centred in the 6pt gap on hover or drag.
        if let divider = projection.dividers.first(where: { $0.path == activeDividerPath }) {
            CorralAestheticTokens.accent.setFill()
            (divider.direction == .horizontal ? divider.frame.insetBy(dx: 2, dy: 0) : divider.frame.insetBy(dx: 0, dy: 2)).fill()
        }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let local = convert(point, from: superview)
        if let button = closeButtons.values.first(where: { $0.alphaValue > 0 && $0.frame.contains(local) }) { return button }
        if divider(at: local) != nil { return self }
        return nil
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let divider = divider(at: point) {
            drag = DividerDrag(divider: divider, origin: point, bounds: bounds)
            activeDividerPath = divider.path
            needsDisplay = true
        } else if let pane = pane(at: point), pane.sessionID != focusedSessionID {
            onFocusPane?(pane.sessionID)
        }
    }

    public override func mouseDragged(with event: NSEvent) { dragDivider(to: convert(event.locationInWindow, from: nil)) }

    public override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        dragDivider(to: convert(event.locationInWindow, from: nil))
        endDrag(committing: true)
    }

    private func dragDivider(to point: CGPoint) {
        guard var drag, let root else { return }
        let delta = drag.divider.direction == .horizontal ? point.x - drag.origin.x : point.y - drag.origin.y
        drag.ratio = SplitLayout.ratio(dragging: drag.divider, by: delta)
        self.drag = drag
        let preview = drag.ratio.flatMap { root.settingRatio($0, at: drag.divider.path) }
        guard preview != previewRoot else { return }
        previewRoot = preview
        refresh()
        onLayoutPreview?(preview)
    }

    private func endDrag(committing: Bool) {
        guard let drag else { return }
        self.drag = nil
        activeDividerPath = nil
        if committing, let ratio = drag.ratio, let committed = previewRoot {
            root = committed
            previewRoot = nil
            refresh()
            onRatioChange?(drag.divider.path, ratio)
        } else {
            let hadPreview = previewRoot != nil
            previewRoot = nil
            refresh()
            if hadPreview { onLayoutPreview?(nil) }
        }
    }

    /// Accessibility splitter value: the first child's extent in points.
    fileprivate func setFirstExtent(_ extent: CGFloat, of divider: SplitLayout.Divider) {
        guard drag == nil, let ratio = SplitLayout.ratio(dragging: divider, by: extent - divider.firstExtent),
              let updated = root?.settingRatio(ratio, at: divider.path) else { return }
        root = updated
        refresh()
        onRatioChange?(divider.path, ratio)
    }

    public override func resetCursorRects() {
        for divider in projection.dividers {
            addCursorRect(divider.frame, cursor: divider.direction == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    public override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    public override func mouseExited(with event: NSEvent) { hover(at: nil) }

    private func hover(at point: CGPoint?) {
        hoveredPane = point.flatMap { self.pane(at: $0)?.sessionID }
        for (id, button) in closeButtons {
            let underPointer = point.map(button.frame.contains) ?? false
            button.alphaValue = id == hoveredPane ? 1 : 0
            button.layer?.backgroundColor = underPointer ? CorralAestheticTokens.hover.cgColor : nil
            button.contentTintColor = underPointer ? CorralAestheticTokens.text : CorralAestheticTokens.textMuted
        }
        let dividerPath = point.flatMap { divider(at: $0)?.path }
        if drag == nil, dividerPath != activeDividerPath {
            activeDividerPath = dividerPath
            needsDisplay = true
        }
    }

    public override func accessibilityChildren() -> [Any]? { (super.accessibilityChildren() ?? []) + dividerElements }

    private func divider(at point: CGPoint) -> SplitLayout.Divider? { projection.dividers.first { $0.frame.contains(point) } }
    private func pane(at point: CGPoint) -> SplitLayout.Pane? { projection.panes.first { $0.frame.contains(point) } }
}

/// Exposes each divider as an AX splitter so headless automation can resize panes without synthesizing input.
@MainActor
private final class SplitDividerAccessibilityElement: NSAccessibilityElement {
    let divider: SplitLayout.Divider
    weak var owner: SplitWorkspaceView?

    init(divider: SplitLayout.Divider, owner: SplitWorkspaceView) {
        self.divider = divider
        self.owner = owner
        super.init()
        setAccessibilityRole(.splitter)
        setAccessibilityIdentifier("corral.split.divider")
        setAccessibilityOrientation(divider.direction == .horizontal ? .vertical : .horizontal)
        setAccessibilityParent(owner)
        setAccessibilityFrameInParentSpace(divider.frame)
    }

    override func accessibilityValue() -> Any? { NSNumber(value: Double(divider.firstExtent)) }
    override func setAccessibilityValue(_ value: Any?) {
        guard let value = value as? NSNumber else { return }
        owner?.setFirstExtent(CGFloat(value.doubleValue), of: divider)
    }
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool { true }
}
