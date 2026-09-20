import AppKit
import WebKit

@MainActor
final class TitlebarDragSurfaceView: NSView {
    weak var dragSurface: DragSurfaceView?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let dragSurface,
              let superview,
              dragSurface.acceptsDrag(at: dragSurface.convert(point, from: superview)) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        dragSurface?.beginDrag(with: event)
    }
}

@MainActor
public final class MainWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    public let webView: WKWebView
    private let bridge: ShellBridge
    private let dragSurface = DragSurfaceView()
    private let titlebarDragSurface = TitlebarDragSurfaceView()
    private weak var titlebarContainer: NSView?
    private let chrome = GlassChrome()
    private var allowLoad = false
    private var disposed = false
    private var fullscreenTarget: Bool?
    public private(set) var acceptsMessages = false
    public var onLoadFailure: (() -> Void)?
    public var onLoadFinished: (() -> Void)?

    public init(distURL: URL, services: (any ShellServiceHandling)? = nil,
                websiteDataStore: WKWebsiteDataStore? = nil) throws {
        let content = try LocalContent(distURL: distURL)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = websiteDataStore ?? WKWebsiteDataStore.default()
        config.setURLSchemeHandler(LocalSchemeHandler(content: content), forURLScheme: "agentmirror")
        bridge = ShellBridge(services: services ?? DefaultShellServices.shared)
        config.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "native")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "AgentMirror"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.minSize = NSSize(width: 1100, height: 700)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        super.init(window: window)
        bridge.owner = self
        window.delegate = self
        webView.navigationDelegate = self
        let root = NSView(frame: .zero)
        root.autoresizingMask = [.width, .height]
        window.contentView = root
        for view in [chrome, webView, dragSurface] {
            view.frame = root.bounds
            view.autoresizingMask = [.width, .height]
            root.addSubview(view)
        }
        let titlebarContainer = keepTitlebarControlsAboveContent(root)
        installTitlebarDragSurface(in: root, titlebarContainer: titlebarContainer)
        alignTrafficLights()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    public var isFullscreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }
    public var geometryGeneration: Int { dragSurface.geometry.geometryGeneration }
    public var windowState: [String: Any] {
        [
            "fullscreen": isFullscreen,
            "minimized": window?.isMiniaturized ?? false,
            "geometryGeneration": geometryGeneration,
            "viewportCSS": ["width": dragSurface.bounds.width, "height": dragSurface.bounds.height],
            "devicePixelRatio": window?.backingScaleFactor ?? 1,
            "safeArea": ["top": 0, "left": 0, "right": 0, "bottom": 0],
        ]
    }

    public func reload() {
        guard !disposed else { return }
        acceptsMessages = false
        bridge.reset()
        dragSurface.geometry.reset()
        webView.stopLoading()
        allowLoad = true
        webView.load(URLRequest(url: LocalContent.entryURL))
    }

    public func dispose() {
        guard !disposed else { return }
        disposed = true
        acceptsMessages = false
        bridge.reset()
        bridge.owner = nil
        dragSurface.geometry.reset()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "native", contentWorld: .page)
        webView.configuration.userContentController.removeAllUserScripts()
    }

    public override func close() { dispose(); super.close() }
    public func windowWillClose(_ notification: Notification) { dispose() }

    public func setFullscreen(_ flag: Bool) throws {
        guard let window, !disposed else { throw ShellError.unavailable }
        if let fullscreenTarget {
            guard fullscreenTarget == flag else { throw ShellError.unavailable }
            return
        }
        guard flag != isFullscreen else { return }
        fullscreenTarget = flag
        dragSurface.geometry.invalidate()
        window.toggleFullScreen(nil)
    }

    func updateSurface(_ params: [String: Any]) throws -> [String: Any] {
        guard let window, fullscreenTarget == nil else { throw ShellError.unavailable }
        do {
            try dragSurface.geometry.update(params, bounds: dragSurface.bounds,
                                             backingScale: window.backingScaleFactor)
        } catch {
            // A malformed or stale report must not retain a clickable old hit map.
            // Do not emit window.state here: the frontend's geometry watcher would
            // answer that event with another surface.update and recurse forever.
            dragSurface.geometry.invalidate()
            throw error
        }
        return ["revision": dragSurface.geometry.revision,
                "geometryGeneration": dragSurface.geometry.geometryGeneration]
    }

    public func windowDidResize(_ notification: Notification) {
        alignTrafficLights()
        geometryChanged()
    }
    public func windowDidChangeScreen(_ notification: Notification) {
        alignTrafficLights()
        geometryChanged()
    }
    public func windowDidChangeBackingProperties(_ notification: Notification) {
        alignTrafficLights()
        geometryChanged()
    }
    public func windowWillEnterFullScreen(_ notification: Notification) { fullscreenTarget = true; geometryChanged() }
    public func windowWillExitFullScreen(_ notification: Notification) { fullscreenTarget = false; geometryChanged() }
    public func windowDidEnterFullScreen(_ notification: Notification) { fullscreenTarget = nil; geometryChanged() }
    public func windowDidExitFullScreen(_ notification: Notification) { fullscreenTarget = nil; geometryChanged() }
    public func windowDidFailToEnterFullScreen(_ window: NSWindow) { fullscreenTarget = nil; geometryChanged() }
    public func windowDidFailToExitFullScreen(_ window: NSWindow) { fullscreenTarget = nil; geometryChanged() }
    public func windowDidMiniaturize(_ notification: Notification) { geometryChanged() }
    public func windowDidDeminiaturize(_ notification: Notification) { geometryChanged() }

    @discardableResult
    private func keepTitlebarControlsAboveContent(_ contentView: NSView) -> NSView? {
        guard let frameView = contentView.superview,
              let closeButton = window?.standardWindowButton(.closeButton) else { return nil }

        var ancestor = closeButton.superview
        while let candidate = ancestor, candidate.superview !== frameView {
            ancestor = candidate.superview
        }
        guard let titlebarContainer = ancestor,
              titlebarContainer.superview === frameView,
              titlebarContainer !== contentView else { return nil }
        frameView.addSubview(contentView, positioned: .below, relativeTo: titlebarContainer)
        frameView.addSubview(titlebarContainer, positioned: .above, relativeTo: contentView)
        return titlebarContainer
    }

    private func alignTrafficLights() {
        guard let window else { return }
        updateTitlebarDragSurfaceFrame()
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for buttonType in buttons {
            guard let button = window.standardWindowButton(buttonType),
                  let titlebarView = button.superview else { continue }
            let frame = TrafficLightLayout.alignedFrame(buttonFrame: button.frame,
                                                         in: titlebarView.bounds)
            button.setFrameOrigin(frame.origin)
        }
    }

    private func installTitlebarDragSurface(in contentView: NSView, titlebarContainer: NSView?) {
        guard let titlebarContainer else { return }
        self.titlebarContainer = titlebarContainer
        titlebarDragSurface.dragSurface = dragSurface
        titlebarDragSurface.autoresizingMask = []
        // NSThemeFrame rejects arbitrary subviews on macOS 14. Keep the
        // overlay in our content hierarchy while the full-size content view
        // still lets it cover the native titlebar area.
        contentView.addSubview(titlebarDragSurface)
        updateTitlebarDragSurfaceFrame()
    }

    private func updateTitlebarDragSurfaceFrame() {
        guard let contentView = titlebarDragSurface.superview,
              let titlebarContainer else { return }
        titlebarDragSurface.frame = contentView.convert(titlebarContainer.bounds, from: titlebarContainer)
    }

    private func geometryChanged() {
        dragSurface.geometry.invalidate()
        bridge.emitWindowState()
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard !disposed,
              navigationAction.targetFrame?.isMainFrame == true,
              LocalContent.isEntry(navigationAction.request.url),
              allowLoad else {
            decisionHandler(.cancel)
            return
        }
        allowLoad = false
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        acceptsMessages = LocalContent.isEntry(webView.url) && !disposed
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onLoadFinished?() }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { loadFailed() }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { loadFailed() }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loadFailed() }

    private func loadFailed() {
        acceptsMessages = false
        dragSurface.geometry.reset()
        bridge.reset()
        onLoadFailure?()
    }
}
