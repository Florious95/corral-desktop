@testable import CorralProtocol
import CorralContracts
import Foundation
import XCTest

/// One host, several routes: the link dials Tailscale first, falls over to LAN without waiting for a
/// dead route, and every reconnect races all routes again.
final class HostCentricRouteRaceTests: XCTestCase {
    private let hostID = "host-centric-01"

    func testPreferredRouteWinsAloneWithinItsHeadStart() async throws {
        let tailnet = RouteSocket(), lan = RouteSocket()
        let factory = RouteSocketFactory([tailnetURL: [tailnet], lanURL: [lan]])
        let link = makeLink(factory: factory, stagger: 5_000_000_000)
        let all = try routes()
        let connect = Task { try await link.connect(toAnyOf: all, deviceID: DeviceID("d"), credential: CredentialHandle("token")) }
        try await tailnet.waitForAuthentication()
        await tailnet.acceptAuthentication()
        _ = try await connect.value

        XCTAssertEqual(factory.dialed, [tailnetURL], "LAN must not be dialed while Tailscale answers inside its head start")
        let active = await link.activeEndpoint()
        XCTAssertEqual(active?.route, .tailnet)
        await link.disconnect()
    }

    func testDeadPreferredRouteHandsOverToLANImmediately() async throws {
        let tailnet = RouteSocket(), lan = RouteSocket()
        await tailnet.refuse()
        let factory = RouteSocketFactory([tailnetURL: [tailnet], lanURL: [lan]])
        // A head start far longer than the test: LAN may only start because Tailscale failed.
        let link = makeLink(factory: factory, stagger: 60_000_000_000)
        let all = try routes()
        let connect = Task { try await link.connect(toAnyOf: all, deviceID: DeviceID("d"), credential: CredentialHandle("token")) }
        try await lan.waitForAuthentication()
        await lan.acceptAuthentication()
        _ = try await connect.value

        XCTAssertEqual(factory.dialed, [tailnetURL, lanURL])
        let active = await link.activeEndpoint()
        XCTAssertEqual(active?.route, .lan)
        await link.disconnect()
    }

    func testSilentPreferredRouteIsOvertakenAfterHeadStartAndClosed() async throws {
        let tailnet = RouteSocket(), lan = RouteSocket()
        let factory = RouteSocketFactory([tailnetURL: [tailnet], lanURL: [lan]])
        let link = makeLink(factory: factory, stagger: 20_000_000)
        let all = try routes()
        let connect = Task { try await link.connect(toAnyOf: all, deviceID: DeviceID("d"), credential: CredentialHandle("token")) }
        try await tailnet.waitForAuthentication()
        try await lan.waitForAuthentication()
        await lan.acceptAuthentication()
        _ = try await connect.value

        let active = await link.activeEndpoint()
        XCTAssertEqual(active?.route, .lan)
        try await tailnet.waitForClose()
        await link.disconnect()
    }

    func testReconnectRacesEveryRouteAndRestoresSubscriptions() async throws {
        let firstTailnet = RouteSocket(), secondTailnet = RouteSocket(), lan = RouteSocket()
        await secondTailnet.refuse()
        let factory = RouteSocketFactory([tailnetURL: [firstTailnet, secondTailnet], lanURL: [lan]])
        let link = makeLink(factory: factory, stagger: 60_000_000_000)
        let events = try await link.eventStream()
        let all = try routes()
        let connect = Task { try await link.connect(toAnyOf: all, deviceID: DeviceID("d"), credential: CredentialHandle("token")) }
        try await firstTailnet.waitForAuthentication()
        await firstTailnet.acceptAuthentication()
        _ = try await connect.value
        let reference = try SessionReference("roaming-session")
        _ = try await link.send(.subscribe(reference: reference, size: GridSize(rows: 30, columns: 100)))

        // Tailscale drops (the route the session ran over); the link must fail over to LAN by itself.
        await firstTailnet.drop()
        try await lan.waitForAuthentication()
        await lan.acceptAuthentication()
        try await waitForReady(epoch: ConnectionEpoch(2), in: events)

        XCTAssertEqual(factory.dialed, [tailnetURL, tailnetURL, lanURL], "The reconnect re-dials the preferred route first")
        let active = await link.activeEndpoint()
        XCTAssertEqual(active?.route, .lan)
        let replayed = await lan.sent()
        XCTAssertTrue(replayed.contains { $0.contains("\"subscribe\"") && $0.contains("roaming-session") }, "Failover must restore the subscription")
        await link.disconnect()
    }

