import Foundation
import WebKit
import UniformTypeIdentifiers

public struct LocalContent {
    public static let entryURL = URL(string: "agentmirror://app/index.html")!
    private let root: URL
    public init(distURL: URL) throws {
        root = distURL.standardizedFileURL.resolvingSymlinksInPath()
        guard root.isFileURL,
              FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path) else { throw ShellError.unavailable }
    }
    public static func isEntry(_ url: URL?) -> Bool {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        components.fragment = nil
        return components.url == entryURL
    }
    public func file(for url: URL) throws -> URL {
        guard url.scheme == "agentmirror", url.host == "app", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil else { throw ShellError.invalidRequest }
        let file = root.appendingPathComponent(url.path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/"), !url.path.contains("\0") else { throw ShellError.invalidRequest }
        let info = try file.resourceValues(forKeys: [.isRegularFileKey])
        guard info.isRegularFile == true else { throw ShellError.invalidRequest }
        return file
    }
}

/// Only immutable bundled resources. Never routes HTTP, uploads, or arbitrary file URLs.
@MainActor
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {
    let content: LocalContent
    init(content: LocalContent) { self.content = content }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        do {
            guard let url = urlSchemeTask.request.url, urlSchemeTask.request.httpMethod == "GET" else { throw ShellError.invalidRequest }
            let file = try content.file(for: url)
            let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
            let mime: String
            switch file.pathExtension.lowercased() {
            case "js", "mjs": mime = "text/javascript"
            case "css": mime = "text/css"
            default: mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            }
            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: bytes.count, textEncodingName: "utf-8"))
            urlSchemeTask.didReceive(bytes)
            urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(ShellError.unavailable) }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
