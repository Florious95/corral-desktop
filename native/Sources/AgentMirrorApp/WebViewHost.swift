import AppKit
import WebKit

@MainActor
final class WebViewHost: NSView, WKNavigationDelegate {
    let webView: WKWebView
    private let webRoot: URL
    private let nativeRPC: NativeRPC

    init(webRoot: URL) {
        self.webRoot = webRoot.standardizedFileURL

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(
            BundleSchemeHandler(root: self.webRoot),
            forURLScheme: "agentmirror"
        )
        nativeRPC = NativeRPC()
        configuration.userContentController.addScriptMessageHandler(
            nativeRPC,
            contentWorld: .page,
            name: NativeRPC.handlerName
        )

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        loadIndex()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func loadIndex() {
        let index = webRoot.appendingPathComponent("index.html", isDirectory: false)
        guard FileManager.default.fileExists(atPath: index.path) else { return }

        // Keep file loading available for a focused compatibility probe, but
        // use the private scheme by default: file-origin module subresources
        // are rejected by current WebKit even with relative Vite assets.
        if ProcessInfo.processInfo.environment["AGENTMIRROR_WEB_LOAD_MODE"] == "file" {
            webView.loadFileURL(index, allowingReadAccessTo: webRoot)
        } else {
            webView.load(URLRequest(url: URL(string: "agentmirror://app/index.html")!))
        }
    }

    static func resolveWebRoot() -> URL? {
        let fileManager = FileManager.default
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("web", isDirectory: true),
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("dist", isDirectory: true),
        ].compactMap { $0 }

        return candidates.first {
            fileManager.fileExists(atPath: $0.appendingPathComponent("index.html").path)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              (url.scheme == "agentmirror" && url.host == "app" && isInsideWebRoot(url))
                || (url.isFileURL && isInsideWebRoot(url))
        else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("AgentMirror WebView loaded local index (%@)", webView.url?.absoluteString ?? "<unknown>")
        logPageHealth(label: "immediate")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.logPageHealth(label: "settled")
        }
    }

    private func logPageHealth(label: String) {
        webView.evaluateJavaScript(
            "JSON.stringify({ready:document.readyState,root:!!document.getElementById('root'),children:document.getElementById('root')?.children.length || 0})"
        ) { value, error in
            if let error {
                NSLog("AgentMirror WebView health probe (%@) failed: %@", label, error.localizedDescription)
            } else {
                NSLog("AgentMirror WebView health (%@): %@", label, String(describing: value))
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        NSLog("AgentMirror WebView navigation failed: %@", error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        NSLog("AgentMirror WebView provisional navigation failed: %@", error.localizedDescription)
    }

    private func isInsideWebRoot(_ url: URL) -> Bool {
        if url.scheme == "agentmirror" {
            return url.host == "app"
                && BundleSchemeHandler.fileURL(for: url, under: webRoot) != nil
        }
        let rootPath = webRoot.path.hasSuffix("/") ? webRoot.path : webRoot.path + "/"
        let path = url.standardizedFileURL.path
        return path == webRoot.path || path.hasPrefix(rootPath)
    }
}