    func testUpdatedRoutesAreRacedOnTheNextReconnect() async throws {
        let lan = RouteSocket(), learnedTailnet = RouteSocket(), deadLAN = RouteSocket()
        await deadLAN.refuse()
        let factory = RouteSocketFactory([lanURL: [lan, deadLAN], tailnetURL: [learnedTailnet]])
        let link = makeLink(factory: factory, stagger: 60_000_000_000)
        let events = try await link.eventStream()
        let lanOnly = try ApprovedEndpoint(url: XCTUnwrap(URL(string: lanURL)), pairingHostID: hostID)
        let connect = Task { try await link.connect(toAnyOf: [lanOnly], deviceID: DeviceID("d"), credential: CredentialHandle("token")) }
        try await lan.waitForAuthentication()
        await lan.acceptAuthentication()
        _ = try await connect.value

        await link.updateRoutes(try routes())
        await lan.drop()
        try await learnedTailnet.waitForAuthentication()
        await learnedTailnet.acceptAuthentication()
        try await waitForReady(epoch: ConnectionEpoch(2), in: events)
        let active = await link.activeEndpoint()
        XCTAssertEqual(active?.route, .tailnet, "A route learned after connect must be raced by the next reconnect")
        await link.disconnect()
    }

    func testRejectionByOneRouteStaysRetryableButUnanimousRejectionIsUnauthorized() async throws {
        let tailnet = RouteSocket(), lan = RouteSocket()
        await tailnet.refuse()
        let factory = RouteSocketFactory([tailnetURL: [tailnet], lanURL: [lan]])
        let link = makeLink(factory: factory, stagger: 60_000_000_000)
        let all = try routes()
        let connect = Task { try await link.connect(toAnyOf: all, deviceID: DeviceID("d"), credential: CredentialHandle("stale")) }
        try await lan.waitForAuthentication(token: "stale")
        await lan.rejectAuthentication()
        do { _ = try await connect.value; XCTFail("No route authenticated") }
        catch { XCTAssertNotEqual(error as? SessionLinkFailure, .unauthorized, "An unreachable route keeps the failure retryable") }

        let only = RouteSocket()
        let single = makeLink(factory: RouteSocketFactory([lanURL: [only]]), stagger: 1_000_000)
        let lanRoute = try ApprovedEndpoint(url: XCTUnwrap(URL(string: lanURL)), pairingHostID: hostID)
        let rejected = Task { try await single.connect(toAnyOf: [lanRoute], deviceID: DeviceID("d"), credential: CredentialHandle("stale")) }
        try await only.waitForAuthentication(token: "stale")
        await only.rejectAuthentication()
        do { _ = try await rejected.value; XCTFail("The only route rejected the token") }
        catch { XCTAssertEqual(error as? SessionLinkFailure, .unauthorized) }
    }

    /// A route that silently stops carrying packets (Wi-Fi gone, no RST) never errors; the missing pong does.
    func testSilentlyDeadRouteIsDetectedByHeartbeatAndFailsOver() async throws {
        let tailnet = RouteSocket(), deadTailnet = RouteSocket(), lan = RouteSocket()
        await deadTailnet.refuse()
        let factory = RouteSocketFactory([tailnetURL: [tailnet, deadTailnet], lanURL: [lan]])
        var configuration = URLSessionSessionLink.Configuration()
        configuration.heartbeatIntervalNanoseconds = 20_000_000
        configuration.heartbeatTimeoutNanoseconds = 40_000_000
        configuration.initialReconnectDelayNanoseconds = 1_000_000
        configuration.maximumReconnectDelayNanoseconds = 10_000_000
        configuration.routeStaggerNanoseconds = 60_000_000_000
        configuration.routeVerifier = Self.proven
        let link = URLSessionSessionLink(configuration: configuration) { factory.make($0) }
        let events = try await link.eventStream()
        let all = try routes()
        let connect = Task { try await link.connect(toAnyOf: all, deviceID: DeviceID("d"), credential: CredentialHandle("token")) }
        try await tailnet.waitForAuthentication()
        await tailnet.acceptAuthentication()
        _ = try await connect.value
        await tailnet.stopAnsweringPings()

        try await lan.waitForAuthentication()
        await lan.acceptAuthentication()
        try await waitForReady(epoch: ConnectionEpoch(2), in: events)
        let active = await link.activeEndpoint()
        XCTAssertEqual(active?.route, .lan)
        try await tailnet.waitForClose()
        await link.disconnect()
    }

