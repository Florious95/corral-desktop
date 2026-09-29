import CorralContracts
import Foundation

public enum SessionLinkTransportError: Error, Equatable, Sendable {
    case sendQueueFull
    case sendTimedOut
}

/// Native WebSocket implementation of the frozen Protocol v1 session-link contract.
public actor URLSessionSessionLink: SessionLinkProtocol {
    struct Configuration: Sendable {
        var maximumQueuedMessages: Int = 256
        var sendTimeoutNanoseconds: UInt64 = 5_000_000_000
        var maximumBufferedEvents: UInt32 = 128
        var maximumBufferedBytes: UInt64 = 16 * 1_024 * 1_024
        var maximumBufferedControls: UInt32 = 32
        var heartbeatIntervalNanoseconds: UInt64 = 15_000_000_000
        var initialReconnectDelayNanoseconds: UInt64 = 250_000_000
        var maximumReconnectDelayNanoseconds: UInt64 = 5_000_000_000

        static let live = Configuration()
    }

    private enum DesiredSubscription: Sendable {
        case subscribed(GridSize)
    }

    private struct PendingSend {
        let id = UUID()
        let command: ClientCommand
        let attempt: UInt64
        let epoch: ConnectionEpoch
        let continuation: CheckedContinuation<CommandSendReceipt, Error>
    }

    private let configuration: Configuration
    private let codec: any WireCodecProtocol
    private let transportFactory: @Sendable (URL) -> any WebSocketConnection
    private let linkInstanceID = LinkInstanceID()
    private let eventMailbox: EventMailbox

    private var state: ConnectionState = .disconnected
    private var epoch = ConnectionEpoch.initial
    private var receiveOrdinal: UInt64 = 0
    private var lifecycle: UInt64 = 0
    private var nextAttempt: UInt64 = 0
    private var activeAttempt: UInt64?
    private var endpoint: ApprovedEndpoint?
    private var deviceID: DeviceID?
    private var credential: CredentialHandle?
    private var socket: (any WebSocketConnection)?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var senderTask: Task<Void, Never>?
    private var sendTimeoutTask: Task<Void, Never>?
    private var inFlight: PendingSend?
    private var eventStreamClaimed = false
    private var outbound: [PendingSend] = []
    private var subscriptions: [SessionReference: DesiredSubscription] = [:]

    public init(codec: any WireCodecProtocol = ProtocolV1Codec()) {
        self.configuration = .live
        self.codec = codec
        self.transportFactory = { URLSessionWebSocketConnection(url: $0) }
        self.eventMailbox = EventMailbox(budget: Self.budget(for: .live))
    }

    init(
        codec: any WireCodecProtocol = ProtocolV1Codec(),
        configuration: Configuration,
        transportFactory: @escaping @Sendable (URL) -> any WebSocketConnection
    ) {
        precondition(configuration.maximumQueuedMessages > 0)
        precondition(configuration.sendTimeoutNanoseconds > 0)
        precondition(configuration.maximumBufferedEvents > 0)
        precondition(configuration.maximumBufferedBytes > 0)
        precondition(configuration.maximumBufferedControls <= configuration.maximumBufferedEvents)
        precondition(configuration.heartbeatIntervalNanoseconds > 0)
        precondition(configuration.initialReconnectDelayNanoseconds > 0)
        precondition(configuration.maximumReconnectDelayNanoseconds >= configuration.initialReconnectDelayNanoseconds)
        self.configuration = configuration
        self.codec = codec
        self.transportFactory = transportFactory
        self.eventMailbox = EventMailbox(budget: Self.budget(for: configuration))
    }

    public func connect(
        to endpoint: ApprovedEndpoint,
        deviceID: DeviceID,
        credential: CredentialHandle
    ) async throws -> AuthenticatedConnection {
        let approved = try ApprovedEndpoint(
            scheme: endpoint.scheme,
            host: endpoint.host,
            port: endpoint.port,
            path: endpoint.path
        )
        lifecycle &+= 1
        let currentLifecycle = lifecycle
        cancelCurrentTasks()
        failQueuedSends(SessionLinkFailure.disconnected)
        let previousSocket = socket
        socket = nil
        activeAttempt = nil
        subscriptions.removeAll()
        self.endpoint = approved
        self.deviceID = deviceID
        self.credential = credential
        if let previousSocket { await previousSocket.close() }
        await eventMailbox.discardBufferedEvents()
        guard currentLifecycle == lifecycle else { throw CancellationError() }

        do {
            return try await establishConnection(lifecycle: currentLifecycle, restoreSubscriptions: false)
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

    public func eventStream() async throws -> any SessionEventStream {
        guard !eventStreamClaimed else { throw SessionLinkFailure.eventStreamAlreadyClaimed }
        eventStreamClaimed = true
        return eventMailbox
    }

    public func send(_ command: ClientCommand) async throws -> CommandSendReceipt {
        guard case let .authenticatedReady(currentEpoch) = state,
              let attempt = activeAttempt else {
            throw SessionLinkFailure.unauthenticated
        }
        guard outbound.count < configuration.maximumQueuedMessages else {
            throw SessionLinkTransportError.sendQueueFull
        }
        return try await withCheckedThrowingContinuation { continuation in
            outbound.append(PendingSend(
                command: command,
                attempt: attempt,
                epoch: currentEpoch,
                continuation: continuation
            ))
            startSenderIfNeeded()
        }
    }

    public func disconnect() async {
        lifecycle &+= 1
        let currentLifecycle = lifecycle
        cancelCurrentTasks()
        endpoint = nil
        credential = nil
        activeAttempt = nil
        failQueuedSends(SessionLinkFailure.disconnected)
        let previousSocket = socket
        socket = nil
        if let previousSocket { await previousSocket.close() }
        await eventMailbox.discardBufferedEvents()
        guard currentLifecycle == lifecycle else { return }
        await setState(.disconnected)
    }

    private func establishConnection(
        lifecycle expectedLifecycle: UInt64,
        restoreSubscriptions: Bool
    ) async throws -> AuthenticatedConnection {
        guard expectedLifecycle == lifecycle, let endpoint, let credential, let deviceID else {
            throw CancellationError()
        }
        guard epoch.rawValue < UInt64.max else {
            throw SessionLinkFailure.transport("Connection epoch exhausted")
        }
        nextAttempt &+= 1
        let attempt = nextAttempt
        activeAttempt = attempt
        epoch = ConnectionEpoch(epoch.rawValue + 1)
        let connectionEpoch = epoch
        let candidate = transportFactory(endpoint.url)
        socket = candidate
        await setState(.transportOpen(connectionEpoch))

        do {
            try await candidate.start()
            guard expectedLifecycle == lifecycle, activeAttempt == attempt else { throw CancellationError() }
            await setState(.authenticating(connectionEpoch))
            let auth = try codec.encodeAuthentication(AuthToken(credential.rawValue))
            try await candidate.send(.text(auth.utf8String))
            let response = try await candidate.receive()
            guard case let .text(text) = response else {
                throw SessionLinkFailure.protocolViolation("Expected a text authentication acknowledgement")
            }
            let control: ControlMessage
            do { control = try codec.decodeControlMessage(Data(text.utf8)) }
            catch { throw SessionLinkFailure.protocolViolation("Invalid authentication acknowledgement: \(error)") }
            guard case let .authAck(ok, _, _) = control else {
                throw SessionLinkFailure.protocolViolation("Expected auth_ack before other controls")
            }
            guard ok else { throw SessionLinkFailure.unauthorized }
            guard expectedLifecycle == lifecycle, activeAttempt == attempt else { throw CancellationError() }
            await publish(.control(control))

            if restoreSubscriptions { try await restoreDesiredSubscriptions(on: candidate) }
            guard expectedLifecycle == lifecycle, activeAttempt == attempt else { throw CancellationError() }
            await setState(.authenticatedReady(connectionEpoch))
            let connection = try AuthenticatedConnection(
                linkInstanceID: linkInstanceID,
                deviceID: deviceID,
                connectionEpoch: connectionEpoch
            )
            receiveTask = Task { [weak self] in await self?.receiveLoop(on: candidate, attempt: attempt) }
            heartbeatTask = Task { [weak self] in await self?.heartbeatLoop(on: candidate, attempt: attempt) }
            return connection
        } catch {
            await candidate.close()
            if activeAttempt == attempt {
                activeAttempt = nil
                socket = nil
            }
            throw error
        }
    }

    private func restoreDesiredSubscriptions(on candidate: any WebSocketConnection) async throws {
        let desired = subscriptions.sorted { $0.key.rawValue < $1.key.rawValue }
        for (reference, subscription) in desired {
            guard case let .subscribed(size) = subscription else { continue }
            let bytes = try codec.encodeClientCommand(.subscribe(reference: reference, size: size))
            try await candidate.send(.text(bytes.utf8String))
        }
    }

    private func startSenderIfNeeded() {
        guard inFlight == nil else { return }
        while !outbound.isEmpty {
            let item = outbound.removeFirst()
            guard item.attempt == activeAttempt,
                  item.epoch == epoch,
                  case let .authenticatedReady(readyEpoch) = state,
                  readyEpoch == item.epoch,
                  let candidate = socket else {
                item.continuation.resume(throwing: SessionLinkFailure.disconnected)
                continue
            }

            let bytes: Data
            do { bytes = try codec.encodeClientCommand(item.command) }
            catch {
                item.continuation.resume(throwing: error)
                continue
            }

            inFlight = item
            senderTask = Task { [weak self] in
                do {
                    try await candidate.send(.text(bytes.utf8String))
                    await self?.completeSend(id: item.id, error: nil)
                } catch { await self?.completeSend(id: item.id, error: error) }
            }
            // Do not use a task group: an uncooperative socket operation would
            // keep the group's scope (and every caller) suspended past its deadline.
            sendTimeoutTask = Task { [weak self, configuration] in
                do { try await Task.sleep(nanoseconds: configuration.sendTimeoutNanoseconds) }
                catch { return }
                await self?.completeSend(id: item.id, error: SessionLinkTransportError.sendTimedOut, timedOut: true)
            }
            return
        }
    }

    private func completeSend(id: UUID, error: Error?, timedOut: Bool = false) async {
        // Disconnect owns continuation completion. An old socket's late callback
        // must neither resume it twice nor alter subscriptions in the new epoch.
        guard let item = inFlight, item.id == id else { return }
        inFlight = nil
        if timedOut { senderTask?.cancel() }
        else { sendTimeoutTask?.cancel() }
        senderTask = nil
        sendTimeoutTask = nil
        if let error {
            item.continuation.resume(throwing: inFlightFailure(for: item, error: error))
            await transportFailed(attempt: item.attempt, error: error)
        } else if activeAttempt == item.attempt, epoch == item.epoch {
            updateDesiredSubscription(for: item.command)
            item.continuation.resume(returning: CommandSendReceipt(requestID: requestID(for: item.command), socketWritten: true))
        } else {
            item.continuation.resume(throwing: inFlightFailure(for: item, error: SessionLinkFailure.disconnected))
        }
        startSenderIfNeeded()
    }

    private func inFlightFailure(for item: PendingSend, error: Error) -> Error {
        if case let .input(request) = item.command {
            return SessionLinkFailure.inputOutcomeUnknown(requestID: request.sequence)
        }
        return error
    }

    private func updateDesiredSubscription(for command: ClientCommand) {
        switch command {
        case let .subscribe(reference, size): subscriptions[reference] = .subscribed(size)
        case let .unsubscribe(reference): subscriptions.removeValue(forKey: reference)
        default: break
        }
    }

    private func requestID(for command: ClientCommand) -> UInt32? {
        switch command {
        case let .list(requestID): requestID
        case let .createAgent(request): request.requestID
        case let .closeSession(request): request.requestID
        case let .input(request): request.sequence
        default: nil
        }
    }

    private func receiveLoop(on candidate: any WebSocketConnection, attempt: UInt64) async {
        while !Task.isCancelled, activeAttempt == attempt {
            do {
                try await handleIncoming(try await candidate.receive(), attempt: attempt)
            } catch is CancellationError {
                return
            } catch let failure as SessionLinkFailure {
                if failure == .unauthorized {
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

    private func handleIncoming(_ message: WebSocketMessage, attempt: UInt64) async throws {
        guard activeAttempt == attempt else { return }
        switch message {
        case let .binary(bytes):
            do { try await publish(.frame(codec.decodeBinaryFrame(bytes)), wireByteCount: UInt64(bytes.count)) }
            catch { throw SessionLinkFailure.protocolViolation("Invalid binary frame: \(error)") }
        case let .text(text):
            let bytes = Data(text.utf8)
            let control: ControlMessage
            do { control = try codec.decodeControlMessage(bytes) }
            catch { throw SessionLinkFailure.protocolViolation("Invalid control message: \(error)") }
            if case let .authAck(ok, _, _) = control {
                if !ok { throw SessionLinkFailure.unauthorized }
                throw SessionLinkFailure.protocolViolation("Unexpected auth_ack after authentication")
            }
            await publish(.control(control), wireByteCount: UInt64(bytes.count))
        }
    }

    private func heartbeatLoop(on candidate: any WebSocketConnection, attempt: UInt64) async {
        while !Task.isCancelled, activeAttempt == attempt {
            do { try await Task.sleep(nanoseconds: configuration.heartbeatIntervalNanoseconds) }
            catch { return }
            guard activeAttempt == attempt else { return }
            do { try await candidate.ping() }
            catch {
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
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        receiveTask = nil
        heartbeatTask = nil
        failQueuedSends(SessionLinkFailure.disconnected)
        let failure = sessionFailure(for: error)
        if let previousSocket { await previousSocket.close() }
        guard expectedLifecycle == lifecycle else { return }
        await setState(.disconnected)
        await publish(.failed(failure))
        guard endpoint != nil, credential != nil, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in await self?.reconnectLoop(lifecycle: expectedLifecycle) }
    }

    private func reconnectLoop(lifecycle expectedLifecycle: UInt64) async {
        var delay = configuration.initialReconnectDelayNanoseconds
        while !Task.isCancelled, expectedLifecycle == lifecycle, endpoint != nil {
            do { try await Task.sleep(nanoseconds: delay) }
            catch { break }
            guard expectedLifecycle == lifecycle, endpoint != nil else { break }
            do {
                _ = try await establishConnection(lifecycle: expectedLifecycle, restoreSubscriptions: true)
                reconnectTask = nil
                return
            } catch is CancellationError {
                reconnectTask = nil
                return
            } catch let failure as SessionLinkFailure {
                if failure == .unauthorized {
                    await authenticationFailed(attempt: activeAttempt ?? 0)
                    reconnectTask = nil
                    return
                }
                if case .protocolViolation = failure {
                    await protocolFailed(attempt: activeAttempt ?? 0, failure: failure)
                    reconnectTask = nil
                    return
                }
                await setState(.disconnected)
                await publish(.failed(failure))
            } catch {
                await setState(.disconnected)
                await publish(.failed(sessionFailure(for: error)))
            }
            let doubled = delay.multipliedReportingOverflow(by: 2)
            delay = min(doubled.overflow ? configuration.maximumReconnectDelayNanoseconds : doubled.partialValue,
                        configuration.maximumReconnectDelayNanoseconds)
        }
        if lifecycle == expectedLifecycle { reconnectTask = nil }
    }

    private func authenticationFailed(attempt: UInt64) async {
        guard attempt == 0 || activeAttempt == attempt else { return }
        let expectedLifecycle = lifecycle
        activeAttempt = nil
        endpoint = nil
        credential = nil
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        reconnectTask?.cancel()
        receiveTask = nil
        heartbeatTask = nil
        reconnectTask = nil
        failQueuedSends(SessionLinkFailure.unauthorized)
        let previousSocket = socket
        socket = nil
        if let previousSocket { await previousSocket.close() }
        guard expectedLifecycle == lifecycle else { return }
        await setState(.failed(.unauthorized))
        await publish(.failed(.unauthorized))
    }

    private func protocolFailed(attempt: UInt64, failure: SessionLinkFailure) async {
        guard attempt == 0 || activeAttempt == attempt else { return }
        let expectedLifecycle = lifecycle
        activeAttempt = nil
        endpoint = nil
        credential = nil
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        reconnectTask?.cancel()
        receiveTask = nil
        heartbeatTask = nil
        reconnectTask = nil
        failQueuedSends(failure)
        let previousSocket = socket
        socket = nil
        if let previousSocket { await previousSocket.close() }
        guard expectedLifecycle == lifecycle else { return }
        await setState(.failed(failure))
        await publish(.failed(failure))
    }

    private func cancelCurrentTasks() {
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        reconnectTask?.cancel()
        receiveTask = nil
        heartbeatTask = nil
        reconnectTask = nil
    }

    private func failQueuedSends(_ error: Error) {
        senderTask?.cancel()
        senderTask = nil
        sendTimeoutTask?.cancel()
        sendTimeoutTask = nil
        if let item = inFlight {
            inFlight = nil
            item.continuation.resume(throwing: inFlightFailure(for: item, error: error))
        }
        let pending = outbound
        outbound.removeAll()
        for item in pending { item.continuation.resume(throwing: error) }
    }

    private func setState(_ newState: ConnectionState) async {
        state = newState
        await publish(.connectionChanged(newState))
    }

    private func publish(_ event: SessionEvent, wireByteCount: UInt64 = 0) async {
        guard let deviceID, epoch.rawValue > 0 else { return }
        guard receiveOrdinal < UInt64.max else {
            await eventMailbox.finish(with: .eventBufferOverflow)
            return
        }
        receiveOrdinal += 1
        let origin = SessionEventOrigin(
            linkInstanceID: linkInstanceID,
            deviceID: deviceID,
            connectionEpoch: epoch,
            receiveOrdinal: ReceiveOrdinal(receiveOrdinal)
        )
        guard let envelope = try? SessionEventEnvelope(origin: origin, wireByteCount: wireByteCount, event: event) else { return }
        do {
            switch event {
            case .connectionChanged, .failed:
                // Failure handling can cancel the task that detected it. Its
                // connection-state notification must still reach the consumer.
                try await eventMailbox.enqueue(envelope, cancellable: false)
            default: try await eventMailbox.enqueue(envelope)
            }
        }
        catch is CancellationError { return }
        catch {
            // A single unbufferable event is fatal. Never leave a live socket
            // behind a terminated stream that silently ignores all future output.
            cancelCurrentTasks()
            failQueuedSends(error)
            activeAttempt = nil
            endpoint = nil
            credential = nil
            state = .failed(.eventBufferOverflow)
            let previous = socket
            socket = nil
            await previous?.close()
        }
    }

    private func sessionFailure(for error: Error) -> SessionLinkFailure {
        if let failure = error as? SessionLinkFailure { return failure }
        if error is EndpointSafetyError { return .protocolViolation("Endpoint rejected by ApprovedEndpoint") }
        return .transport(String(describing: error))
    }

    private static func budget(for configuration: Configuration) -> SessionEventStreamBudget {
        SessionEventStreamBudget(
            maximumBufferedBytes: configuration.maximumBufferedBytes,
            maximumBufferedEvents: configuration.maximumBufferedEvents,
            maximumBufferedControls: configuration.maximumBufferedControls
        )
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
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        let session = URLSession(configuration: .ephemeral, delegate: RejectWebSocketRedirects(), delegateQueue: nil)
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
    let budget: SessionEventStreamBudget
    private var buffer: [SessionEventEnvelope] = []
    private var bufferedBytes: UInt64 = 0
    private var bufferedControls: UInt32 = 0
    private var waiter: (id: UUID, continuation: CheckedContinuation<SessionEventEnvelope?, Error>)?
    private struct Producer {
        let id: UUID
        let event: SessionEventEnvelope
        let continuation: CheckedContinuation<Void, Error>
    }
    // The single receiver suspends here instead of reading more WebSocket data.
    // Lifecycle publishers join the same FIFO, preserving receiveOrdinal order.
    private var producers: [Producer] = []
    private var terminalError: SessionLinkFailure?
    private var finished = false

    init(budget: SessionEventStreamBudget) { self.budget = budget }

    private func isControl(_ event: SessionEventEnvelope) -> Bool {
        if case .control = event.event { return true }
        return false
    }

    private func hasCapacity(for event: SessionEventEnvelope) -> Bool {
        buffer.count < budget.maximumBufferedEvents &&
            event.wireByteCount <= budget.maximumBufferedBytes - bufferedBytes &&
            (!isControl(event) || bufferedControls < budget.maximumBufferedControls)
    }

    private func append(_ event: SessionEventEnvelope) {
        buffer.append(event)
        bufferedBytes += event.wireByteCount
        if isControl(event) { bufferedControls += 1 }
    }

    func enqueue(_ event: SessionEventEnvelope, cancellable: Bool = true) async throws {
        if cancellable { try Task.checkCancellation() }
        guard !finished else { throw terminalError ?? SessionLinkFailure.disconnected }
        guard event.wireByteCount <= budget.maximumBufferedBytes else {
            finish(with: .eventBufferOverflow)
            throw SessionLinkFailure.eventBufferOverflow
        }
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: event)
            return
        }
        if producers.isEmpty, hasCapacity(for: event) {
            append(event)
            return
        }
        let id = UUID()
        if !cancellable {
            return try await withCheckedThrowingContinuation { continuation in
                producers.append(Producer(id: id, event: event, continuation: continuation))
            }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { producers.append(Producer(id: id, event: event, continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancelProducer(id) }
        }
    }

    private func admitProducers() {
        while let first = producers.first, hasCapacity(for: first.event) {
            producers.removeFirst()
            append(first.event)
            first.continuation.resume()
        }
    }

    private func cancelProducer(_ id: UUID) {
        guard let index = producers.firstIndex(where: { $0.id == id }) else { return }
        producers.remove(at: index).continuation.resume(throwing: CancellationError())
        admitProducers()
    }

    func next() async throws -> SessionEventEnvelope? {
        try Task.checkCancellation()
        guard waiter == nil else { throw SessionLinkFailure.concurrentEventRead }
        if !buffer.isEmpty {
            let event = buffer.removeFirst()
            bufferedBytes -= event.wireByteCount
            if isControl(event) { bufferedControls -= 1 }
            admitProducers()
            return event
        }
        // A zero control-buffer budget can still deliver a control directly.
        if !producers.isEmpty {
            let first = producers.removeFirst()
            first.continuation.resume()
            return first.event
        }
        if let terminalError { throw terminalError }
        if finished { return nil }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiter = (id, continuation) }
            }
        } onCancel: {
            Task { await self.cancelReader(id) }
        }
    }

    private func cancelReader(_ id: UUID) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Explicit disconnect/connect invalidates the old epoch's queued work.
    /// Release a backpressured receiver even when the consumer has been stopped.
    func discardBufferedEvents() {
        buffer.removeAll()
        bufferedBytes = 0
        bufferedControls = 0
        for producer in producers { producer.continuation.resume(throwing: CancellationError()) }
        producers.removeAll()
    }

    func finish(with error: SessionLinkFailure?) {
        guard !finished else { return }
        finished = true
        terminalError = error
        buffer.removeAll()
        bufferedBytes = 0
        bufferedControls = 0
        for producer in producers { producer.continuation.resume(throwing: error ?? .disconnected) }
        producers.removeAll()
        if let waiter {
            self.waiter = nil
            if let error { waiter.continuation.resume(throwing: error) }
            else { waiter.continuation.resume(returning: nil) }
        }
    }
}

private extension Data {
    var utf8String: String { String(decoding: self, as: UTF8.self) }
}
