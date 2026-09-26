import Foundation

public enum EndpointSafetyError: Error, Equatable, Sendable {
    case productionEndpointForbidden
    case invalidEndpoint
}

/// The only network destination admitted by this development build: loopback port 9919.
/// Non-loopback hosts are treated as production endpoints and fail closed.
public struct ApprovedEndpoint: Codable, Hashable, Sendable {
    public static let productionPort = 9900
    public static let developmentPort = 9919
    private static let allowedHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    public let scheme: String
    public let host: String
    public let port: Int

    public init(scheme: String = "ws", host: String, port: Int) throws {
        let normalizedScheme = scheme.lowercased()
        let normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        guard !normalizedHost.isEmpty else { throw EndpointSafetyError.invalidEndpoint }
        guard port != Self.productionPort, Self.allowedHosts.contains(normalizedHost) else {
            throw EndpointSafetyError.productionEndpointForbidden
        }
        guard (normalizedScheme == "ws" || normalizedScheme == "wss"), (1...65_535).contains(port) else {
            throw EndpointSafetyError.invalidEndpoint
        }
        guard port == Self.developmentPort else { throw EndpointSafetyError.invalidEndpoint }

        self.scheme = normalizedScheme
        self.host = normalizedHost
        self.port = port
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
        try self.init(scheme: scheme, host: host, port: port)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        guard let value = components.url else { preconditionFailure("Validated endpoint must form a URL") }
        return value
    }

    private enum CodingKeys: String, CodingKey { case scheme, host, port }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            scheme: values.decode(String.self, forKey: .scheme),
            host: values.decode(String.self, forKey: .host),
            port: values.decode(Int.self, forKey: .port)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(scheme, forKey: .scheme)
        try values.encode(host, forKey: .host)
        try values.encode(port, forKey: .port)
    }
}

/// Opaque reference resolved by a platform credential store; the secret is not held here.
public struct CredentialHandle: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}
