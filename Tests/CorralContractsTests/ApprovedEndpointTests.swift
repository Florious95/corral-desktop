import CorralContracts
import Foundation
import XCTest

final class ApprovedEndpointTests: XCTestCase {
    func testLoopbackEndpointsAllowAnyValidPortAtTheWebSocketPath() throws {
        for port in [9919, 9900, 8080] {
            XCTAssertEqual(
                try ApprovedEndpoint(host: "127.0.0.1", port: port).url.absoluteString,
                "ws://127.0.0.1:\(port)/ws"
            )
        }
        XCTAssertEqual(try ApprovedEndpoint(host: "localhost", port: 9919).url.absoluteString, "ws://127.0.0.1:9919/ws")
        XCTAssertEqual(try ApprovedEndpoint(host: "::1", port: 9919).url.absoluteString, "ws://[::1]:9919/ws")
        XCTAssertEqual(try ApprovedEndpoint(host: "[::1]", port: 9919).url.host, "::1")
        XCTAssertThrowsError(try ApprovedEndpoint(host: "production.example", port: 9919)) {
            XCTAssertEqual($0 as? EndpointSafetyError, .nonLoopbackEndpointForbidden)
        }
        XCTAssertThrowsError(try ApprovedEndpoint(host: "localhost", port: 0)) {
            XCTAssertEqual($0 as? EndpointSafetyError, .invalidEndpoint)
        }
    }

    func testURLInitializerKeepsWsPathAndRejectsUnapprovedPaths() throws {
        for rawURL in [
            "ws://localhost:9919",
            "ws://127.0.0.1:9919/ws",
            "ws://[::1]:9919/ws",
            "ws://127.0.0.1:9900/ws"
        ] {
            let endpoint = try ApprovedEndpoint(url: XCTUnwrap(URL(string: rawURL)))
            XCTAssertEqual(endpoint.url.path, "/ws")
            let decoded = try JSONDecoder().decode(ApprovedEndpoint.self, from: JSONEncoder().encode(endpoint))
            XCTAssertEqual(decoded, endpoint)
            XCTAssertEqual(decoded.url.absoluteString, endpoint.url.absoluteString)
        }
        XCTAssertThrowsError(try ApprovedEndpoint(url: XCTUnwrap(URL(string: "ws://127.0.0.1:9919/not-ws")))) {
            XCTAssertEqual($0 as? EndpointSafetyError, .invalidEndpoint)
        }
        XCTAssertThrowsError(try ApprovedEndpoint(host: "[[::1]]", port: 9919)) {
            XCTAssertEqual($0 as? EndpointSafetyError, .invalidEndpoint)
        }
    }

    func testURLInitializerAllowsLoopback9900AndRejectsRemoteDestinations() throws {
        let localURL = try XCTUnwrap(URL(string: "ws://127.0.0.1:9900/ws"))
        XCTAssertEqual(try ApprovedEndpoint(url: localURL).url, localURL)
        let remoteURL = try XCTUnwrap(URL(string: "wss://production.example:9919/ws"))
        XCTAssertThrowsError(try ApprovedEndpoint(url: remoteURL)) {
            XCTAssertEqual($0 as? EndpointSafetyError, .nonLoopbackEndpointForbidden)
        }
    }

    func testLoopback9900EndpointEncodesAndDecodesNormally() throws {
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:9900/ws"))
        let endpoint = try ApprovedEndpoint(url: url)
        XCTAssertEqual(endpoint.url, url)
        let decoded = try JSONDecoder().decode(ApprovedEndpoint.self, from: JSONEncoder().encode(endpoint))
        XCTAssertEqual(decoded, endpoint)
    }

    func testDecodingCannotBypassTheEndpointFence() {
        let data = Data(#"{"scheme":"ws","host":"production.example","port":9919,"path":"/ws"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ApprovedEndpoint.self, from: data)) {
            XCTAssertEqual($0 as? EndpointSafetyError, .nonLoopbackEndpointForbidden)
        }
    }

    func testDesignTokensAndApiVersionAreExplicit() {
        XCTAssertEqual(DesignTokens.Color.surface0, 0x171B22)
        XCTAssertEqual(DesignTokens.multiDeviceBadgeMaximumWidthPixels, 64)
        XCTAssertEqual(ContractVersion.string, "0.1")
        XCTAssertEqual(ProtocolV1.version, 1)
    }
}
