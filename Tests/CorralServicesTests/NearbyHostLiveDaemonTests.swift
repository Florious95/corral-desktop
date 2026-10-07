import CorralContracts
import CorralProtocol
import CorralServices
import Foundation
import XCTest

/// Opt-in, against a private agentmirrord only: real DNS-SD browse + resolve, real whoami, real identify.
/// Set CORRAL_NATIVE_LIVE_DISCOVERY_HOST_ID / _PORT / _TOKEN. Other daemons on the LAN are never resolved.
final class NearbyHostLiveDaemonTests: XCTestCase {
    func testPrivateDaemonIsBrowsedResolvedAndProvenOverTheRealNetwork() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let hostID = environment["CORRAL_NATIVE_LIVE_DISCOVERY_HOST_ID"],
              let port = environment["CORRAL_NATIVE_LIVE_DISCOVERY_PORT"].flatMap(Int.init),
              let token = environment["CORRAL_NATIVE_LIVE_DISCOVERY_TOKEN"] else { throw XCTSkip("No private daemon configured") }
        XCTAssertNotEqual(port, 9900, "Live discovery tests must never use the production port")

        let browse = Task { () -> NearbyHostSighting? in
            for await found in BonjourHostSource(onlyHostIDs: [hostID]).sightings() where found.port == port { return found }
            return nil
        }
        let timeout = Task { try await Task.sleep(for: .seconds(10)); browse.cancel() }
        let sighting = await browse.value
        timeout.cancel()
        let found = try XCTUnwrap(sighting, "DNS-SD must browse and resolve the private daemon")
        XCTAssertEqual(found.advertisedHostID, hostID)
        XCTAssertEqual(found.channel, .bonjour)

        let probe = HostIdentityProbe()
        let identity = try await probe.whoami(host: found.host, port: found.port)
        XCTAssertEqual(identity.hostID, hostID)
        XCTAssertTrue(identity.addresses.contains(found.host), "whoami lists the address Bonjour resolved")
        let host = NearbyHost(hostID: hostID, name: identity.name, port: Int(identity.port), addresses: identity.addresses, channels: [.bonjour])
        let lan = try XCTUnwrap(host.routes.first { $0.route == .lan })
        let proof = try await probe.verify(lan, hostID: hostID, token: token)
        XCTAssertEqual(proof.bound, "\(lan.host):\(port)")
        do {
            try await probe.verify(lan, hostID: hostID, token: token + "-wrong")
            XCTFail("A wrong token must not verify")
        } catch { XCTAssertEqual(error as? HostIdentityError, .proofRejected) }

        // The real link races every route of the host (Tailscale first) and authenticates on one of them.
        let link = URLSessionSessionLink()
        let started = Date()
        let connection = try await link.connect(toAnyOf: host.routes, deviceID: DeviceID("live-discovery"), credential: CredentialHandle(token))
        let active = await link.activeEndpoint()
        XCTAssertEqual(connection.deviceID, DeviceID("live-discovery"))
        XCTAssertNotNil(active)
        print("LIVE-LINK active=\(active?.url.absoluteString ?? "nil") route=\(String(describing: active?.route)) after=\(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        await link.disconnect()
        print("LIVE-DISCOVERY host=\(identity.name) id=\(hostID) resolved=\(found.host):\(found.port) routes=\(host.routes.map(\.url.absoluteString)) proof=\(proof.bound)")
    }
}
