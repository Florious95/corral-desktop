import CorralContracts
import Foundation

/// `POST /conversation/history` over the route the WebSocket currently uses, with the pairing Bearer token.
/// No other URL, query token, redirect or retry is ever used; late results are checked by the caller.
public struct ConversationHistoryClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Initial ≤64 KiB, pages ≤128 KiB, body chunks ≤32 KiB; anything larger is not a valid response.
    public static let maximumResponseBytes = 128 << 10

    private let transport: Transport

    public init(timeout: TimeInterval = 15) {
        transport = { request in
            var request = request
            request.timeoutInterval = timeout
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            configuration.urlCache = nil
            configuration.httpMaximumConnectionsPerHost = 4
            let session = URLSession(configuration: configuration, delegate: RejectHistoryRedirects(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http)
        }
    }

    public init(transport: @escaping Transport) { self.transport = transport }

    public func fetch(_ request: ConversationHistoryRequest, route: ApprovedEndpoint, token: String) async throws -> ConversationHistoryPage {
        let body = try JSONEncoder().encode(request)
        guard body.count <= ConversationWire.historyRequestBytes, !token.isEmpty else { throw ConversationHistoryFailure("too_large") }
        var components = URLComponents()
        components.scheme = route.scheme == "wss" ? "https" : "http"
        components.host = route.host
        components.port = route.port
        components.path = "/conversation/history"
        guard let url = components.url else { throw ConversationHistoryFailure("source_unavailable") }
        var http = URLRequest(url: url)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        http.httpBody = body
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport(http) }
        catch is CancellationError { throw ConversationHistoryFailure("cancelled") }
        catch let error as URLError where error.code == .cancelled { throw ConversationHistoryFailure("cancelled") }
        catch let error as URLError where error.code == .timedOut { throw ConversationHistoryFailure("deadline") }
        catch { throw ConversationHistoryFailure("network") }
        guard data.count <= Self.maximumResponseBytes else { throw ConversationHistoryFailure("too_large") }
        guard response.statusCode == 200 else {
            let code = (try? JSONDecoder().decode(HistoryErrorBody.self, from: data))?.error
            throw ConversationHistoryFailure(code.flatMap { $0.isEmpty ? nil : $0 } ?? "http_\(response.statusCode)")
        }
        let page: ConversationHistoryPage
        do { page = try JSONDecoder().decode(ConversationHistoryPage.self, from: data) }
        catch { throw ConversationHistoryFailure("malformed") }
        guard page.requestID == request.requestID, page.viewID == request.viewID else { throw ConversationHistoryFailure("stale_view") }
        return page
    }
}

private struct HistoryErrorBody: Decodable { let error: String? }

private final class RejectHistoryRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
