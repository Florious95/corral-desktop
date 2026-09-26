import CorralContracts
import Foundation

public enum SessionLinkTransportError: Error, Equatable, Sendable {
    case sendQueueFull
    case concurrentEventReads
}

/// Native WebSocket implementation of the Corral session transport.
public actor URLSessionSessionLink: SessionLinkProtocol {
    struct Configuration: Sendable {
        var maximumQueuedMessages = 256
        var maximumBufferedEvents = 128
        var heartbeatIntervalNanoseconds: UInt64 = 15_000_000_000
        var initialReconnectDelayNanoseconds: UInt64 = 250_000_000
        var maximumReconnectDelayNanoseconds: UInt64 = 5_000_000_000

        static let live = Configuration()
    }

    private enum DesiredSubscription: Sendable {
        case subscribed(GridSize?)
        case unsubscribed
    }

    private struct QueuedMessage: Sendable {
        let id: UInt64
        let message: ControlMessage
    }

    private let configuration: Configuration
    private let codec: any WireCodecProtocol
    private let transportFactory: @Sendable (URL) -> any WebSocketConnection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var state: ConnectionState = .disconnected
    private var epoch = ConnectionEpoch.initial
    private var lifecycle: UInt64 = 0
    private var nextAttempt: UInt64 = 0
    private var activeAttempt: UInt64?
    private var endpoint: ApprovedEndpoint?
    private var credential: CredentialHandle?
    private var socket: (any WebSocketConnection)?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var flushingAttempt: UInt64?
    private var nextQueueID: UInt64 = 0
    private var nextHeartbeatNonce: UInt64 = 0
    private var awaitingPong: UInt64?
    private var outbound: [QueuedMessage] = []
    private var subscriptions: [SessionID: DesiredSubscription] = [:]
    private var streams: [WeakEventMailbox] = []

    public init(codec: any WireCodecProtocol = BinaryV1Codec()) {
        self.configuration = .live
        self.codec = codec
        self.transportFactory = { URLSessionWebSocketConnection(url: $0) }
    }

    init(
        codec: any WireCodecProtocol = BinaryV1Codec(),
        configuration: Configuration,
        transportFactory: @escaping @Sendable (URL) -> any WebSocketConnection
    ) {
        precondition(configuration.maximumQueuedMessages > 0)
        precondition(configuration.maximumBufferedEvents > 0)
        precondition(configuration.heartbeatIntervalNanoseconds > 0)
        precondition(configuration.initialReconnectDelayNanoseconds > 0)
        precondition(configuration.maximumReconnectDelayNanoseconds >= configuration.initialReconnectDelayNanoseconds)
        self.configuration = configuration
        self.codec = codec
        self.transportFactory = transportFactory
    }

    public func connect(to endpoint: ApprovedEndpoint, credential: CredentialHandle) async throws {
        // Revalidate through the contract's only endpoint gate before creating any transport.
        let approved = try ApprovedEndpoint(scheme: endpoint.scheme, host: endpoint.host, port: endpoint.port)
        lifecycle &+= 1
        let currentLifecycle = lifecycle
        cancelCurrentTasks()
        let previousSocket = socket
        socket = nil
        activeAttempt = nil
        outbound.removeAll()
        subscriptions.removeAll()
        self.endpoint = approved
        self.credential = credential
        awaitingPong = nil
        if let previousSocket { await previousSocket.close() }
        guard currentLifecycle == lifecycle else { throw CancellationError() }

        await setState(.connecting)
        do {
            try await establishConnection(lifecycle: currentLifecycle, restoreSubscriptions: true)
        } catch {
            guard currentLifecycle == lifecycle else { throw error }
            let failure = sessionFailure(for: error)
            self.endpoint = nil
            self.credential = nil
            await setState(.failed(failure))
            await publish(.failed(failure))
            throw error
        }
    }

    public func eventStream() async -> any SessionEventStream {
        let mailbox = EventMailbox(
            capacity: configuration.maximumBufferedEvents,
            initialEvent: .connectionChanged(state)
        )
        streams.append(WeakEventMailbox(mailbox))
        return mailbox
    }

    public func send(_ message: ControlMessage) async throws {
        if case .connected = state { try await flushOutbound() }
        guard outbound.count < configuration.maximumQueuedMessages else {
            throw SessionLinkTransportError.sendQueueFull
        }

        switch message {
        case let .subscribe(sessionID, initialSize):
            subscriptions[sessionID] = .subscribed(initialSize)
        case let .unsubscribe(sessionID):
            subscriptions[sessionID] = .unsubscribed
        default:
            break
        }
        nextQueueID &+= 1
        outbound.append(QueuedMessage(id: nextQueueID, message: message))
        try await flushOutbound()
    }

    public func disconnect() async {
        lifecycle &+= 1
        let currentLifecycle = lifecycle
        cancelCurrentTasks()
        endpoint = nil
        credential = nil
        activeAttempt = nil
        awaitingPong = nil
        outbound.removeAll()
        subscriptions.removeAll()
        let previousSocket = socket
        socket = nil
        if let previousSocket { await previousSocket.close() }
        guard currentLifecycle == lifecycle else { return }
        await setState(.disconnected)
    }

    private func establishConnection(lifecycle expectedLifecycle: UInt64, restoreSubscriptions: Bool) async throws {
        guard expectedLifecycle == lifecycle, let endpoint, let credential else { throw CancellationError() }
        nextAttempt &+= 1
        let attempt = nextAttempt
        activeAttempt = attempt
        let candidate = transportFactory(endpoint.url)
        socket = candidate

        do {
            try await candidate.start()
            try await candidate.send(.text(try encoder.encode(ControlMessage.auth(credential: credential)).utf8String))
            let response = try await candidate.receive()
            guard case let .text(text) = response,
                  case let .authAck(accepted) = try decoder.decode(ControlMessage.self, from: Data(text.utf8)) else {
                throw SessionLinkFailure.protocolViolation("Expected authentication acknowledgement")
            }
            guard accepted else { throw SessionLinkFailure.unauthorized }
            guard expectedLifecycle == lifecycle, activeAttempt == attempt else { throw CancellationError() }

            socket = candidate
            awaitingPong = nil
            if restoreSubscriptions {
                try await restoreDesiredSubscriptions(on: candidate)
            }
            try await drainOutbound(on: candidate, attempt: attempt, whileConnecting: true)
            guard expectedLifecycle == lifecycle, activeAttempt == attempt else { throw CancellationError() }
            guard epoch.rawValue < UInt64.max else {
                throw SessionLinkFailure.transport("Connection epoch exhausted")
            }
            epoch = ConnectionEpoch(epoch.rawValue + 1)
            await setState(.connected(epoch))
            guard expectedLifecycle == lifecycle, activeAttempt == attempt else { throw CancellationError() }
            receiveTask = Task { [weak self] in await self?.receiveLoop(on: candidate, attempt: attempt) }
            heartbeatTask = Task { [weak self] in await self?.heartbeatLoop(on: candidate, attempt: attempt) }
        } catch {
            await candidate.close()
            if activeAttempt == attempt {
                activeAttempt = nil
                socket = nil
                awaitingPong = nil
            }
            throw error
        }
    }

    private func restoreDesiredSubscriptions(on candidate: any WebSocketConnection) async throws {
        let snapshot = subscriptions.sorted { $0.key.rawValue < $1.key.rawValue }
        outbound.removeAll {
            switch $0.message {
            case .subscribe, .unsubscribe: true
            default: false
            }
        }
        for (sessionID, desired) in snapshot {
            let message: ControlMessage
            switch desired {
            case let .subscribed(size): message = .subscribe(sessionID: sessionID, initialSize: size)
            case .unsubscribed: message = .unsubscribe(sessionID: sessionID)
            }
            try await sendDirect(message, on: candidate)
        }
    }

    private func drainOutbound(
        on candidate: any WebSocketConnection,
        attempt: UInt64,
        whileConnecting: Bool = false
    ) async throws {
        guard flushingAttempt == nil else { return }
        flushingAttempt = attempt
        defer { if flushingAttempt == attempt { flushingAttempt = nil } }

        while let item = outbound.first {
            guard activeAttempt == attempt,
                  whileConnecting || isConnected(attempt: attempt) else { return }
            try await sendDirect(item.message, on: candidate)
            guard activeAttempt == attempt else { return }
            if outbound.first?.id == item.id { outbound.removeFirst() }
        }
    }

    private func flushOutbound() async throws {
        guard case .connected = state,
              let candidate = socket,
              let attempt = activeAttempt else { return }
        do {
            try await drainOutbound(on: candidate, attempt: attempt)
        } catch {
            await transportFailed(attempt: attempt, error: error)
            throw error
        }
    }

    private func sendDirect(_ message: ControlMessage, on candidate: any WebSocketConnection) async throws {
        let data = try encoder.encode(message)
        try await candidate.send(.text(data.utf8String))
    }

    private func receiveLoop(on candidate: any WebSocketConnection, attempt: UInt64) async {
        while !Task.isCancelled, activeAttempt == attempt {
            do {
                let message = try await candidate.receive()
                try await handleIncoming(message, on: candidate, attempt: attempt)
            } catch is CancellationError {
                return
            } catch let failure as SessionLinkFailure {
                if case .unauthorized = failure {
                    await authenticationFailed(attempt: attempt)
                } else if case .protocolViolation = failure {
                    await protocolFailed(attempt: attempt, failure: failure)
                } else {
                    await transportFailed(attempt: attempt, error: failure)
                }
                return
            } catch {
                await transportFailed(attempt: attempt, error: error)
                return
            }
        }
    }

    private func handleIncoming(
        _ message: WebSocketMessage,
        on candidate: any WebSocketConnection,
        attempt: UInt64
    ) async throws {
        switch message {
        case let .binary(data):
            do { await publish(.frame(try codec.decodeBinaryFrame(data))) }
            catch { throw SessionLinkFailure.protocolViolation(String(describing: error)) }
        case let .text(text):
            let control: ControlMessage
            do { control = try decoder.decode(ControlMessage.self, from: Data(text.utf8)) }
            catch { throw SessionLinkFailure.protocolViolation("Invalid control message: \(error)") }
            switch control {
            case let .authAck(accepted):
                if !accepted { throw SessionLinkFailure.unauthorized }
                throw SessionLinkFailure.protocolViolation("Unexpected authentication acknowledgement")
            case let .ping(nonce):
                try await sendDirect(.pong(nonce: nonce), on: candidate)
                await publish(.control(control))
            case let .pong(nonce):
                if awaitingPong == nonce { awaitingPong = nil }
                await publish(.control(control))
            default:
                await publish(.control(control))
            }
        }
        guard activeAttempt == attempt else { return }
    }

    private func heartbeatLoop(on candidate: any WebSocketConnection, attempt: UInt64) async {
        while !Task.isCancelled, activeAttempt == attempt {
            do { try await Task.sleep(nanoseconds: configuration.heartbeatIntervalNanoseconds) }
            catch { return }
            guard activeAttempt == attempt else { return }
            if awaitingPong != nil {
                await transportFailed(
                    attempt: attempt,
                    error: SessionLinkFailure.disconnected
                )
                return
            }
            nextHeartbeatNonce &+= 1
            let nonce = nextHeartbeatNonce
            awaitingPong = nonce
            do {
                try await candidate.ping()
                try await sendDirect(.ping(nonce: nonce), on: candidate)
            } catch {
                await transportFailed(attempt: attempt, error: error)
                return
            }
        }
    }

    private func transportFailed(attempt: UInt64, error: Error) async {
        guard activeAttempt == attempt else { return }
        let expectedLifecycle = lifecycle
        activeAttempt = nil
        let previousSocket = socket
        socket = nil
        awaitingPong = nil
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        receiveTask = nil
        heartbeatTask = nil
        let failure = sessionFailure(for: error)
        if let previousSocket { await previousSocket.close() }
        guard expectedLifecycle == lifecycle else { return }
        await setState(.disconnected)
        guard expectedLifecycle == lifecycle else { return }
        await publish(.failed(failure))
        guard expectedLifecycle == lifecycle,
              endpoint != nil, credential != nil, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            await self?.reconnectLoop(lifecycle: expectedLifecycle)
        }
    }

    private func reconnectLoop(lifecycle expectedLifecycle: UInt64) async {
        var delay = configuration.initialReconnectDelayNanoseconds
        defer { if lifecycle == expectedLifecycle { reconnectTask = nil } }

        while !Task.isCancelled, expectedLifecycle == lifecycle, endpoint != nil {
            do { try await Task.sleep(nanoseconds: delay) }
            catch { return }
            guard expectedLifecycle == lifecycle, endpoint != nil else { return }
            await setState(.connecting)
            do {
                try await establishConnection(lifecycle: expectedLifecycle, restoreSubscriptions: true)
                return
            } catch is CancellationError {
                return
            } catch let failure as SessionLinkFailure {
                if case .unauthorized = failure {
                    await authenticationFailed(attempt: activeAttempt ?? 0)
                    return
                }
                await publish(.failed(failure))
            } catch {
                await publish(.failed(sessionFailure(for: error)))
            }
            let doubledDelay = delay.multipliedReportingOverflow(by: 2)
            delay = min(
                doubledDelay.overflow ? configuration.maximumReconnectDelayNanoseconds : doubledDelay.partialValue,
                configuration.maximumReconnectDelayNanoseconds
            )
        }
    }

    private func authenticationFailed(attempt: UInt64) async {
        guard attempt == 0 || activeAttempt == attempt else { return }
        let expectedLifecycle = lifecycle
        activeAttempt = nil
        endpoint = nil
        credential = nil
        outbound.removeAll()
        subscriptions.removeAll()
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        let previousSocket = socket
        socket = nil
        awaitingPong = nil
        if let previousSocket { await previousSocket.close() }
        guard expectedLifecycle == lifecycle else { return }
        await setState(.failed(.unauthorized))
        await publish(.failed(.unauthorized))
    }

    private func protocolFailed(attempt: UInt64, failure: SessionLinkFailure) async {
        guard activeAttempt == attempt else { return }
        let expectedLifecycle = lifecycle
        activeAttempt = nil
        endpoint = nil
        credential = nil
        outbound.removeAll()
        subscriptions.removeAll()
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        let previousSocket = socket
        socket = nil
        if let previousSocket { await previousSocket.close() }
        guard expectedLifecycle == lifecycle else { return }
        await setState(.failed(failure))
        await publish(.failed(failure))
    }

    private func setState(_ newState: ConnectionState) async {
        state = newState
        await publish(.connectionChanged(newState))
    }

    private func publish(_ event: SessionEvent) async {
        var active: [WeakEventMailbox] = []
        for weakMailbox in streams {
            guard let mailbox = weakMailbox.value else { continue }
            active.append(weakMailbox)
            await mailbox.enqueue(event)
        }
        streams = active
    }

    private func isConnected(attempt: UInt64) -> Bool {
        guard activeAttempt == attempt else { return false }
        if case .connected = state { return true }
        return false
    }

    private func cancelCurrentTasks() {
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        reconnectTask?.cancel()
        receiveTask = nil
        heartbeatTask = nil
        reconnectTask = nil
        flushingAttempt = nil
    }

    private func sessionFailure(for error: Error) -> SessionLinkFailure {
        if let failure = error as? SessionLinkFailure { return failure }
        if error is EndpointSafetyError { return .protocolViolation("Endpoint rejected by ApprovedEndpoint") }
        return .transport(String(describing: error))
    }
}