    /// identify gates the WebSocket: an address that cannot prove the host never sees a socket or the token.
    func testUnprovenRouteNeverReceivesTheToken() async throws {
        let lan = RouteSocket()
        let factory = RouteSocketFactory([lanURL: [lan]])
        let tailnet = tailnetURL
        let link = makeLink(factory: factory, stagger: 60_000_000_000) { route, _ in
            if route.url.absoluteString == tailnet { throw HostIdentityError.identityMismatch }
        }
        let all = try routes()
        let connect = Task { try await link.connect(toAnyOf: all, deviceID: DeviceID("d"), credential: CredentialHandle("token")) }
        try await lan.waitForAuthentication()
        await lan.acceptAuthentication()
        _ = try await connect.value
        XCTAssertEqual(factory.dialed, [lanURL], "The impostor route is never dialed, so it never sees the token")
        await link.disconnect()
    }

    func testEveryRouteRejectingTheProofIsUnauthorized() async throws {
        let factory = RouteSocketFactory([:])
        let link = makeLink(factory: factory, stagger: 1_000_000) { _, _ in throw SessionLinkFailure.unauthorized }
        do {
            _ = try await link.connect(toAnyOf: try routes(), deviceID: DeviceID("d"), credential: CredentialHandle("wrong"))
            XCTFail("No route proved the host under this token")
        } catch { XCTAssertEqual(error as? SessionLinkFailure, .unauthorized) }
        XCTAssertTrue(factory.dialed.isEmpty)
    }

    func testRoutesOfAnotherHostAreNeverAdopted() async throws {
        let first = RouteSocket(), second = RouteSocket()
        let factory = RouteSocketFactory([lanURL: [first, second]])
        let link = makeLink(factory: factory, stagger: 60_000_000_000)
        let events = try await link.eventStream()
        let lan = try ApprovedEndpoint(url: XCTUnwrap(URL(string: lanURL)), pairingHostID: hostID)
        let connect = Task { try await link.connect(toAnyOf: [lan], deviceID: DeviceID("d"), credential: CredentialHandle("token")) }
        try await first.waitForAuthentication()
        await first.acceptAuthentication()
        _ = try await connect.value

        // A late route update for a different host (another device's learnRoutes) is refused.
        await link.updateRoutes([try ApprovedEndpoint(host: "100.99.9.9", port: 9931, pairingHostID: "another-host-99")])
        await first.drop()
        try await second.waitForAuthentication()
        await second.acceptAuthentication()
        try await waitForReady(epoch: ConnectionEpoch(2), in: events)
        XCTAssertEqual(factory.dialed, [lanURL, lanURL])
        await link.disconnect()
    }

    func testRouteThatNeverAuthenticatesTimesOut() async throws {
        let silent = RouteSocket()
        var configuration = URLSessionSessionLink.Configuration()
        configuration.routeAttemptTimeoutNanoseconds = 30_000_000
        configuration.routeVerifier = Self.proven
        let link = URLSessionSessionLink(configuration: configuration) { _ in silent }
        let route = try ApprovedEndpoint(url: XCTUnwrap(URL(string: lanURL)), pairingHostID: hostID)
        do {
            _ = try await link.connect(toAnyOf: [route], deviceID: DeviceID("d"), credential: CredentialHandle("token"))
            XCTFail("A silent route must not hang the connect")
        } catch {
            guard case .transport = error as? SessionLinkFailure else { return XCTFail("Expected a transport timeout, got \(error)") }
        }
        try await silent.waitForClose()
    }

    // MARK: - Fixtures

    private let tailnetURL = "ws://100.88.1.2:9931/ws"
    private let lanURL = "ws://192.168.7.20:9931/ws"

    private func routes() throws -> [ApprovedEndpoint] {
        try [tailnetURL, lanURL].map { try ApprovedEndpoint(url: XCTUnwrap(URL(string: $0)), pairingHostID: hostID) }
    }

