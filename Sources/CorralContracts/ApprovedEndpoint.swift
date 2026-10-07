import Foundation

public enum EndpointSafetyError: Error, Equatable, Sendable {
    case nonLoopbackEndpointForbidden
    case invalidEndpoint
}

/// A canonical `/ws` endpoint. Remote private IPv4 hosts require explicit QR-pairing authorization.
public struct ApprovedEndpoint: Codable, Hashable, Sendable {
    public static let developmentPort = 9919
    public static let webSocketPath = "/ws"
    private static let allowedHosts: Set<String> = ["127.0.0.1", "::1"]

    public let scheme: String
    public let host: String
    public let port: Int
    public let path: String
    public let pairingHostID: String?
    private let validatedURL: URL

    public init(
        scheme: String = "ws",
        host: String,
        port: Int,
        path: String = Self.webSocketPath,
        pairingHostID: String? = nil
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
        if let pairingHostID {
            guard pairingHostID.range(of: "^[A-Za-z0-9_-]{8,64}$", options: .regularExpression) != nil else {
                throw EndpointSafetyError.invalidEndpoint
            }
        }
        guard Self.allowedHosts.contains(canonicalHost) || (pairingHostID != nil && Self.isPairingHost(canonicalHost)) else {
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
        self.pairingHostID = pairingHostID
        self.validatedURL = url
    }

    public init(url: URL, pairingHostID: String? = nil) throws {
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
        try self.init(scheme: scheme, host: host, port: port, path: components.percentEncodedPath, pairingHostID: pairingHostID)
    }

    public var url: URL { validatedURL }

    public func revalidated() throws -> Self {
        try Self(scheme: scheme, host: host, port: port, path: path, pairingHostID: pairingHostID)
    }

    /// The network channel this endpoint reaches its host through. A host is one identity with several
    /// routes; the route never identifies the host.
    public enum Route: Int, Comparable, Sendable {
        /// Tailscale CGNAT (100.64/10): direct peer-to-peer on the same Wi-Fi and it survives roaming.
        case tailnet
        /// RFC 1918 private network.
        case lan
        case loopback

        public static func < (lhs: Route, rhs: Route) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var route: Route { Self.route(forHost: host) ?? .loopback }

    /// Classifies a literal address; nil for names and public addresses, which are no route of ours.
    public static func route(forHost host: String) -> Route? {
        if host == "::1" || host == "localhost" { return .loopback }
        guard let bytes = ipv4Octets(host) else { return nil }
        if bytes[0] == 127 { return .loopback }
        if bytes[0] == 100 && (64...127).contains(bytes[1]) { return .tailnet }
        return isPairingHost(host) ? .lan : nil
    }

    /// Host-centric dial order: Tailscale, then LAN, then loopback; stable within a route and de-duplicated.
    public static func dialOrder(_ endpoints: [ApprovedEndpoint]) -> [ApprovedEndpoint] {
        var seen = Set<URL>()
        return endpoints.enumerated()
            .sorted { ($0.element.route, $0.offset) < ($1.element.route, $1.offset) }
            .map(\.element)
            .filter { seen.insert($0.url).inserted }
    }

    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let bytes = parts.compactMap { UInt8($0) }
        guard parts.count == 4, bytes.count == 4, zip(parts, bytes).allSatisfy({ String($0.1) == $0.0 }) else { return nil }
        return bytes
    }

    private static func isPairingHost(_ host: String) -> Bool {
        guard let bytes = ipv4Octets(host) else { return false }
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 100 && (64...127).contains(bytes[1]))
    }

    private enum CodingKeys: String, CodingKey { case scheme, host, port, path, pairingHostID }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            scheme: values.decode(String.self, forKey: .scheme),
            host: values.decode(String.self, forKey: .host),
            port: values.decode(Int.self, forKey: .port),
            path: values.decodeIfPresent(String.self, forKey: .path) ?? "",
            pairingHostID: values.decodeIfPresent(String.self, forKey: .pairingHostID)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(scheme, forKey: .scheme)
        try values.encode(host, forKey: .host)
        try values.encode(port, forKey: .port)
        try values.encode(path, forKey: .path)
        try values.encodeIfPresent(pairingHostID, forKey: .pairingHostID)
    }
}

/// Opaque reference resolved by a platform credential store; the secret is not held here.
public struct CredentialHandle: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Legacy marker retained for compatibility; it is not a token and does not bypass authentication.
public enum SessionLinkCredential {
    public static let localPeerAnonymous = CredentialHandle("corral-local-peer-anonymous")
}
