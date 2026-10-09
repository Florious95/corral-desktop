@testable import CorralProtocol
import CorralContracts
import Foundation
import XCTest

final class URLSessionSessionLinkTests: XCTestCase {
    func testStalledWriteTimesOutWithoutReplayingInputAndReconnects() async throws {
        var configuration = URLSessionSessionLink.Configuration()
        configuration.sendTimeoutNanoseconds = 40_000_000
        configuration.initialReconnectDelayNanoseconds = 1_000_000
        let first = MockWebSocket()
        let second = MockWebSocket()
        let factory = MockWebSocketFactory(sockets: [first, second])
        let link = URLSessionSessionLink(configuration: configuration) { factory.make($0) }
        let connect = Task { try await link.connect(to: ApprovedEndpoint(host: "127.0.0.1", port: 9919),
            deviceID: DeviceID("deadline"), credential: CredentialHandle("test")) }
        try await waitForAuthentication(on: first)
        await first.enqueue(.text(authenticationAck()))
        _ = try await connect.value
        await first.blockNextSend()
        let input = try ClientInputRequest(sequence: 42, reference: SessionReference("input"), payload: .bytes(Data("x".utf8)))
        do { _ = try await link.send(.input(input)); XCTFail("The socket write is still blocked") }
        catch { XCTAssertEqual(error as? SessionLinkFailure, .inputOutcomeUnknown(requestID: 42)) }
        try await waitForAuthentication(on: second)
        await second.enqueue(.text(authenticationAck()))
        let stream = try await link.eventStream()
        while try await waitForReady(in: stream).epoch != ConnectionEpoch(2) {}
        _ = try await link.send(.list(requestID: 2))
        let messages = await second.sentMessages()
        XCTAssertFalse(messages.contains { if case let .text(text) = $0 { text.contains("\"input\"") } else { false } })
        await first.releaseSend()
        await link.disconnect()
    }

    func testDisconnectUnblocksSaturatedMailboxWithoutAConsumer() async throws {
        var configuration = URLSessionSessionLink.Configuration()
        configuration.maximumBufferedEvents = 8
        configuration.maximumBufferedControls = 4
        let socket = MockWebSocket()
        let link = URLSessionSessionLink(configuration: configuration) { _ in socket }
        let stream = try await link.eventStream()
        let connect = Task { try await link.connect(to: ApprovedEndpoint(host: "127.0.0.1", port: 9919),
            deviceID: DeviceID("saturated"), credential: CredentialHandle("test")) }
        try await waitForAuthentication(on: socket)
        await socket.enqueue(.text(authenticationAck()))
        _ = try await connect.value
        _ = try await waitForReady(in: stream)
        let codec = BinaryV1Codec()
        for _ in 0..<32 { await socket.enqueue(.binary(try codec.encodeBinaryFrame(.delta(reference: SessionReference("busy"), ansi: Data("x".utf8))))) }
        try await Task.sleep(for: .milliseconds(40))
        let stopped = expectation(description: "disconnect releases a backpressured producer")
        let stopping = Task { await link.disconnect(); stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 1)
        await stopping.value
        let event = try await stream.next()
        XCTAssertEqual(event?.event, .connectionChanged(.disconnected))
    }

