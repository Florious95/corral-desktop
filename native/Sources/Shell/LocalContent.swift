import Foundation
import WebKit

public struct LocalContent {
    public static let entryURL = URL(string: "agentmirror://app/index.html")!
    private static let maximumFileSize: Int64 = 128 * 1024 * 1024
    private let root: URL
    private let manifest: [String: URL]

    public init(distURL: URL) throws {
        let resolvedRoot = distURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard resolvedRoot.isFileURL,
              FileManager.default.fileExists(atPath: resolvedRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ShellError.unavailable
        }
        root = resolvedRoot
        manifest = Self.makeManifest(root: resolvedRoot)
        guard manifest["/index.html"] != nil else { throw ShellError.unavailable }
    }

    public static func isEntry(_ url: URL?) -> Bool {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        components.fragment = nil
        return components.url == entryURL
    }

    public func file(for url: URL) throws -> URL {
        guard let path = canonicalPath(for: url), let file = manifest[path] else {
            throw ShellError.invalidRequest
        }
        return file
    }

    /// Internal response plan used by the scheme handler and package tests. It
    /// contains metadata and a bounded file range, never a whole resource body.
    func responsePlan(for request: URLRequest) -> LocalResponsePlan {
        guard let url = request.url, validOrigin(url) else {
            return .error(statusCode: 400)
        }
        let method = (request.httpMethod ?? "GET").uppercased()
        guard method == "GET" || method == "HEAD" else {
            return .error(statusCode: 405, headers: ["Allow": "GET, HEAD"])
        }
        guard let path = canonicalPath(for: url) else {
            return .error(statusCode: 400)
        }
        guard let file = manifest[path] else {
            return .error(statusCode: 404)
        }
        let values: URLResourceValues
        do {
            values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            return .error(statusCode: 404)
        }
        guard values.isRegularFile == true, let size = values.fileSize.map(Int64.init), size >= 0 else {
            return .error(statusCode: 404)
        }
        guard size <= Self.maximumFileSize else {
            return .error(statusCode: 413)
        }

        let mime = Self.mimeType(for: file.pathExtension)
        var headers = [
            "Content-Type": mime.type,
            "Content-Length": String(size),
            "Accept-Ranges": "bytes",
            "Access-Control-Allow-Origin": "*",
            "X-Content-Type-Options": "nosniff",
        ]
        if let encoding = mime.encoding { headers["Content-Type"] = "\(mime.type); charset=\(encoding)" }
        guard let rangeHeader = Self.header(named: "Range", in: request) else {
            return LocalResponsePlan(statusCode: 200, headers: headers, file: file,
                                     range: size == 0 ? nil : 0..<size, bodyAllowed: method == "GET")
        }

        switch Self.parseRange(rangeHeader, size: size) {
        case .multi:
            // Multipart ranges are deliberately not implemented. Returning a
            // complete 200 response is the frozen, non-multipart policy.
            return LocalResponsePlan(statusCode: 200, headers: headers, file: file,
                                     range: size == 0 ? nil : 0..<size, bodyAllowed: method == "GET")
        case .malformed:
            return .error(statusCode: 400)
        case .unsatisfiable:
            return .error(statusCode: 416, headers: ["Content-Range": "bytes */\(size)"])
        case let .single(start, end):
            let length = end - start + 1
            headers["Content-Length"] = String(length)
            headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
            return LocalResponsePlan(statusCode: 206, headers: headers, file: file,
                                     range: start..<end + 1, bodyAllowed: method == "GET")
        }
    }

    private func validOrigin(_ url: URL) -> Bool {
        url.scheme == "agentmirror" && url.host == "app" && url.port == nil
            && url.user == nil && url.password == nil && url.query == nil
    }

    private func canonicalPath(for url: URL) -> String? {
        guard validOrigin(url), !url.path.contains("\0"),
              let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let decoded = urlComponents.percentEncodedPath.removingPercentEncoding,
              decoded.hasPrefix("/"), !decoded.contains("\0") else { return nil }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first == "",
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return "/" + components.dropFirst().joined(separator: "/")
    }

