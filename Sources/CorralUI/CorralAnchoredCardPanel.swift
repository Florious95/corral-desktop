import AppKit

@MainActor
public final class CorralAnchoredCardPanel: NSPanel {
    public static let cardWidth: CGFloat = 300
    public static let windowLeftInset: CGFloat = 10
    public static let anchorGap: CGFloat = 15
    public private(set) var lastDismissedAt: TimeInterval?

    public init(contentViewController: NSViewController, anchoredTo sourceView: NSView) {
        contentViewController.loadViewIfNeeded()
        let size = contentViewController.preferredContentSize
        super.init(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Self.cardWidth, height: size.height)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.contentViewController = contentViewController
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.transient, .moveToActiveSpace]
        updateContentSizeAndPosition(anchoredTo: sourceView)
    }

    public required init?(coder: NSCoder) {
        fatalError("CorralAnchoredCardPanel is created programmatically")
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public override func resignKey() {
        super.resignKey()
        lastDismissedAt = ProcessInfo.processInfo.systemUptime
        orderOut(nil)
    }

    public func updateContentSizeAndPosition(anchoredTo sourceView: NSView) {
        guard let window = sourceView.window else { return }
        contentViewController?.loadViewIfNeeded()
        let contentSize = contentViewController?.preferredContentSize ?? frame.size
        let sourceRect = window.convertToScreen(sourceView.convert(sourceView.bounds, to: nil))
        setFrame(
            Self.frame(contentSize: contentSize, sourceRectInScreen: sourceRect, windowFrame: window.frame,
                       visibleFrame: window.screen?.visibleFrame),
            display: false
        )
    }

    /// Anchored above the source; kept inside the screen's visible frame when the window sits near an edge.
    public static func frame(contentSize: NSSize, sourceRectInScreen: NSRect, windowFrame: NSRect, visibleFrame: NSRect? = nil) -> NSRect {
        var frame = NSRect(
            x: windowFrame.minX + windowLeftInset,
            y: sourceRectInScreen.maxY + anchorGap,
            width: cardWidth,
            height: contentSize.height
        )
        guard let visible = visibleFrame else { return frame }
        frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
        frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - frame.height - 8)
        return frame
    }
}
