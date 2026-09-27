import AppKit

@MainActor
public final class CorralWindow: NSWindow {
    public static let minimumContentSize = NSSize(width: 1100, height: 700)

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

    private static func frameRespectingMinimumSize(_ frame: NSRect) -> NSRect {
        var frame = frame.standardized
        frame.size.width = max(frame.size.width, minimumContentSize.width)
        frame.size.height = max(frame.size.height, minimumContentSize.height)
        return frame
    }

    public required init?(coder: NSCoder) {
        fatalError("CorralWindow is created programmatically")
    }

    /// Repositions the native close, minimize, and zoom controls within the transparent title bar.
    public func positionTrafficLights(leftInset: CGFloat = 16, topInset: CGFloat = 14) {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in buttons.enumerated() {
            guard let button = standardWindowButton(type), let parent = button.superview else { continue }
            let spacing = button.frame.width + 7
            let origin = NSPoint(
                x: leftInset + CGFloat(index) * spacing,
                y: parent.bounds.height - topInset - button.frame.height
            )
            button.setFrameOrigin(origin)
        }
    }
}

@MainActor
public final class CorralWindowController: NSWindowController, NSWindowDelegate {
    public private(set) var savedFrameBeforeZoom: NSRect?

    public init(workspaceView: CorralWorkspaceView, contentRect: NSRect = NSRect(x: 0, y: 0, width: 1400, height: 860)) {
        let window = CorralWindow(contentRect: contentRect)
        super.init(window: window)
        window.contentView = workspaceView
        workspaceView.autoresizingMask = [.width, .height]
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

@MainActor
final class CorralWindowDragRegion: NSView {
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2, let controller = window.windowController as? CorralWindowController {
            controller.toggleZoom()
        } else {
            window.performDrag(with: event)
        }
    }
}
