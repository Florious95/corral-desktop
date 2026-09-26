import AppKit

@MainActor
public final class CorralWindow: NSWindow {
    public init(contentRect: NSRect = NSRect(x: 0, y: 0, width: 1180, height: 760), title: String = "Corral") {
        super.init(
            contentRect: contentRect,
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
        minSize = NSSize(width: 720, height: 480)
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
public final class CorralWindowController: NSWindowController {
    public private(set) var savedFrameBeforeZoom: NSRect?

    public init(workspaceView: CorralWorkspaceView, contentRect: NSRect = NSRect(x: 0, y: 0, width: 1180, height: 760)) {
        let window = CorralWindow(contentRect: contentRect)
        super.init(window: window)
        window.contentView = workspaceView
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

    /// Uses the target screen's visible frame and remembers the exact pre-zoom window frame.
    public func toggleZoom(to visibleFrame: NSRect) {
        guard let window else { return }
        if let originalFrame = savedFrameBeforeZoom {
            window.setFrame(originalFrame, display: true, animate: false)
            savedFrameBeforeZoom = nil
        } else {
            savedFrameBeforeZoom = window.frame
            window.setFrame(visibleFrame, display: true, animate: false)
        }
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
