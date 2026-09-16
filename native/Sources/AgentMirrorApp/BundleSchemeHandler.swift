import Foundation
import WebKit

/// Serve the bundled Vite output from a private app:// origin. WKWebView's
/// file origin blocks module subresources on current macOS, while a custom
/// read-only scheme keeps relative assets working without enabling universal
/// file access or starting a local HTTP server.
///
/// The A1 bundle is small enough for synchronous reads on the main actor. The
/// production shell should move large resources to an actor-safe async reader
/// once the RPC and cancellation contracts are in place.
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let fileURL = Self.fileURL(for: requestURL, under: root),
              FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL)
        else {
            urlSchemeTask.didFailWithError(Self.error(code: 404, description: "resource not found"))
            return
        }

        let response = URLResponse(
            url: requestURL,
            mimeType: Self.mimeType(for: fileURL),
            expectedContentLength: data.count,
            textEncodingName: Self.isText(fileURL) ? "utf-8" : nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Synchronous reads complete before WebKit can cancel this small A1
        // resource request. An async reader belongs to the production pass.
    }

    static func fileURL(for url: URL, under root: URL) -> URL? {
        let relative = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let resolvedRoot = root.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relative)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard candidate.path == resolvedRoot.path || candidate.path.hasPrefix(rootPath) else { return nil }
        return candidate
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": return "text/html"
        case "css": return "text/css"
        case "js", "mjs": return "text/javascript"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    private static func isText(_ url: URL) -> Bool {
        ["html", "css", "js", "mjs", "json", "svg"].contains(url.pathExtension.lowercased())
    }

    private static func error(code: Int, description: String) -> NSError {
        NSError(
            domain: "AgentMirror.BundleScheme",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}
