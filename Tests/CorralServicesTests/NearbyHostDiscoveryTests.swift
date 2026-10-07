import CorralContracts
import CorralProtocol
import CorralServices
import Foundation
import XCTest

@MainActor
final class NearbyHostDiscoveryTests: XCTestCase {
    func testSightingsFromBonjourAndTailscaleMergeIntoOneHostPerHostID() async throws {
        let whoami = WhoAmIResponder([
            "192.168.31.20": (hostID: "studio-host-0001", name: "Mac Studio", addresses: ["192.168.31.20", "100.101.2.3"]),
            "100.101.2.3": (hostID: "studio-host-0001", name: "Mac Studio", addresses: ["192.168.31.20", "100.101.2.3"]),
            "100.77.226.21": (hostID: "air-host-000002", name: "MacBook Air", addresses: ["100.77.226.21"]),
            "10.0.0.66": (hostID: "impostor-host-01", name: "Impostor", addresses: ["10.0.0.66"])
        ])
        let discovery = NearbyHostDiscovery(
            sources: [
                FixedSource([NearbyHostSighting(host: "192.168.31.20", port: 9900, advertisedHostID: "studio-host-0001", channel: .bonjour),
                             // DNS-SD says one host, whoami another: the sighting is not trusted.
                             NearbyHostSighting(host: "10.0.0.66", port: 9900, advertisedHostID: "studio-host-0001", channel: .bonjour),
                             // This Mac's own daemon is already the local device and is never probed.
                             NearbyHostSighting(host: "192.168.31.116", port: 9900, advertisedHostID: "self-host-00001", channel: .bonjour)]),
                FixedSource([NearbyHostSighting(host: "100.101.2.3", port: 9900, channel: .tailscale),
                             NearbyHostSighting(host: "100.77.226.21", port: 9900, channel: .tailscale)])
            ],
            probe: HostIdentityProbe(transport: whoami.transport),
            excludedAddresses: ["192.168.31.116"]
        )
        var updates = 0
        discovery.onUpdate = { _ in updates += 1 }
        discovery.start()
        for _ in 0..<200 where discovery.hosts.count < 2 || discovery.hosts.first?.channels.count != 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        discovery.stop()

        XCTAssertEqual(discovery.hosts.map(\.name), ["Mac Studio", "MacBook Air"])
        let studio = try XCTUnwrap(discovery.hosts.first)
        XCTAssertEqual(studio.channels, [.bonjour, .tailscale])
        XCTAssertEqual(studio.routes.map(\.url.absoluteString), ["ws://100.101.2.3:9900/ws", "ws://192.168.31.20:9900/ws"], "Tailscale first")
        XCTAssertEqual(studio.tailnetAddress, "100.101.2.3")
        XCTAssertEqual(studio.lanAddress, "192.168.31.20")
        XCTAssertFalse(whoami.queried.contains("192.168.31.116"), "This Mac's own daemon must not be probed")
        XCTAssertGreaterThan(updates, 0)
    }

    func testTailscaleStatusYieldsOnlineDesktopPeers() throws {
        let status = #"""
        {"Self":{"HostName":"this-mac","TailscaleIPs":["100.75.207.88"]},
         "Peer":{
          "a":{"HostName":"MacBook Air","OS":"macOS","Online":true,"TailscaleIPs":["100.77.226.21","fd7a:115c:a1e0::5638:e216"]},
          "b":{"HostName":"host82","OS":"linux","Online":true,"TailscaleIPs":["fd7a:115c:a1e0::d938:106c","100.96.16.107"]},
          "c":{"HostName":"pixel","OS":"android","Online":true,"TailscaleIPs":["100.69.43.120"]},
          "d":{"HostName":"old-mac","OS":"macOS","Online":false,"TailscaleIPs":["100.75.10.115"]}}}
        """#
        XCTAssertEqual(TailscalePeerSource.parsePeers(Data(status.utf8)),
                       [.init(name: "MacBook Air", address: "100.77.226.21"), .init(name: "host82", address: "100.96.16.107")])
        XCTAssertEqual(TailscalePeerSource.parsePeers(Data("not json".utf8)), [])
    }
}

private struct FixedSource: NearbyHostSource {
    let fixed: [NearbyHostSighting]
    init(_ sightings: [NearbyHostSighting]) { fixed = sightings }
    func sightings() -> AsyncStream<NearbyHostSighting> {
        AsyncStream { continuation in
            fixed.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

private final class WhoAmIResponder: @unchecked Sendable {
    typealias Identity = (hostID: String, name: String, addresses: [String])
    private let identities: [String: Identity]
    private let lock = NSLock()
    private var hosts: [String] = []

    init(_ identities: [String: Identity]) { self.identities = identities }
    var queried: [String] { lock.withLock { hosts } }

    var transport: HostIdentityProbe.Transport {
        { [self] request in
            let url = try XCTUnwrap(request.url), host = try XCTUnwrap(url.host)
            lock.withLock { hosts.append(host) }
            guard url.path == "/pair/whoami", let identity = identities[host] else { throw URLError(.cannotConnectToHost) }
            let list = identity.addresses.map { "\"\($0)\"" }.joined(separator: ",")
            let body = #"{"v":1,"host_id":"\#(identity.hostID)","name":"\#(identity.name)","port":9900,"addresses":[\#(list)]}"#
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}
