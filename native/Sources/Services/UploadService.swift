import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum UploadError: Error, Equatable, Sendable {
    case invalidURL
    case invalidRequest
    case invalidFile
    case unauthorized
    case unreachable
    case timeout
    case httpStatus(Int)
    case invalidResponse

    public var code: String {
        switch self {
        case .invalidURL: return "invalid_url"
        case .invalidRequest: return "invalid_request"
        case .invalidFile: return "invalid_file"
        case .unauthorized: return "unauthorized"
        case .unreachable: return "unreachable"
        case .timeout: return "timeout"
        case .httpStatus: return "http_status"
        case .invalidResponse: return "invalid_response"
        }
    }
}

public typealias UploadServiceError = UploadError

extension UploadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "invalid_url: upload URL is invalid"
        case .invalidRequest: return "invalid_request: upload request is invalid"
        case .invalidFile: return "invalid_file: upload bytes are empty"
        case .unauthorized: return "unauthorized: upload authentication failed"
        case .unreachable: return "unreachable: daemon unavailable"
        case .timeout: return "timeout: upload request timed out"
        case let .httpStatus(status): return "http_status: HTTP \(status)"
        case .invalidResponse: return "invalid_response: upload response is invalid"
        }
    }
}

public struct UploadResult: Codable, Equatable, Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }
}

/// The narrow async boundary used by UploadService. Production delegates to
/// URLSession; tests can inspect requests without opening a network socket.
public protocol URLSessionClient: Sendable {
    func upload(for request: URLRequest, from body: Data) async throws -> (Data, URLResponse)
}

public typealias URLSessionProtocol = URLSessionClient

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never forward a bearer credential to a redirected origin. Cancelling
        // all redirects also keeps same-origin behavior deterministic.
        completionHandler(nil)
    }
}

/// URLSession-backed client with no shared cookies or credential storage.
public final class URLSessionUploadClient: URLSessionClient, @unchecked Sendable {
    private let session: URLSession
    private let delegate: NoRedirectDelegate

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        self.delegate = NoRedirectDelegate()
        self.session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    public func upload(for request: URLRequest, from body: Data) async throws -> (Data, URLResponse) {
        try await session.upload(for: request, from: body)
    }
}

public struct UploadService: Sendable {
    private let client: any URLSessionClient

    public init(client: any URLSessionClient = URLSessionUploadClient()) {
        self.client = client
    }

    public init(session: any URLSessionClient) {
        self.client = session
    }

    /// Upload bytes to the supplied `/upload` endpoint and return the daemon's
    /// normalized absolute path. The token is only put into the Authorization
    /// header and is never retained in an error value or logged.
    public func upload(
        url: URL,
        token: String,
        filename: String,
        mime: String,
        bytes: Data
    ) async throws -> String {
        guard isHTTPURL(url) else { throw UploadError.invalidURL }
        guard !token.isEmpty, !Self.containsHeaderBreak(token) else {
            throw UploadError.invalidRequest
        }
        guard !bytes.isEmpty else { throw UploadError.invalidFile }

        let boundary = "AgentMirrorBoundary-\(UUID().uuidString)"
        let body = try Self.makeMultipartBody(
            filename: filename,
            mime: mime,
            bytes: bytes,
            boundary: boundary
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await client.upload(for: request, from: body)
        } catch let error as UploadError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw UploadError.timeout
        } catch {
            // Do not preserve URLSession's error text: it can contain request
            // details, and callers only need the stable public classification.
            throw UploadError.unreachable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UploadError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw UploadError.unauthorized
            }
            throw UploadError.httpStatus(httpResponse.statusCode)
        }

        let result: UploadResult
        do {
            result = try JSONDecoder().decode(UploadResult.self, from: responseData)
        } catch {
            throw UploadError.invalidResponse
        }
        guard isAbsolutePath(result.path) else {
            throw UploadError.invalidResponse
        }
        return result.path
    }

    public func upload(
        url: String,
        token: String,
        filename: String,
        mime: String,
        bytes: Data
    ) async throws -> String {
        guard let url = URL(string: url) else { throw UploadError.invalidURL }
        return try await upload(url: url, token: token, filename: filename, mime: mime, bytes: bytes)
    }

    public func upload(
        to url: URL,
        token: String,
        filename: String,
        mime: String,
        bytes: Data
    ) async throws -> String {
        try await upload(url: url, token: token, filename: filename, mime: mime, bytes: bytes)
    }

    /// Kept public so multipart framing can be independently verified without
    /// coupling tests to URLSession internals.
    public static func makeMultipartBody(
        filename: String,
        mime: String,
        bytes: Data,
        boundary: String
    ) throws -> Data {
        guard !bytes.isEmpty else { throw UploadError.invalidFile }
        guard !boundary.isEmpty, !Self.containsHeaderBreak(boundary), !boundary.contains("\"") else {
            throw UploadError.invalidRequest
        }
        guard !mime.isEmpty, !Self.containsHeaderBreak(mime) else {
            throw UploadError.invalidRequest
        }

        let safeFilename = safeFilename(filename)
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(
            Data(
                "Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename)\"\r\n".utf8
            )
        )
        body.append(Data("Content-Type: \(mime)\r\n\r\n".utf8))
        body.append(bytes)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private static func safeFilename(_ filename: String) -> String {
        let basename = filename.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "image"
        let cleaned = basename.map { character in
            character.unicodeScalars.contains(where: { scalar in
                scalar.value == 0x0A || scalar.value == 0x0D || scalar.value == 0x22 || scalar.value == 0x5C
            }) ? "_" : character
        }
        return cleaned.isEmpty ? "image" : String(cleaned)
    }

    private func isHTTPURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              components.host != nil,
              components.user == nil,
              components.password == nil
        else { return false }
        return true
    }

    private static func containsHeaderBreak(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value == 0x0A || scalar.value == 0x0D || scalar.value == 0
        }
    }

    private func isAbsolutePath(_ path: String) -> Bool {
        !path.isEmpty && path.hasPrefix("/") && !Self.containsHeaderBreak(path)
    }
}
