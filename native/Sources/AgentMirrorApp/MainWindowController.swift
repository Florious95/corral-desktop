import AppKit

@MainActor
final class MainWindowController: NSWindowController {
    private static let defaultFrame = NSRect(x: 0, y: 0, width: 1400, height: 860)

    init(webRoot: URL) {
        let webViewHost = WebViewHost(webRoot: webRoot)
        let rootView = GlassWindowContentView(content: webViewHost)
        let window = NSWindow(
            contentRect: Self.defaultFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = rootView
        window.title = "AgentMirror"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1100, height: 700)
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

extension MainWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        true
    }
}

/// Native glass is constrained to the shell layer. The WebView remains the
/// content view so React/xterm keep their existing rendering and event model.
@MainActor
final class GlassWindowContentView: NSView {
    private let surface: NSView

    init(content: NSView) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: .zero)
            glass.style = .regular
            glass.cornerRadius = 0
            glass.contentView = content
            surface = glass
        } else {
            let vibrancy = NSVisualEffectView(frame: .zero)
            vibrancy.material = .underWindowBackground
            vibrancy.blendingMode = .behindWindow
            vibrancy.state = .active
            vibrancy.addSubview(content)
            surface = vibrancy
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
