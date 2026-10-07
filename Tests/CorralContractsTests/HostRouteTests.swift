import CorralContracts
import Foundation
import XCTest

final class HostRouteTests: XCTestCase {
    private let hostID = "host-route-01"

    func testRoutesAreClassifiedByAddressNotByHostIdentity() throws {
        XCTAssertEqual(try endpoint("100.64.0.1").route, .tailnet)
        XCTAssertEqual(try endpoint("100.127.255.254").route, .tailnet)
        XCTAssertEqual(try endpoint("192.168.31.116").route, .lan)
        XCTAssertEqual(try endpoint("10.0.2.2").route, .lan)
        XCTAssertEqual(try endpoint("172.16.4.9").route, .lan)
        XCTAssertEqual(try ApprovedEndpoint(host: "127.0.0.1", port: 9919).route, .loopback)
        XCTAssertEqual(try ApprovedEndpoint(host: "::1", port: 9919).route, .loopback)
    }

    func testDialOrderIsTailscaleThenLANThenLoopbackStableAndUnique() throws {
        let lanA = try endpoint("192.168.1.5"), lanB = try endpoint("10.0.0.7")
        let tailnet = try endpoint("100.100.1.1"), loopback = try ApprovedEndpoint(host: "127.0.0.1", port: 9931, pairingHostID: hostID)
        XCTAssertEqual(ApprovedEndpoint.dialOrder([loopback, lanA, tailnet, lanB, lanA]), [tailnet, lanA, lanB, loopback])
    }

    func testDeviceKeepsOnlyRoutesToItsOwnPairedHost() throws {
        let primary = try endpoint("192.168.1.5")
        let tailnet = try endpoint("100.100.1.1")
        let otherHost = try ApprovedEndpoint(host: "10.0.0.9", port: 9931, pairingHostID: "another-host-99")
        let loopback = try ApprovedEndpoint(host: "127.0.0.1", port: 9931, pairingHostID: hostID)
        let device = DeviceRecord(id: DeviceID("d"), name: "Studio", endpoint: primary, credential: CredentialHandle("c"),
                                  alternateEndpoints: [otherHost, loopback, primary, tailnet])
        XCTAssertEqual(device.alternateEndpoints, [tailnet], "Foreign, loopback and duplicate routes are never kept")
        XCTAssertEqual(device.endpoints, [tailnet, primary], "Tailscale is dialed before the LAN route it was paired over")

        let local = DeviceRecord(id: DeviceID("l"), name: "本机", endpoint: try ApprovedEndpoint(host: "127.0.0.1", port: 9919),
                                 credential: CredentialHandle("c"), alternateEndpoints: [tailnet])
        XCTAssertEqual(local.endpoints.map(\.route), [.loopback], "An unpaired loopback device has no other routes")
    }

    func testDeviceRecordDecodesStoresWrittenBeforeAlternateRoutes() throws {
        let legacy = #"{"id":"d","name":"Old","endpoint":{"scheme":"ws","host":"127.0.0.1","port":9919,"path":"/ws"},"credential":"c"}"#
        let device = try JSONDecoder().decode(DeviceRecord.self, from: Data(legacy.utf8))
        XCTAssertEqual(device.alternateEndpoints, [])
        let roundTrip = try JSONDecoder().decode(DeviceRecord.self, from: JSONEncoder().encode(device))
        XCTAssertEqual(roundTrip, device)
    }

    private func endpoint(_ host: String) throws -> ApprovedEndpoint {
        try ApprovedEndpoint(host: host, port: 9931, pairingHostID: hostID)
    }
}
