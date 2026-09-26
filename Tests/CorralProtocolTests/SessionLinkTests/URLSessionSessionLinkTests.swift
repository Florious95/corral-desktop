@testable import CorralProtocol
import CorralContracts
import Foundation
import XCTest

final class URLSessionSessionLinkTests: XCTestCase {
    func testReconnectIncrementsConnectionEpochAndUsesOnlyApprovedPort() async throws {
        var configuration = URLSessionSessionLink.Configuration()
        configuration.heartbeatIntervalNanoseconds = 60_000_000_000
        configuration.initialReconnectDelayNanoseconds = 1_000_000
        configuration.maximumReconnectDelayNanoseconds = 10_000_000
        let first = MockWebSocket()
        let second = MockWebSocket()
        let factory = MockWebSocketFactory(sockets: [first, second])
        let link = URLSessionSessionLink(configuration: configuration) { factory.make($0) }
        let events = await link.eventStream()
        let endpoint = try ApprovedEndpoint(host: "127.0.0.1", port: 9919)

        let connect = Task { try await link.connect(to: endpoint, credential: CredentialHandle("test")) }
        try await waitForAuthentication(on: first)
        await first.enqueue(.text(try authenticationAck()))
        try await connect.value
        let initialEpoch = try await waitForConnectedEpoch(in: events)
        XCTAssertEqual(initialEpoch, ConnectionEpoch(1))
        let sessionID = SessionID("session-a")
        try await link.send(.subscribe(sessionID: sessionID, initialSize: GridSize(rows: 24, columns: 80)))

        await first.fail()
        try await waitForAuthentication(on: second)
        await second.enqueue(.text(try authenticationAck()))
        let reconnectedEpoch = try await waitForConnectedEpoch(in: events)
        XCTAssertEqual(reconnectedEpoch, ConnectionEpoch(2))
        XCTAssertEqual(factory.createdURLs.map(\.port), [9919, 9919])
        let restoredSubscription = await second.sentMessages().contains { message in
            guard case let .text(text) = message,
                  let control = try? JSONDecoder().decode(ControlMessage.self, from: Data(text.utf8)),
                  case let .subscribe(id, _) = control else { return false }
            return id == sessionID
        }
        XCTAssertTrue(restoredSubscription)

        await link.disconnect()
    }

    func testHeartbeatUsesProtocolPingAndMatchingPong() async throws {
        var configuration = URLSessionSessionLink.Configuration()
        configuration.heartbeatIntervalNanoseconds = 100_000_000
        configuration.initialReconnectDelayNanoseconds = 1_000_000
        configuration.maximumReconnectDelayNanoseconds = 10_000_000
        let socket = MockWebSocket()
        let factory = MockWebSocketFactory(sockets: [socket])
        let link = URLSessionSessionLink(configuration: configuration) { factory.make($0) }
        let endpoint = try ApprovedEndpoint(host: "127.0.0.1", port: 9919)
        let connect = Task { try await link.connect(to: endpoint, credential: CredentialHandle("test")) }

        try await waitForAuthentication(on: socket)
        await socket.enqueue(.text(try authenticationAck()))
        try await connect.value
        let nonce = try await waitForPing(on: socket)
        await socket.enqueue(.text(try encoded(.pong(nonce: nonce))))
        await link.disconnect()
    }

    func testSendQueueRejectsMessagesBeyondItsBound() async throws {
        var configuration = URLSessionSessionLink.Configuration()
        configuration.maximumQueuedMessages = 1
        let factory = MockWebSocketFactory(sockets: [])
        let link = URLSessionSessionLink(configuration: configuration) { factory.make($0) }

        try await link.send(.ping(nonce: 1))
        do {
            try await link.send(.ping(nonce: 2))
            XCTFail("Expected bounded queue to reject the second queued message")
        } catch let error as SessionLinkTransportError {
            XCTAssertEqual(error, .sendQueueFull)
        }
    }

    func testApprovedEndpointRejectsProductionPort() {
        XCTAssertThrowsError(try ApprovedEndpoint(host: "127.0.0.1", port: 9900)) {
            XCTAssertEqual($0 as? EndpointSafetyError, .productionEndpointForbidden)
        }
    }

    private func waitForAuthentication(on socket: MockWebSocket) async throws {
        for _ in 0..<200 {
            if await socket.sentMessages().contains(where: { message in
                guard case let .text(text) = message,
                      let control = try? JSONDecoder().decode(ControlMessage.self, from: Data(text.utf8)),
                      case .auth = control else { return false }
                return true
            }) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for authentication message")
        throw SessionLinkFailure.disconnected
    }

    private func waitForConnectedEpoch(in stream: any SessionEventStream) async throws -> ConnectionEpoch {
        for _ in 0..<16 {
            guard let event = try await stream.next() else { break }
            if case let .connectionChanged(.connected(epoch)) = event { return epoch }
        }
        XCTFail("Did not receive a connected event")
        throw SessionLinkFailure.disconnected
    }

    private func waitForPing(on socket: MockWebSocket) async throws -> UInt64 {
        for _ in 0..<200 {
            for message in await socket.sentMessages() {
                guard case let .text(text) = message,
                      let control = try? JSONDecoder().decode(ControlMessage.self, from: Data(text.utf8)),
                      case let .ping(nonce) = control else { continue }
                return nonce
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for heartbeat ping")
        throw SessionLinkFailure.disconnected
    }

    private func authenticationAck() throws -> String {
        try encoded(.authAck(accepted: true))
    }

    private func encoded(_ message: ControlMessage) throws -> String {
        String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
    }
}

private actor MockWebSocket: WebSocketConnection {
    private var incoming: [WebSocketMessage] = []
    private var receiver: CheckedContinuation<WebSocketMessage, Error>?
    private var receiveFailure: SessionLinkFailure?
    private var outgoing: [WebSocketMessage] = []

    func start() async throws {}

    func send(_ message: WebSocketMessage) async throws {
        outgoing.append(message)
    }

    func receive() async throws -> WebSocketMessage {
        if !incoming.isEmpty { return incoming.removeFirst() }
        if let receiveFailure { throw receiveFailure }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func ping() async throws {}

    func close() async {
        fail()
    }

    func enqueue(_ message: WebSocketMessage) {
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: message)
        } else {
            incoming.append(message)
        }
    }

    func fail() {
        receiveFailure = .disconnected
        receiver?.resume(throwing: SessionLinkFailure.disconnected)
        receiver = nil
    }

    func sentMessages() -> [WebSocketMessage] { outgoing }
}

private final class MockWebSocketFactory: @unchecked Sendable {
    private let sockets: [MockWebSocket]
    private let lock = NSLock()
    private var nextIndex = 0
    private(set) var createdURLs: [URL] = []

    init(sockets: [MockWebSocket]) { self.sockets = sockets }

    func make(_ url: URL) -> any WebSocketConnection {
        lock.lock()
        defer { lock.unlock() }
        createdURLs.append(url)
        guard nextIndex < sockets.count else { preconditionFailure("Unexpected WebSocket connection") }
        defer { nextIndex += 1 }
        return sockets[nextIndex]
    }
}