    /// Every fake route proves its host unless a test says otherwise.
    private static let proven: @Sendable (ApprovedEndpoint, String) async throws -> Void = { _, _ in }

    private func makeLink(factory: RouteSocketFactory, stagger: UInt64,
                          verifier: @escaping @Sendable (ApprovedEndpoint, String) async throws -> Void = HostCentricRouteRaceTests.proven) -> URLSessionSessionLink {
        var configuration = URLSessionSessionLink.Configuration()
        configuration.heartbeatIntervalNanoseconds = 60_000_000_000
        configuration.initialReconnectDelayNanoseconds = 1_000_000
        configuration.maximumReconnectDelayNanoseconds = 10_000_000
        configuration.routeStaggerNanoseconds = stagger
        configuration.routeVerifier = verifier
        return URLSessionSessionLink(configuration: configuration) { factory.make($0) }
    }

    private func waitForReady(epoch: ConnectionEpoch, in stream: any SessionEventStream) async throws {
        for _ in 0..<64 {
            guard let envelope = try await stream.next() else { break }
            if case let .connectionChanged(.authenticatedReady(ready)) = envelope.event, ready == epoch { return }
        }
        XCTFail("Did not reach authenticated-ready epoch \(epoch)")
    }
}

private actor RouteSocket: WebSocketConnection {
    private var incoming: [WebSocketMessage] = []
    private var receiver: CheckedContinuation<WebSocketMessage, Error>?
    private var failure: SessionLinkFailure?
    private var outgoing: [String] = []
    private var closed = false

    func start() async throws {}
    func send(_ message: WebSocketMessage) async throws {
        if let failure { throw failure }
        if case let .text(text) = message { outgoing.append(text) }
    }
    func receive() async throws -> WebSocketMessage {
        if !incoming.isEmpty { return incoming.removeFirst() }
        if let failure { throw failure }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    private var silentPings = false
    private var pendingPings: [CheckedContinuation<Void, Error>] = []
    func ping() async throws {
        guard silentPings else { return }
        try await withCheckedThrowingContinuation { pendingPings.append($0) }
    }
    func stopAnsweringPings() { silentPings = true }
    func close() async {
        closed = true; drop()
        pendingPings.forEach { $0.resume(throwing: SessionLinkFailure.disconnected) }; pendingPings = []
    }

    /// Connection refused: every operation fails at once.
    func refuse() { failure = .transport("connection refused") }
    func drop() {
        failure = failure ?? .disconnected
        receiver?.resume(throwing: failure!)
        receiver = nil
    }
    func acceptAuthentication() { deliver(#"{"v":1,"type":"auth_ack","payload":{"ok":true}}"#) }
    func rejectAuthentication() { deliver(#"{"v":1,"type":"auth_ack","payload":{"ok":false,"reason":"unauthorized"}}"#) }
    private func deliver(_ text: String) {
        if let receiver { self.receiver = nil; receiver.resume(returning: .text(text)) } else { incoming.append(.text(text)) }
    }
    func sent() -> [String] { outgoing }
    func isClosed() -> Bool { closed }

    nonisolated func waitForAuthentication(token: String = "token") async throws {
        for _ in 0..<400 {
            if await sent().contains(where: { $0.contains("\"auth\"") && $0.contains("\"\(token)\"") }) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Route never authenticated")
        throw SessionLinkFailure.disconnected
    }

    nonisolated func waitForClose() async throws {
        for _ in 0..<400 {
            if await isClosed() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("The losing route was never closed")
    }
}

private final class RouteSocketFactory: @unchecked Sendable {
    private var sockets: [String: [RouteSocket]]
    private let lock = NSLock()
    private var dialedURLs: [String] = []

    init(_ sockets: [String: [RouteSocket]]) { self.sockets = sockets }

    var dialed: [String] { lock.withLock { dialedURLs } }

    func make(_ url: URL) -> any WebSocketConnection {
        lock.withLock {
            dialedURLs.append(url.absoluteString)
            guard var queue = sockets[url.absoluteString], !queue.isEmpty else { preconditionFailure("Unexpected dial of \(url)") }
            let socket = queue.removeFirst()
            sockets[url.absoluteString] = queue
            return socket
        }
    }
}
