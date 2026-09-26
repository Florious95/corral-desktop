import CorralContracts
import Foundation
import XCTest

final class ApprovedEndpointTests: XCTestCase {
    func testOnlyLoopbackDevelopmentPortIsApproved() throws {
        XCTAssertEqual(try ApprovedEndpoint(host: "localhost", port: 9919).port, 9919)
        XCTAssertEqual(try ApprovedEndpoint(host: "127.0.0.1", port: 9919).url.host, "127.0.0.1")
        XCTAssertEqual(try ApprovedEndpoint(host: "::1", port: 9919).port, 9919)

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

    func testURLInitializerRejectsProductionAndRemoteDestinations() throws {
        for rawURL in ["ws://127.0.0.1:9900", "wss://production.example:9919"] {
            let url = try XCTUnwrap(URL(string: rawURL))
            XCTAssertThrowsError(try ApprovedEndpoint(url: url)) {
                XCTAssertEqual($0 as? EndpointSafetyError, .productionEndpointForbidden)
            }
        }
    }

    func testDecodingCannotBypassTheEndpointFence() {
        let data = Data(#"{"scheme":"ws","host":"production.example","port":9919}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ApprovedEndpoint.self, from: data)) {
            XCTAssertEqual($0 as? EndpointSafetyError, .productionEndpointForbidden)
        }
    }

    func testDesignTokensExposeDarkSurfaceAndBadgeLimit() {
        XCTAssertEqual(DesignTokens.Color.surface0, 0x171B22)
        XCTAssertEqual(DesignTokens.multiDeviceBadgeMaximumWidthPixels, 64)
        XCTAssertEqual(ContractVersion.current, 0)
    }
}
