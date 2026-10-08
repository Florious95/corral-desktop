import CorralContracts
import CryptoKit
import Foundation

public enum HostIdentityError: Error, Equatable, Sendable {
    case httpStatus(Int)
    /// The responder is not the paired host, or bound the proof to another address.
    case identityMismatch
    /// The proof does not verify under the pairing token: wrong token or an impostor.
    case proofRejected
    case unsupportedRoute
}

/// `/pair/whoami` and `/pair/identify`. Discovery and whoami are unauthenticated hints; a route is only
/// trusted once identify proves, by an HMAC over the pairing token, that this exact IPv4:port is the
/// paired host. The token itself never leaves the client here.
public struct HostIdentityProbe: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let transport: Transport
    private let codec = AgentMirrorHTTPCodec()

    public init(timeout: TimeInterval = 4) {
        transport = { request in
            var request = request
            request.timeoutInterval = timeout
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            let session = URLSession(configuration: configuration, delegate: RejectIdentityRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http)
        }
    }

    public init(transport: @escaping Transport) { self.transport = transport }

    public func whoami(host: String, port: Int, secure: Bool = false) async throws -> AgentMirrorWhoAmIResponse {
        let (data, response) = try await transport(URLRequest(url: try Self.url(host: host, port: port, secure: secure, path: "/pair/whoami")))
        guard response.statusCode == 200 else { throw HostIdentityError.httpStatus(response.statusCode) }
        let identity = try codec.decodeWhoAmIResponse(data)
        guard Self.isHostID(identity.hostID) else { throw HostIdentityError.identityMismatch }
        return identity
    }

    public func whoami(at endpoint: ApprovedEndpoint) async throws -> AgentMirrorWhoAmIResponse {
        try await whoami(host: endpoint.host, port: endpoint.port, secure: endpoint.scheme == "wss")
    }

    /// Proves `endpoint` reaches the host that owns `hostID` and `token`; throws otherwise.
    @discardableResult
    public func verify(_ endpoint: ApprovedEndpoint, hostID: String, token: String) async throws -> AgentMirrorIdentifyResponse {
        guard endpoint.route != .loopback, Self.isHostID(hostID), !token.isEmpty else { throw HostIdentityError.unsupportedRoute }
        let nonce = Self.makeNonce()
        let body = try codec.encodeIdentifyRequest(AgentMirrorIdentifyRequest(hostID: hostID, nonce: nonce, destinationIP: endpoint.host))
        var request = URLRequest(url: try Self.url(host: endpoint.host, port: endpoint.port, secure: endpoint.scheme == "wss", path: "/pair/identify"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await transport(request)
        guard response.statusCode == 200 else { throw HostIdentityError.httpStatus(response.statusCode) }
        let proof = try codec.decodeIdentifyResponse(data)
        guard proof.hostID == hostID, proof.bound == "\(endpoint.host):\(endpoint.port)" else { throw HostIdentityError.identityMismatch }
        let message = Self.identifyMessage(hostID: hostID, nonce: nonce, boundIP: endpoint.host, boundPort: endpoint.port)
        guard let mac = Data(hexString: proof.mac),
              HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: message, using: SymmetricKey(data: Data(token.utf8))) else {
            throw HostIdentityError.proofRejected
        }
        return proof
    }

    /// The frozen `agentmirror-identify-v1` vector, as the daemon's `IdentifyMAC`.
    public static func identifyMAC(token: String, hostID: String, nonce: String, boundIP: String, boundPort: Int) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: identifyMessage(hostID: hostID, nonce: nonce, boundIP: boundIP, boundPort: boundPort),
                                                    using: SymmetricKey(data: Data(token.utf8)))
        return code.map { String(format: "%02x", $0) }.joined()
    }

    public static func isHostID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{8,64}$", options: .regularExpression) != nil
    }

    private static func identifyMessage(hostID: String, nonce: String, boundIP: String, boundPort: Int) -> Data {
        Data("agentmirror-identify-v1\u{1F}\(hostID)\u{1F}\(nonce)\u{1F}\(boundIP)\u{1F}\(boundPort)".utf8)
    }

    private static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    private static func url(host: String, port: Int, secure: Bool, path: String) throws -> URL {
        var components = URLComponents()
        components.scheme = secure ? "https" : "http"
        components.host = host
        components.port = port
        components.path = path
        guard let url = components.url else { throw HostIdentityError.unsupportedRoute }
        return url
    }
}

private extension Data {
    init?(hexString: String) {
        let bytes = Array(hexString.utf8)
        guard bytes.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let byte = UInt8(String(decoding: bytes[index...index + 1], as: UTF8.self), radix: 16) else { return nil }
            data.append(byte)
        }
        self = data
    }
}

private final class RejectIdentityRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
