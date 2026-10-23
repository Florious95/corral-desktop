import CorralContracts
import Foundation
import UniformTypeIdentifiers

public struct ConversationUploadFailure: Error, Equatable, Sendable {
    public let code: String
    public init(_ code: String) { self.code = code }
}

/// One paired-route multipart POST. File I/O/encoding runs off the UI actor; failures never become prompts.
public struct ConversationUploadClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public static let maximumFileBytes = 20 << 20
    private let transport: Transport
    public init() {
        transport = { request in
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil; config.connectionProxyDictionary = [:]; config.timeoutIntervalForResource = 60
            let session = URLSession(configuration: config, delegate: RejectConversationRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw ConversationUploadFailure("response") }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 16 << 10 else { throw ConversationUploadFailure("response_size") }
                data.append(byte)
            }
            return (data, response)
        }
    }
    public init(transport: @escaping Transport) { self.transport = transport }

    public static func request(data: Data, filename: String, route: ApprovedEndpoint, token: String, boundary: String = "corral-" + UUID().uuidString) throws -> URLRequest {
        guard !token.isEmpty, !data.isEmpty, data.count <= maximumFileBytes else { throw ConversationUploadFailure("file_size") }
        guard var components = URLComponents(url: route.url, resolvingAgainstBaseURL: false) else { throw ConversationUploadFailure("route") }
        components.scheme = route.scheme == "wss" ? "https" : "http"; components.path = "/upload"
        guard let url = components.url else { throw ConversationUploadFailure("route") }
        let cleanName = filename.unicodeScalars.prefix(120).map {
            CharacterSet.controlCharacters.contains($0) || $0 == "\"" || $0 == "\\" || $0 == "/" ? "_" : String($0)
        }.joined()
        let name = cleanName.isEmpty ? "attachment" : cleanName
        let mime = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8)
        body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    public func upload(file: URL, route: ApprovedEndpoint, token: String) async throws -> String {
        let request = try await Task.detached(priority: .userInitiated) {
            let access = file.startAccessingSecurityScopedResource()
            defer { if access { file.stopAccessingSecurityScopedResource() } }
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw ConversationUploadFailure("not_file") }
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            let bytes = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
            return try Self.request(data: bytes, filename: file.lastPathComponent, route: route, token: token)
        }.value
        try Task.checkCancellation()
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw ConversationUploadFailure("http_\(response.statusCode)") }
        guard data.count <= 16 << 10, let result = try? JSONDecoder().decode(Reply.self, from: data), Self.validPath(result.path) else {
            throw ConversationUploadFailure("invalid_path")
        }
        return result.path
    }
    private struct Reply: Decodable { let path: String }
    public static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 4096 && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    public static func fileReference(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