    func testDisconnectReleasesInFlightInputAndNewConnectionSender() async throws {
        let first = MockWebSocket()
        let second = MockWebSocket()
        let factory = MockWebSocketFactory(sockets: [first, second])
        let link = URLSessionSessionLink(configuration: .init()) { factory.make($0) }
        let endpoint = try ApprovedEndpoint(host: "127.0.0.1", port: 9919)
        let device = DeviceID("blocked-writer")
        let connect = Task { try await link.connect(to: endpoint, deviceID: device, credential: CredentialHandle("test")) }
        try await waitForAuthentication(on: first)
        await first.enqueue(.text(authenticationAck()))
        _ = try await connect.value
        await first.blockNextSend()
        let oldFinished = expectation(description: "in-flight input resolved without waiting for the transport")
        let input = try ClientInputRequest(sequence: 1, reference: SessionReference("old"), payload: .bytes(Data("x".utf8)))
        let sending = Task {
            do { _ = try await link.send(.input(input)); XCTFail("A disconnected in-flight input must not report success") }
            catch { XCTAssertEqual(error as? SessionLinkFailure, .inputOutcomeUnknown(requestID: 1)) }
            oldFinished.fulfill()
        }
        for _ in 0..<200 {
            if await first.isSendBlocked() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await link.disconnect()
        let reconnect = Task { try await link.connect(to: endpoint, deviceID: device, credential: CredentialHandle("test")) }
        try await waitForAuthentication(on: second)
        await second.enqueue(.text(authenticationAck()))
        _ = try await reconnect.value
        let newFinished = expectation(description: "new connection is not blocked by the old sender")
        let fresh = Task {
            do { _ = try await link.send(.list(requestID: 2)) }
            catch { XCTFail("New connection failed: \(error)") }
            newFinished.fulfill()
        }
        await fulfillment(of: [oldFinished, newFinished], timeout: 1)
        // A deliberately uncooperative socket returns late, after the epoch has changed.
        await first.releaseSend()
        await sending.value
        await fresh.value
        await link.disconnect()
    }

    func testSlowConsumerBackpressuresWithoutLosingTerminalStream() async throws {
        var configuration = URLSessionSessionLink.Configuration()
        configuration.maximumBufferedEvents = 8
        configuration.maximumBufferedControls = 4
        configuration.heartbeatIntervalNanoseconds = 60_000_000_000
        let socket = MockWebSocket()
        let link = URLSessionSessionLink(configuration: configuration) { _ in socket }
        let stream = try await link.eventStream()
        let connect = Task {
            try await link.connect(to: ApprovedEndpoint(host: "127.0.0.1", port: 9919),
                                   deviceID: DeviceID("slow-reader"), credential: CredentialHandle("test"))
        }
        try await waitForAuthentication(on: socket)
        await socket.enqueue(.text(authenticationAck()))
        _ = try await connect.value
        _ = try await waitForReady(in: stream)
        let reference = try SessionReference("live-output")
        let codec = BinaryV1Codec()
        for index in 0..<64 {
            let frame = BinaryFrame.delta(reference: reference, ansi: Data("FRAME-\(index)\r\n".utf8))
            await socket.enqueue(.binary(try codec.encodeBinaryFrame(frame)))
        }
        // A render/persistence stall must slow the producer, not permanently finish the only stream.
        try await Task.sleep(for: .milliseconds(100))
        for index in 0..<64 {
            let event = try await stream.next()
            XCTAssertEqual(event?.event, .frame(.delta(reference: reference, ansi: Data("FRAME-\(index)\r\n".utf8))))
        }
        let receipt = try await link.send(.list(requestID: 99))
        XCTAssertTrue(receipt.socketWritten)
        await link.disconnect()
    }

    func testReconnectIncrementsEpochPreservesSubscriptionAndEventOrdinals() async throws {
        var configuration = URLSessionSessionLink.Configuration()
        configuration.heartbeatIntervalNanoseconds = 60_000_000_000
        configuration.initialReconnectDelayNanoseconds = 1_000_000
        configuration.maximumReconnectDelayNanoseconds = 10_000_000
        let first = MockWebSocket()
        let second = MockWebSocket()
        let factory = MockWebSocketFactory(sockets: [first, second])
        let link = URLSessionSessionLink(configuration: configuration) { factory.make($0) }
        let events = try await link.eventStream()
        let endpoint = try ApprovedEndpoint(host: "127.0.0.1", port: 9919)
        let deviceID = DeviceID("device-a")

        let connect = Task {
            try await link.connect(to: endpoint, deviceID: deviceID, credential: CredentialHandle("test"))
        }
        try await waitForAuthentication(on: first)
        await first.enqueue(.text(authenticationAck()))
        let firstConnection = try await connect.value
        let firstReady = try await waitForReady(in: events)
        XCTAssertEqual(firstReady.epoch, ConnectionEpoch(1))
        XCTAssertEqual(firstConnection.connectionEpoch, firstReady.epoch)
        XCTAssertEqual(firstConnection.deviceID, deviceID)
        XCTAssertEqual(firstConnection.linkInstanceID, firstReady.linkInstanceID)

        let reference = try SessionReference("session-a")
        _ = try await link.send(.subscribe(reference: reference, size: GridSize(rows: 24, columns: 80)))
        await first.fail()
        try await waitForAuthentication(on: second)
        await second.enqueue(.text(authenticationAck()))
        let secondReady = try await waitForReady(in: events)
        XCTAssertEqual(secondReady.epoch, ConnectionEpoch(2))
        XCTAssertGreaterThan(secondReady.ordinal, firstReady.ordinal)
        XCTAssertEqual(factory.createdURLs.map(\.port), [9919, 9919])
        let secondMessages = await second.sentMessages()
        XCTAssertTrue(secondMessages.contains { isSubscription($0, reference: reference) })
        await link.disconnect()
    }

    func testReconnectPreservesSubscribeGrid() async throws {
        var configuration = URLSessionSessionLink.Configuration()
        configuration.heartbeatIntervalNanoseconds = 60_000_000_000
        configuration.initialReconnectDelayNanoseconds = 1_000_000
        configuration.maximumReconnectDelayNanoseconds = 10_000_000
        let first = MockWebSocket()
        let second = MockWebSocket()
        let factory = MockWebSocketFactory(sockets: [first, second])
        let link = URLSessionSessionLink(configuration: configuration) { factory.make($0) }
        let events = try await link.eventStream()
        let endpoint = try ApprovedEndpoint(host: "127.0.0.1", port: 9919)
        let reference = try SessionReference("inspection-session")
        let serverGrid = GridSize(rows: 37, columns: 111)

        let connect = Task {
            try await link.connect(to: endpoint, deviceID: DeviceID("device-a"), credential: CredentialHandle("test"))
        }
        try await waitForAuthentication(on: first)
        await first.enqueue(.text(authenticationAck()))
        _ = try await connect.value
        _ = try await waitForReady(in: events)
        _ = try await link.send(.subscribe(reference: reference, size: serverGrid))

        await first.fail()
        try await waitForAuthentication(on: second)
        await second.enqueue(.text(authenticationAck()))
        _ = try await waitForReady(in: events)
        let replayedMessages = await second.sentMessages()
        let payload = try XCTUnwrap(subscriptionPayload(in: replayedMessages, reference: reference))
        XCTAssertEqual(payload["rows"] as? Int, serverGrid.rows)
        XCTAssertEqual(payload["cols"] as? Int, serverGrid.columns)
        await link.disconnect()
    }

    func testReconnectReplaysOnlyLatestSubscribeGridAfterMobileRotation() async throws {
        var configuration = URLSessionSessionLink.Configuration()
        configuration.heartbeatIntervalNanoseconds = 60_000_000_000
        configuration.initialReconnectDelayNanoseconds = 1_000_000
        configuration.maximumReconnectDelayNanoseconds = 10_000_000
        let first = MockWebSocket()
        let second = MockWebSocket()
        let factory = MockWebSocketFactory(sockets: [first, second])
        let link = URLSessionSessionLink(configuration: configuration) { factory.make($0) }
        let events = try await link.eventStream()
        let endpoint = try ApprovedEndpoint(host: "127.0.0.1", port: 9919)
        let reference = try SessionReference("mobile-rotation")
        let desktopGrid = GridSize(rows: 51, columns: 139)
        let phoneGrid = GridSize(rows: 24, columns: 80)

        let connect = Task {
            try await link.connect(to: endpoint, deviceID: DeviceID("device-a"), credential: CredentialHandle("test"))
        }
        try await waitForAuthentication(on: first)
        await first.enqueue(.text(authenticationAck()))
        _ = try await connect.value
        _ = try await waitForReady(in: events)

        // A phone rotation replaces the desktop's previously requested grid.
        _ = try await link.send(.subscribe(reference: reference, size: desktopGrid))
        _ = try await link.send(.subscribe(reference: reference, size: phoneGrid))

        await first.fail()
        try await waitForAuthentication(on: second)
        await second.enqueue(.text(authenticationAck()))
        _ = try await waitForReady(in: events)

        let replayed = await second.sentMessages()
        let replayedSubscriptions = subscriptionPayloads(in: replayed, reference: reference)
        XCTAssertEqual(replayedSubscriptions.count, 1, "reconnect must replay one current subscription, not stale size history")
        let payload = try XCTUnwrap(replayedSubscriptions.first)
        XCTAssertEqual(payload["rows"] as? Int, phoneGrid.rows)
        XCTAssertEqual(payload["cols"] as? Int, phoneGrid.columns)
        XCTAssertFalse(replayedSubscriptions.contains { ($0["rows"] as? Int) == desktopGrid.rows && ($0["cols"] as? Int) == desktopGrid.columns },
                       "reconnect must not replay the old desktop grid after mobile rotation")
        await link.disconnect()
    }

    func testHeartbeatUsesWebSocketPing() async throws {
        var configuration = URLSessionSessionLink.Configuration()
        configuration.heartbeatIntervalNanoseconds = 100_000_000
        configuration.initialReconnectDelayNanoseconds = 1_000_000
        configuration.maximumReconnectDelayNanoseconds = 10_000_000
        let socket = MockWebSocket()
        let link = URLSessionSessionLink(configuration: configuration) { _ in socket }
        let endpoint = try ApprovedEndpoint(host: "127.0.0.1", port: 9919)
        let connect = Task {
            try await link.connect(to: endpoint, deviceID: DeviceID("device-a"), credential: CredentialHandle("test"))
        }
        try await waitForAuthentication(on: socket)
        await socket.enqueue(.text(authenticationAck()))
        _ = try await connect.value
        try await waitForPing(on: socket)
        await link.disconnect()
    }

    func testAuthenticationAckIsPublishedWithLauncherPayload() async throws {
        let socket = MockWebSocket()
        let link = URLSessionSessionLink(configuration: .init()) { _ in socket }
        let events = try await link.eventStream()
        let endpoint = try ApprovedEndpoint(host: "127.0.0.1", port: 9919)
        let connect = Task {
            try await link.connect(to: endpoint, deviceID: DeviceID("device-a"), credential: CredentialHandle("test"))
        }
        let launchers = [
            AgentLauncher(provider: "codex", displayName: "Codex CLI", supportsBypass: true, naming: .tmux),
            AgentLauncher(provider: "claude", displayName: "Claude Code", supportsBypass: false, naming: .cli)
        ]

        try await waitForAuthentication(on: socket)
        await socket.enqueue(.text(#"{"v":1,"type":"auth_ack","payload":{"ok":true,"agent_launchers":[{"provider":"codex","display_name":"Codex CLI","supports_bypass":true,"naming":"tmux"},{"provider":"claude","display_name":"Claude Code","supports_bypass":false,"naming":"cli"}]}}"#))
        _ = try await connect.value

        var publishedAuthAck: ControlMessage?
        var reachedReady = false
        for _ in 0..<16 {
            guard let envelope = try await events.next() else { break }
            switch envelope.event {
            case let .control(control):
                if case .authAck = control { publishedAuthAck = control }
            case let .connectionChanged(state):
                if case .authenticatedReady = state { reachedReady = true }
            default:
                break
            }
            if publishedAuthAck != nil || reachedReady { break }
        }

        XCTAssertEqual(publishedAuthAck, .authAck(ok: true, reason: nil, launchers: launchers))
        await link.disconnect()
    }

    func testSendRequiresReadyConnectionAndEventStreamHasOneConsumer() async throws {
        let socket = MockWebSocket()
        let link = URLSessionSessionLink(configuration: .init()) { _ in socket }
        do {
            _ = try await link.send(.list(requestID: 1))
            XCTFail("A command must not be queued before authenticated readiness")
        } catch let error as SessionLinkFailure {
            XCTAssertEqual(error, .unauthenticated)
        }
        _ = try await link.eventStream()
        do {
            _ = try await link.eventStream()
            XCTFail("Only one event consumer is allowed")
        } catch let error as SessionLinkFailure {
            XCTAssertEqual(error, .eventStreamAlreadyClaimed)
        }
    }

    func testApprovedEndpointAcceptsLoopback9900() throws {
        XCTAssertEqual(try ApprovedEndpoint(host: "127.0.0.1", port: 9900).url.absoluteString, "ws://127.0.0.1:9900/ws")
    }

    func testLoopback9900RequiresAuthenticationBeforeReady() async throws {
        let socket = MockWebSocket()
        let factory = MockWebSocketFactory(sockets: [socket])
        let link = URLSessionSessionLink(configuration: .init()) { factory.make($0) }
        let endpoint = try ApprovedEndpoint(url: XCTUnwrap(URL(string: "ws://127.0.0.1:9900/ws")))
        let connect = Task {
            try await link.connect(to: endpoint, deviceID: DeviceID("device-a"), credential: SessionLinkCredential.localPeerAnonymous)
        }

        try await waitForAuthentication(on: socket, token: SessionLinkCredential.localPeerAnonymous.rawValue)
        await socket.enqueue(.text(authenticationAck()))
        _ = try await connect.value
        XCTAssertEqual(factory.createdURLs.map(\.absoluteString), ["ws://127.0.0.1:9900/ws"])
        await link.disconnect()
    }

    private func waitForAuthentication(on socket: MockWebSocket, token: String = "test") async throws {
        for _ in 0..<200 {
            if await socket.sentMessages().contains(where: { message in
                guard case let .text(text) = message,
                      let envelope = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      envelope["type"] as? String == "auth",
                      let payload = envelope["payload"] as? [String: Any] else { return false }
                return payload["token"] as? String == token
            }) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for authentication message")
        throw SessionLinkFailure.disconnected
    }

    private func waitForReady(in stream: any SessionEventStream) async throws -> (epoch: ConnectionEpoch, ordinal: UInt64, linkInstanceID: LinkInstanceID) {
        for _ in 0..<32 {
            guard let envelope = try await stream.next() else { break }
            if case let .connectionChanged(.authenticatedReady(epoch)) = envelope.event {
                return (epoch, envelope.origin.receiveOrdinal.rawValue, envelope.origin.linkInstanceID)
            }
        }
        XCTFail("Did not receive an authenticated-ready event")
        throw SessionLinkFailure.disconnected
    }

    private func waitForPing(on socket: MockWebSocket) async throws {
        for _ in 0..<200 {
            if await socket.pingCount() > 0 { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for WebSocket ping")
    }

    private func authenticationAck() -> String {
        #"{"v":1,"type":"auth_ack","payload":{"ok":true}}"#
    }

    private func isSubscription(_ message: WebSocketMessage, reference: SessionReference) -> Bool {
        subscriptionPayload(in: [message], reference: reference) != nil
    }

    private func subscriptionPayload(in messages: [WebSocketMessage], reference: SessionReference) -> [String: Any]? {
        for message in messages {
            guard case let .text(text) = message,
                  let envelope = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  envelope["type"] as? String == "subscribe",
                  let payload = envelope["payload"] as? [String: Any],
                  payload["ref"] as? String == reference.rawValue else { continue }
            return payload
        }
        return nil
    }

    private func subscriptionPayloads(in messages: [WebSocketMessage], reference: SessionReference) -> [[String: Any]] {
        messages.compactMap { message in
            guard case let .text(text) = message,
                  let envelope = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  envelope["type"] as? String == "subscribe",
                  let payload = envelope["payload"] as? [String: Any],
                  payload["ref"] as? String == reference.rawValue else { return nil }
            return payload
        }
    }
}

private actor MockWebSocket: WebSocketConnection {
    private var incoming: [WebSocketMessage] = []
    private var receiver: CheckedContinuation<WebSocketMessage, Error>?
    private var receiveFailure: SessionLinkFailure?
    private var outgoing: [WebSocketMessage] = []
    private var pings = 0
    private var blockSend = false
    private var blockedSend: CheckedContinuation<Void, Never>?

    func start() async throws {}

    func send(_ message: WebSocketMessage) async throws {
        outgoing.append(message)
        if blockSend {
            blockSend = false
            await withCheckedContinuation { blockedSend = $0 }
        }
    }

    func blockNextSend() { blockSend = true }
    func isSendBlocked() -> Bool { blockedSend != nil }
    func releaseSend() { blockedSend?.resume(); blockedSend = nil }

    func receive() async throws -> WebSocketMessage {
        if !incoming.isEmpty { return incoming.removeFirst() }
        if let receiveFailure { throw receiveFailure }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func ping() async throws { pings += 1 }

    func close() async { fail() }

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
    func pingCount() -> Int { pings }
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