enum WebSocketMessage: Sendable {
    case text(String)
    case binary(Data)
}

protocol WebSocketConnection: Sendable {
    func start() async throws
    func send(_ message: WebSocketMessage) async throws
    func receive() async throws -> WebSocketMessage
    func ping() async throws
    func close() async
}

private final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let delegate: RejectWebSocketRedirects
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        let delegate = RejectWebSocketRedirects()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        self.delegate = delegate
        self.session = session
        self.task = session.webSocketTask(with: url)
    }

    func start() async throws { task.resume() }

    func send(_ message: WebSocketMessage) async throws {
        switch message {
        case let .text(value): try await task.send(.string(value))
        case let .binary(value): try await task.send(.data(value))
        }
    }

    func receive() async throws -> WebSocketMessage {
        switch try await task.receive() {
        case let .string(value): .text(value)
        case let .data(value): .binary(value)
        @unknown default: throw SessionLinkFailure.protocolViolation("Unknown WebSocket message")
        }
    }

    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func close() async {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

private final class RejectWebSocketRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private actor EventMailbox: SessionEventStream {
    private let capacity: Int
    private var buffer: [SessionEvent] = []
    private var waiter: CheckedContinuation<SessionEvent?, Error>?
    private var terminalError: SessionLinkFailure?
    private var finished = false

    init(capacity: Int, initialEvent: SessionEvent) {
        self.capacity = capacity
        self.buffer = [initialEvent]
    }

    func enqueue(_ event: SessionEvent) {
        guard !finished else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: event)
        } else if buffer.count < capacity {
            buffer.append(event)
        } else {
            buffer.removeAll()
            terminalError = .eventBufferOverflow
            finished = true
            waiter?.resume(throwing: SessionLinkFailure.eventBufferOverflow)
            waiter = nil
        }
    }

    func next() async throws -> SessionEvent? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if let terminalError {
            self.terminalError = nil
            throw terminalError
        }
        if finished { return nil }
        guard waiter == nil else { throw SessionLinkTransportError.concurrentEventReads }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
}

private final class WeakEventMailbox: @unchecked Sendable {
    weak var value: EventMailbox?
    init(_ value: EventMailbox) { self.value = value }
}

private extension Data {
    var utf8String: String { String(decoding: self, as: UTF8.self) }
}