    private static func makeManifest(root: URL) -> [String: URL] {
        let allowed = Set(["html", "css", "js", "mjs", "json", "map", "wasm", "woff", "woff2", "ttf",
                           "svg", "png", "jpg", "jpeg", "webp", "ico", "gif", "avif"])
        var result: [String: URL] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return result }
        for case let candidate as URL in enumerator {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/"),
                  let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  allowed.contains(resolved.pathExtension.lowercased()) else { continue }
            let relative = String(resolved.path.dropFirst(root.path.count))
            guard relative.hasPrefix("/") else { continue }
            // Use the manifest key from the bundle entry, not from the resolved
            // target, so an in-bundle symlink cannot escape its declared path.
            let entryRelative = String(candidate.standardizedFileURL.path.dropFirst(root.path.count))
            guard entryRelative.hasPrefix("/"), !entryRelative.contains("/../") else { continue }
            result[entryRelative] = resolved
        }
        return result
    }

    private static func header(named name: String, in request: URLRequest) -> String? {
        request.allHTTPHeaderFields?.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func mimeType(for extensionName: String) -> (type: String, encoding: String?) {
        switch extensionName.lowercased() {
        case "html": return ("text/html", "utf-8")
        case "css": return ("text/css", "utf-8")
        case "js", "mjs": return ("text/javascript", "utf-8")
        case "json", "map": return ("application/json", "utf-8")
        case "wasm": return ("application/wasm", nil)
        case "woff": return ("font/woff", nil)
        case "woff2": return ("font/woff2", nil)
        case "ttf": return ("font/ttf", nil)
        case "svg": return ("image/svg+xml", "utf-8")
        case "png": return ("image/png", nil)
        case "jpg", "jpeg": return ("image/jpeg", nil)
        case "webp": return ("image/webp", nil)
        case "ico": return ("image/x-icon", nil)
        case "gif": return ("image/gif", nil)
        case "avif": return ("image/avif", nil)
        default: return ("application/octet-stream", nil)
        }
    }

    private enum RangeDecision {
        case multi, malformed, unsatisfiable, single(Int64, Int64)
    }

    private static func parseRange(_ value: String, size: Int64) -> RangeDecision {
        guard value.lowercased().hasPrefix("bytes=") else { return .malformed }
        let spec = value.dropFirst(6).trimmingCharacters(in: .whitespaces)
        if spec.contains(",") { return .multi }
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .malformed }
        let left = parts[0].trimmingCharacters(in: .whitespaces)
        let right = parts[1].trimmingCharacters(in: .whitespaces)
        guard !left.isEmpty || !right.isEmpty else { return .malformed }
        if left.isEmpty {
            guard right.allSatisfy(\.isNumber), let suffix = UInt64(right) else { return .malformed }
            guard suffix > 0, size > 0 else { return .unsatisfiable }
            let length = min(suffix, UInt64(size))
            return .single(size - Int64(length), size - 1)
        }
        guard left.allSatisfy(\.isNumber), let startValue = UInt64(left) else { return .malformed }
        guard size > 0, startValue < UInt64(size) else { return .unsatisfiable }
        let start = Int64(startValue)
        if right.isEmpty { return .single(start, size - 1) }
        guard right.allSatisfy(\.isNumber), let requestedEnd = UInt64(right) else { return .malformed }
        guard requestedEnd >= startValue else { return .unsatisfiable }
        return .single(start, Int64(min(requestedEnd, UInt64(size - 1))))
    }
}

struct LocalResponsePlan {
    let statusCode: Int
    let headers: [String: String]
    let file: URL?
    let range: Range<Int64>?
    let bodyAllowed: Bool

    static func error(statusCode: Int, headers: [String: String] = [:]) -> LocalResponsePlan {
        var merged = headers
        merged["Content-Length"] = "0"
        merged["X-Content-Type-Options"] = "nosniff"
        return LocalResponsePlan(statusCode: statusCode, headers: merged,
                                 file: nil, range: nil, bodyAllowed: false)
    }
}

/// Streams immutable bundled resources through the custom agentmirror origin.
@MainActor
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {
    private static let maximumActiveTransfers = 64
    private let content: LocalContent
    private var transfers: [ObjectIdentifier: Transfer] = [:]

    init(content: LocalContent) { self.content = content }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard transfers.count < Self.maximumActiveTransfers else {
            let response = HTTPURLResponse(
                url: urlSchemeTask.request.url ?? LocalContent.entryURL,
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "0"]
            )
            if let response {
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didFinish()
            } else {
                urlSchemeTask.didFailWithError(ShellError.unavailable)
            }
            return
        }
        let plan = content.responsePlan(for: urlSchemeTask.request)
        let transfer = Transfer(owner: self, task: urlSchemeTask, plan: plan)
        transfers[ObjectIdentifier(urlSchemeTask)] = transfer
        transfer.start()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard let transfer = transfers.removeValue(forKey: id) else { return }
        transfer.cancel()
    }

    private func remove(_ transfer: Transfer) {
        transfers.removeValue(forKey: transfer.id)
    }

    @MainActor
    private final class Transfer: @unchecked Sendable {
        weak var owner: LocalSchemeHandler?
        let task: any WKURLSchemeTask
        let plan: LocalResponsePlan
        let id: ObjectIdentifier
        private var readTask: Task<Void, Never>?
        private var cancelled = false
        private var finished = false

        init(owner: LocalSchemeHandler, task: any WKURLSchemeTask, plan: LocalResponsePlan) {
            self.owner = owner
            self.task = task
            self.plan = plan
            id = ObjectIdentifier(task)
        }

        func start() {
            guard !cancelled,
                  let response = HTTPURLResponse(
                    url: task.request.url ?? LocalContent.entryURL,
                    statusCode: plan.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: plan.headers
                  ) else {
                fail()
                return
            }
            task.didReceive(response)
            guard plan.bodyAllowed, let range = plan.range, !range.isEmpty else {
                finish()
                return
            }
            guard let file = plan.file else { fail(); return }
            let start = UInt64(range.lowerBound)
            let length = UInt64(range.count)
            readTask = Task.detached(priority: .userInitiated) { [weak self, file] in
                do {
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: start)
                    var remaining = length
                    while remaining > 0 {
                        try Task.checkCancellation()
                        let amount = Int(min(remaining, 64 * 1024))
                        guard let data = try handle.read(upToCount: amount), !data.isEmpty else {
                            throw ShellError.unavailable
                        }
                        remaining -= UInt64(data.count)
                        await self?.deliver(data)
                    }
                    try Task.checkCancellation()
                    await self?.finish()
                } catch is CancellationError {
                    // stop() owns cancellation and forbids late callbacks.
                } catch {
                    await self?.fail()
                }
            }
        }

        func cancel() {
            cancelled = true
            readTask?.cancel()
            readTask = nil
            owner = nil
        }

        func deliver(_ data: Data) {
            guard isActive else { return }
            task.didReceive(data)
        }

        func finish() {
            guard isActive, !finished else { return }
            finished = true
            owner?.remove(self)
            task.didFinish()
        }

        func fail() {
            guard isActive, !finished else { return }
            finished = true
            owner?.remove(self)
            task.didFailWithError(ShellError.unavailable)
        }

        private var isActive: Bool {
            !cancelled && !finished && owner?.transfers[id] === self
        }
    }
}
