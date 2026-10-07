import CorralContracts
@testable import CorralProtocol
import Foundation
import XCTest

final class HostIdentityProbeTests: XCTestCase {
    private let hostID = "AAAAAAAAAAAAAAAAAAAAAAAAAA"

    func testIdentifyMACMatchesTheDaemonFrozenVector() {
        // agentmirrord `TestIdentifyVectorAndBoundLocalAddr`.
        XCTAssertEqual(HostIdentityProbe.identifyMAC(token: "pairing-token", hostID: hostID, nonce: "00112233445566778899aabbccddeeff",
                                                     boundIP: "192.0.2.7", boundPort: 9900),
                       "94a249b0dd5103c27295dcef7d3699659a22ed07f90d8a3e8d33207c45d46e94")
    }

    func testVerifyAcceptsOnlyAProofBoundToThisRouteUnderThisToken() async throws {
        let route = try ApprovedEndpoint(host: "100.88.1.2", port: 9931, pairingHostID: hostID)
        let honest = IdentifyResponder(hostID: hostID, token: "right")
        let proof = try await HostIdentityProbe(transport: honest.transport).verify(route, hostID: hostID, token: "right")
        XCTAssertEqual(proof.bound, "100.88.1.2:9931")
        let request = try XCTUnwrap(honest.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://100.88.1.2:9931/pair/identify")
        XCTAssertFalse(String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("right"), "The token must never be sent to an unproven route")

        await assertRejects(IdentifyResponder(hostID: hostID, token: "other"), route, .proofRejected)
        await assertRejects(IdentifyResponder(hostID: hostID, token: "right", bound: "192.168.1.9:9931"), route, .identityMismatch)
        await assertRejects(IdentifyResponder(hostID: "BBBBBBBBBBBBBBBBBBBBBBBBBB", token: "right"), route, .identityMismatch)
        let loopback = try ApprovedEndpoint(host: "127.0.0.1", port: 9931, pairingHostID: hostID)
        await assertRejects(honest, loopback, .unsupportedRoute)
    }

    func testWhoAmIRejectsMalformedHostIdentity() async throws {
        let probe = HostIdentityProbe { request in
            XCTAssertEqual(request.url?.absoluteString, "http://192.168.1.4:9931/pair/whoami")
            let body = #"{"v":1,"host_id":"x","name":"n","port":9931,"addresses":[]}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await probe.whoami(host: "192.168.1.4", port: 9931); XCTFail("A short host_id is not a host identity") }
        catch { XCTAssertEqual(error as? HostIdentityError, .identityMismatch) }
    }

    private func assertRejects(_ responder: IdentifyResponder, _ route: ApprovedEndpoint, _ expected: HostIdentityError,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await HostIdentityProbe(transport: responder.transport).verify(route, hostID: hostID, token: "right")
            XCTFail("Proof must be rejected", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? HostIdentityError, expected, file: file, line: line)
        }
    }
}

/// Answers `/pair/identify` like the daemon, optionally lying about its identity or binding.
final class IdentifyResponder: @unchecked Sendable {
    private let hostID: String, token: String, bound: String?
    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    init(hostID: String, token: String, bound: String? = nil) { self.hostID = hostID; self.token = token; self.bound = bound }

    var requests: [URLRequest] { lock.withLock { recorded } }

    var transport: HostIdentityProbe.Transport {
        { [self] request in
            lock.withLock { recorded.append(request) }
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            let nonce = try XCTUnwrap(body["nonce"] as? String), destination = try XCTUnwrap(body["dest_ip"] as? String)
            let port = request.url?.port ?? 0
            let boundAddress = bound ?? "\(destination):\(port)"
            let (boundIP, boundPort) = (String(boundAddress.split(separator: ":")[0]), Int(boundAddress.split(separator: ":")[1]) ?? 0)
            let mac = HostIdentityProbe.identifyMAC(token: token, hostID: hostID, nonce: nonce, boundIP: boundIP, boundPort: boundPort)
            let response = #"{"v":1,"host_id":"\#(hostID)","name":"Studio","bound":"\#(boundAddress)","mac":"\#(mac)"}"#
            return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}
