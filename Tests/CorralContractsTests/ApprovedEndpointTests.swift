import CorralContracts
import Foundation
import XCTest

final class ApprovedEndpointTests: XCTestCase {
    func testOnlyLoopbackDevelopmentPortAndWebSocketPathAreApproved() throws {
        XCTAssertEqual(try ApprovedEndpoint(host: "localhost", port: 9919).url.absoluteString, "ws://127.0.0.1:9919/ws")
        XCTAssertEqual(try ApprovedEndpoint(host: "127.0.0.1", port: 9919).url.absoluteString, "ws://127.0.0.1:9919/ws")
        XCTAssertEqual(try ApprovedEndpoint(host: "::1", port: 9919).url.absoluteString, "ws://[::1]:9919/ws")
        XCTAssertEqual(try ApprovedEndpoint(host: "[::1]", port: 9919).url.host, "::1")

        XCTAssertThrowsError(try ApprovedEndpoint(host: "127.0.0.1", port: 9900)) {
            XCTAssertEqual($0 as? EndpointSafetyError, .productionEndpointForbidden)
        }
        XCTAssertThrowsError(try ApprovedEndpoint(host: "production.example", port: 9919)) {
            XCTAssertEqual($0 as? EndpointSafetyError, .productionEndpointForbidden)
        }
        XCTAssertThrowsError(try ApprovedEndpoint(host: "localhost", port: 9918)) {
            XCTAssertEqual($0 as? EndpointSafetyError, .invalidEndpoint)
        }
    }

    func testURLInitializerKeepsWsPathAndRejectsUnapprovedPaths() throws {
        for rawURL in ["ws://localhost:9919", "ws://127.0.0.1:9919/ws", "ws://[::1]:9919/ws"] {
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

    func testURLInitializerRejectsProductionAndRemoteDestinations() throws {
        for rawURL in ["ws://127.0.0.1:9900/ws", "wss://production.example:9919/ws"] {
            let url = try XCTUnwrap(URL(string: rawURL))
            XCTAssertThrowsError(try ApprovedEndpoint(url: url)) {
                XCTAssertEqual($0 as? EndpointSafetyError, .productionEndpointForbidden)
            }
        }
    }

    func testProductionLoopbackRequiresExplicitOptInAndCannotBePersisted() throws {
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:9900/ws"))
        let endpoint = try ApprovedEndpoint(url: url, allowingProduction: true)
        XCTAssertTrue(endpoint.isProductionEndpoint)
        XCTAssertEqual(endpoint.url, url)
        XCTAssertThrowsError(try ApprovedEndpoint(url: url)) {
            XCTAssertEqual($0 as? EndpointSafetyError, .productionEndpointForbidden)
        }
        XCTAssertThrowsError(try ApprovedEndpoint(
            url: XCTUnwrap(URL(string: "ws://production.example:9900/ws")),
            allowingProduction: true
        )) {
            XCTAssertEqual($0 as? EndpointSafetyError, .productionEndpointForbidden)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ApprovedEndpoint.self, from: JSONEncoder().encode(endpoint))) {
            XCTAssertEqual($0 as? EndpointSafetyError, .productionEndpointForbidden)
        }
    }

    func testDecodingCannotBypassTheEndpointFence() {
        let data = Data(#"{"scheme":"ws","host":"production.example","port":9919,"path":"/ws"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ApprovedEndpoint.self, from: data)) {
            XCTAssertEqual($0 as? EndpointSafetyError, .productionEndpointForbidden)
        }
    }

    func testDesignTokensAndApiVersionAreExplicit() {
        XCTAssertEqual(DesignTokens.Color.surface0, 0x171B22)
        XCTAssertEqual(DesignTokens.multiDeviceBadgeMaximumWidthPixels, 64)
        XCTAssertEqual(ContractVersion.string, "0.1")
        XCTAssertEqual(ProtocolV1.version, 1)
    }
}
