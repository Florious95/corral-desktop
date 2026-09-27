import Foundation

public enum EndpointSafetyError: Error, Equatable, Sendable {
    case nonLoopbackEndpointForbidden
    case invalidEndpoint
}

/// A validated WebSocket URL restricted to loopback hosts and the canonical `/ws` path.
public struct ApprovedEndpoint: Codable, Hashable, Sendable {
    public static let developmentPort = 9919
    public static let webSocketPath = "/ws"
    private static let allowedHosts: Set<String> = ["127.0.0.1", "::1"]

    public let scheme: String
    public let host: String
    public let port: Int
    public let path: String
    private let validatedURL: URL

    public init(
        scheme: String = "ws",
        host: String,
        port: Int,
        path: String = Self.webSocketPath
    ) throws {
        let normalizedScheme = scheme.lowercased()
        let inputHost = host.lowercased()
        let normalizedHost: String
        if inputHost.hasPrefix("[") || inputHost.hasSuffix("]") {
            guard inputHost.hasPrefix("["), inputHost.hasSuffix("]"),
                  inputHost.dropFirst().dropLast().allSatisfy({ $0 != "[" && $0 != "]" }) else {
                throw EndpointSafetyError.invalidEndpoint
            }
            normalizedHost = String(inputHost.dropFirst().dropLast())
        } else {
            guard !inputHost.contains("[") && !inputHost.contains("]") else {
                throw EndpointSafetyError.invalidEndpoint
            }
            normalizedHost = inputHost
        }
        let canonicalHost = normalizedHost == "localhost" ? "127.0.0.1" : normalizedHost

        guard !canonicalHost.isEmpty else { throw EndpointSafetyError.invalidEndpoint }
        guard Self.allowedHosts.contains(canonicalHost) else {
            throw EndpointSafetyError.nonLoopbackEndpointForbidden
        }
        guard normalizedScheme == "ws" || normalizedScheme == "wss",
              (1...65_535).contains(port),
              path.isEmpty || path == Self.webSocketPath else {
            throw EndpointSafetyError.invalidEndpoint
        }

        let hostLiteral = canonicalHost.contains(":") ? "[\(canonicalHost)]" : canonicalHost
        guard let url = URL(string: "\(normalizedScheme)://\(hostLiteral):\(port)\(Self.webSocketPath)"),
              url.scheme == normalizedScheme, url.host == canonicalHost, url.port == port,
              url.path == Self.webSocketPath else {
            throw EndpointSafetyError.invalidEndpoint
        }

        self.scheme = normalizedScheme
        self.host = canonicalHost
        self.port = port
        self.path = Self.webSocketPath
        self.validatedURL = url
    }

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw EndpointSafetyError.invalidEndpoint
        }
        let scheme = components.scheme ?? ""
        let port = components.port ?? (scheme.lowercased() == "wss" ? 443 : 80)
        try self.init(scheme: scheme, host: host, port: port, path: components.percentEncodedPath)
    }

    public var url: URL { validatedURL }

    private enum CodingKeys: String, CodingKey { case scheme, host, port, path }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            scheme: values.decode(String.self, forKey: .scheme),
            host: values.decode(String.self, forKey: .host),
            port: values.decode(Int.self, forKey: .port),
            path: values.decodeIfPresent(String.self, forKey: .path) ?? ""
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(scheme, forKey: .scheme)
        try values.encode(host, forKey: .host)
        try values.encode(port, forKey: .port)
        try values.encode(path, forKey: .path)
    }
}

/// Opaque reference resolved by a platform credential store; the secret is not held here.
public struct CredentialHandle: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}
