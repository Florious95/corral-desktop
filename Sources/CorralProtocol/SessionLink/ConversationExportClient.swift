import CorralContracts
import Foundation

public struct ConversationExportFailure: Error, Equatable, Sendable {
    public let code: String
    public init(_ code: String) { self.code = code }
}

/// A bounded private download; the caller owns cleanup, and only saves after checking the captured session again.
public struct ConversationExportArtifact: Sendable {
    public let file: URL
    init(file: URL) { self.file = file }
    public func remove() { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    public func save(to destination: URL) throws {
        let manager = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".corral-export-" + UUID().uuidString)
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: file, to: staging)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else { try manager.moveItem(at: staging, to: destination) }
    }
}

/// One authenticated GET on the current approved route; no query token, redirect, retry, or HTML rendering.
public struct ConversationExportClient: Sendable {
    public static let maximumBytes = 64 << 20
    public init() {}

    public static func request(reference: SessionReference, sessionID: String, route: ApprovedEndpoint, token: String) throws -> URLRequest {
        guard !token.isEmpty, !sessionID.isEmpty, sessionID.utf8.count <= 128, !sessionID.hasPrefix("-"),
              sessionID != ".", sessionID != "..", !sessionID.contains("/"), !sessionID.contains("\\"),
              !sessionID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ConversationExportFailure("invalid_session")
        }
        var components = URLComponents()
        components.scheme = route.scheme == "wss" ? "https" : "http"
        components.host = route.host; components.port = route.port
        components.path = "/artifacts/\(sessionID)/export"
        components.queryItems = [URLQueryItem(name: "ref", value: reference.rawValue)]
        guard let url = components.url else { throw ConversationExportFailure("invalid_route") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"; request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        return request
    }

    public func download(reference: SessionReference, sessionID: String, route: ApprovedEndpoint, token: String) async throws -> ConversationExportArtifact {
        let request = try Self.request(reference: reference, sessionID: sessionID, route: route, token: token)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: RejectConversationRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("corral-export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("session.html")
        let artifact = ConversationExportArtifact(file: file)
        var complete = false
        defer { if !complete { artifact.remove() } }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw ConversationExportFailure("http_failed") }
        guard response.mimeType?.lowercased() == "text/html" else { throw ConversationExportFailure("unexpected_format") }
        guard response.expectedContentLength <= Self.maximumBytes else { throw ConversationExportFailure("too_large") }
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ConversationExportFailure("file_failed") }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var chunk = Data(); chunk.reserveCapacity(64 << 10)
        var count = 0
        for try await byte in bytes {
            count += 1
            guard count <= Self.maximumBytes else { throw ConversationExportFailure("too_large") }
            chunk.append(byte)
            if chunk.count == 64 << 10 {
                try Task.checkCancellation()
                try handle.write(contentsOf: chunk); chunk.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        guard count > 0 else { throw ConversationExportFailure("empty") }
        try handle.write(contentsOf: chunk)
        try handle.synchronize()
        complete = true
        return artifact
    }
}
