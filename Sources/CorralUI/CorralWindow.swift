import AppKit

@MainActor
public final class CorralWindow: NSWindow {
    public static let minimumContentSize = NSSize(width: 480, height: 360)
    /// The terminal owns its special paste chord; all other keys follow AppKit's responder chain.
    public var onTerminalKeyDown: ((NSEvent) -> Bool)?

    public override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onTerminalKeyDown?(event) == true { return }
        super.sendEvent(event)
    }

    public init(contentRect: NSRect = NSRect(x: 0, y: 0, width: 1400, height: 860), title: String = "Corral") {
        var boundedContentRect = contentRect.standardized
        boundedContentRect.size.width = max(boundedContentRect.width, Self.minimumContentSize.width)
        boundedContentRect.size.height = max(boundedContentRect.height, Self.minimumContentSize.height)
        super.init(
            contentRect: boundedContentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.title = title
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        // The Tab lane sits under the transparent titlebar. AppKit only carves NSControl frames out of
        // the WindowServer drag region there (not views returning mouseDownCanMoveWindow == false), so a
        // movable titlebar would move the window from any Tab. Blank title chrome moves it explicitly instead.
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        backgroundColor = CorralAestheticTokens.surface0
        minSize = Self.minimumContentSize
        contentMinSize = Self.minimumContentSize
    }

    public override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(Self.frameRespectingMinimumSize(frameRect), display: flag)
    }

    public override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        super.setFrame(Self.frameRespectingMinimumSize(frameRect), display: flag, animate: animateFlag)
    }

    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Prevent headless/lockscreen virtual display boundaries from shrinking the window below minimum or requested size.
        Self.frameRespectingMinimumSize(frameRect)
    }

    private static func frameRespectingMinimumSize(_ frame: NSRect) -> NSRect {
        var frame = frame.standardized
        frame.size.width = max(frame.size.width, minimumContentSize.width)
        frame.size.height = max(frame.size.height, minimumContentSize.height)
        return frame
    }

    public required init?(coder: NSCoder) {
        fatalError("CorralWindow is created programmatically")
    }

    /// Repositions native window controls; without an explicit inset their centers match the workspace header.
    public func positionTrafficLights(leftInset: CGFloat = 16, topInset: CGFloat? = nil) {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in buttons.enumerated() {
            guard let button = standardWindowButton(type), let parent = button.superview else { continue }
            let spacing = button.frame.width + 7
            let inset = topInset ?? (CorralWorkspaceView.headerHeight - button.frame.height) / 2
            let origin = NSPoint(
                x: leftInset + CGFloat(index) * spacing,
                y: parent.bounds.height - inset - button.frame.height
            )
            button.setFrameOrigin(origin)
        }
    }
}

// Keep collapsible workspace constraints from becoming the window's fitting-size constraints.
@MainActor
private final class CorralWindowContentHost: NSView {
    private weak var workspaceView: NSView?

    func host(_ view: NSView) {
        workspaceView = view
        view.autoresizingMask = []
        view.frame = bounds
        addSubview(view)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        workspaceView?.frame = bounds
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        workspaceView?.frame = bounds
    }
}

@MainActor
public final class CorralWindowController: NSWindowController, NSWindowDelegate {
    public private(set) var savedFrameBeforeZoom: NSRect?

    public init(workspaceView: CorralWorkspaceView, contentRect: NSRect = NSRect(x: 0, y: 0, width: 1400, height: 860)) {
        let window = CorralWindow(contentRect: contentRect)
        super.init(window: window)
        let contentHost = CorralWindowContentHost(frame: window.contentView?.bounds ?? .zero)
        contentHost.host(workspaceView)
        window.contentView = contentHost
        window.delegate = self
        window.center()
        window.positionTrafficLights()
    }

    public required init?(coder: NSCoder) {
        fatalError("CorralWindowController is created programmatically")
    }

    public func toggleZoom() {
        guard let window, let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        toggleZoom(to: visibleFrame)
    }

    /// Uses the target screen's usable frame, excluding the menu bar and Dock, and restores the exact original frame.
    public func toggleZoom(to visibleFrame: NSRect) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        if let originalFrame = savedFrameBeforeZoom {
            window.setFrame(originalFrame, display: true, animate: false)
            savedFrameBeforeZoom = nil
        } else {
            let targetFrame = visibleFrame.standardized
            guard targetFrame.width > 0, targetFrame.height > 0 else { return }
            savedFrameBeforeZoom = window.frame
            window.setFrame(targetFrame, display: true, animate: false)
        }
    }

    public func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: max(frameSize.width, CorralWindow.minimumContentSize.width),
            height: max(frameSize.height, CorralWindow.minimumContentSize.height)
        )
    }

    public func windowDidResize(_ notification: Notification) {
        (window as? CorralWindow)?.positionTrafficLights()
    }

    public func windowDidChangeScreen(_ notification: Notification) {
        (window as? CorralWindow)?.positionTrafficLights()
    }
}

extension NSWindow {
    /// Blank title-bar chrome moves the window; `performDrag` works although CorralWindow is not titlebar-movable.
    func moveFromTitleChrome(with event: NSEvent) {
        if event.clickCount == 2, let controller = windowController as? CorralWindowController {
            controller.toggleZoom()
        } else {
            performDrag(with: event)
        }
    }
}
