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
        /// A route that silently stops carrying packets never fails a ping; no pong by then means it is gone.
        var heartbeatTimeoutNanoseconds: UInt64 = 10_000_000_000
        var initialReconnectDelayNanoseconds: UInt64 = 250_000_000
        var maximumReconnectDelayNanoseconds: UInt64 = 5_000_000_000
        /// Happy-eyeballs head start of a preferred route before the next one joins the race.
        var routeStaggerNanoseconds: UInt64 = 1_000_000_000
        /// A route that has not authenticated by then is abandoned (URLSession would wait 60s).
        var routeAttemptTimeoutNanoseconds: UInt64 = 8_000_000_000
        /// Proves a paired route reaches its host (`/pair/identify`, an HMAC under the token that never
        /// reveals it) before the token goes over WebSocket. Loopback and unpaired routes skip it.
        var routeVerifier: @Sendable (ApprovedEndpoint, String) async throws -> Void = { route, token in
            guard let hostID = route.pairingHostID, route.route != .loopback else { return }
            do { try await HostIdentityProbe().verify(route, hostID: hostID, token: token) }
            catch HostIdentityError.proofRejected { throw SessionLinkFailure.unauthorized }
        }

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
    /// Every route to the connected host, in dial order; empty when no connection is wanted.
    private var routes: [ApprovedEndpoint] = []
    private var connectedRoute: ApprovedEndpoint?
    private var handshakeTask: Task<RouteHandshake, Error>?
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
        precondition(configuration.routeAttemptTimeoutNanoseconds > 0)
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
        try await connect(toAnyOf: [endpoint], deviceID: deviceID, credential: credential)
    }

    public func connect(
        toAnyOf routes: [ApprovedEndpoint],
        deviceID: DeviceID,
        credential: CredentialHandle
    ) async throws -> AuthenticatedConnection {
        let approved = try Self.approvedRoutes(routes)
        lifecycle &+= 1
        let currentLifecycle = lifecycle
        cancelCurrentTasks()
        failQueuedSends(SessionLinkFailure.disconnected)
        let previousSocket = socket
        socket = nil
        activeAttempt = nil
        subscriptions.removeAll()
        self.routes = approved
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
            self.routes = []
            self.credential = nil
            await setState(.failed(failure))
            await publish(.failed(failure))
            throw error
        }
    }

    /// Routes of another host are refused: a late update must never pair one device's token with
    /// another host's addresses.
    public func updateRoutes(_ routes: [ApprovedEndpoint]) async {
        guard let hostID = self.routes.first?.pairingHostID, self.routes.allSatisfy({ $0.pairingHostID == hostID }),
              let approved = try? Self.approvedRoutes(routes), approved.allSatisfy({ $0.pairingHostID == hostID }) else { return }
        self.routes = approved
    }

    public func activeEndpoint() async -> ApprovedEndpoint? {
        guard case .authenticatedReady = state else { return nil }
        return connectedRoute
    }

    private static func approvedRoutes(_ routes: [ApprovedEndpoint]) throws -> [ApprovedEndpoint] {
        var seen = Set<URL>()
        let approved = try routes.map { try $0.revalidated() }.filter { seen.insert($0.url).inserted }
        guard !approved.isEmpty else { throw EndpointSafetyError.invalidEndpoint }
        return approved
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
        routes = []
        connectedRoute = nil
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
        guard expectedLifecycle == lifecycle, !routes.isEmpty, let credential, let deviceID else {
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
        await setState(.transportOpen(connectionEpoch))
        await setState(.authenticating(connectionEpoch))

        let race = Task { [routes, codec, transportFactory, configuration] in
            try await Self.raceRoutes(routes, token: credential.rawValue, codec: codec,
                                      transportFactory: transportFactory, configuration: configuration)
        }
        handshakeTask = race
        let winner: RouteHandshake
        do {
            winner = try await withTaskCancellationHandler { try await race.value } onCancel: { race.cancel() }
        } catch {
            if handshakeTask == race { handshakeTask = nil }
            if activeAttempt == attempt { activeAttempt = nil }
            throw error
        }
        if handshakeTask == race { handshakeTask = nil }
        let candidate = winner.socket
        do {
            guard expectedLifecycle == lifecycle, activeAttempt == attempt else { throw CancellationError() }
            socket = candidate
            connectedRoute = winner.route
            await publish(.control(winner.control))

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
                connectedRoute = nil
            }
            throw error
        }
    }

    struct RouteHandshake: Sendable {
        let route: ApprovedEndpoint
        let socket: any WebSocketConnection
        let control: ControlMessage
    }

    private enum RouteRaceEvent: Sendable {
        case authenticated(RouteHandshake)
        case staggerElapsed(launched: Int)
    }

    /// Happy eyeballs over one host's routes: the preferred route starts alone, the next joins after
    /// `routeStaggerNanoseconds` or as soon as a running route fails; the first authenticated route wins.
    private static func raceRoutes(
        _ routes: [ApprovedEndpoint],
        token: String,
        codec: any WireCodecProtocol,
        transportFactory: @escaping @Sendable (URL) -> any WebSocketConnection,
        configuration: Configuration
    ) async throws -> RouteHandshake {
        try await withThrowingTaskGroup(of: RouteRaceEvent.self) { group in
            var launched = 0
            var failures: [Error] = []
            func launchNext() {
                let route = routes[launched]
                launched += 1
                group.addTask {
                    .authenticated(try await handshake(route, token: token, codec: codec, transportFactory: transportFactory,
                                                       verifier: configuration.routeVerifier, timeout: configuration.routeAttemptTimeoutNanoseconds))
                }
                guard launched < routes.count else { return }
                let generation = launched
                group.addTask {
                    try await Task.sleep(nanoseconds: configuration.routeStaggerNanoseconds)
                    return .staggerElapsed(launched: generation)
                }
            }
            /// Every exit cancels the rest and closes any route that authenticated meanwhile.
            func closeStragglers() async {
                group.cancelAll()
                while let late = await group.nextResult() {
                    if case let .success(.authenticated(extra)) = late { await extra.socket.close() }
                }
            }
            launchNext()
            while let result = await group.nextResult() {
                switch result {
                case let .success(.authenticated(winner)):
                    await closeStragglers()
                    return winner
                case let .success(.staggerElapsed(generation)):
                    if generation == launched, launched < routes.count { launchNext() }
                case let .failure(error):
                    if Task.isCancelled { await closeStragglers(); throw CancellationError() }
                    failures.append(error)
                    if launched < routes.count { launchNext() }
                    else if failures.count >= routes.count { await closeStragglers(); throw preferredFailure(failures) }
                }
            }
            throw Task.isCancelled ? CancellationError() : preferredFailure(failures)
        }
    }

    /// A route's rejection speaks for the host only when every route agrees; an unreachable route
    /// (Wi-Fi gone, Tailscale down) keeps the failure retryable.
    private static func preferredFailure(_ failures: [Error]) -> Error {
        func isTerminal(_ error: Error) -> Bool {
            guard let failure = error as? SessionLinkFailure else { return false }
            if case .protocolViolation = failure { return true }
            return failure == .unauthorized
        }
        return failures.first { !isTerminal($0) } ?? failures.first ?? SessionLinkFailure.disconnected
    }

    /// Proof first, then the WebSocket: the token is only ever sent to a route that proved its host.
    private static func handshake(
        _ route: ApprovedEndpoint,
        token: String,
        codec: any WireCodecProtocol,
        transportFactory: @escaping @Sendable (URL) -> any WebSocketConnection,
        verifier: @escaping @Sendable (ApprovedEndpoint, String) async throws -> Void,
        timeout: UInt64
    ) async throws -> RouteHandshake {
        let opened = OpenedSocket()
        do {
            let (socket, control) = try await withThrowingTaskGroup(of: (any WebSocketConnection, ControlMessage)?.self) { group in
                group.addTask {
                    try await verifier(route, token)
                    try Task.checkCancellation()
                    let socket = transportFactory(route.url)
                    opened.socket = socket
                    // An uncooperative socket only unblocks when closed.
                    let control = try await withTaskCancellationHandler {
                        try await authenticate(on: socket, token: token, codec: codec)
                    } onCancel: { Task { await socket.close() } }
                    return (socket, control)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeout)
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let handshake = first else {
                    throw SessionLinkFailure.transport("Route \(route.host) did not authenticate in time")
                }
                return handshake
            }
            return RouteHandshake(route: route, socket: socket, control: control)
        } catch {
            await opened.socket?.close()
            throw error
        }
    }

    private static func authenticate(
        on socket: any WebSocketConnection,
        token: String,
        codec: any WireCodecProtocol
    ) async throws -> ControlMessage {
        try await socket.start()
        try Task.checkCancellation()
        let auth = try codec.encodeAuthentication(AuthToken(token))
        try await socket.send(.text(auth.utf8String))
        let response = try await socket.receive()
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
        return control
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
            if let error = await Self.ping(candidate, within: configuration.heartbeatTimeoutNanoseconds) {
                await transportFailed(attempt: attempt, error: error)
                return
            }
        }
    }

    /// The pong or the deadline, whichever comes first. A ping on a dead route may never complete;
    /// it is left to unwind when `transportFailed` closes the socket.
    private static func ping(_ socket: any WebSocketConnection, within timeout: UInt64) async -> Error? {
        let outcome = PingOutcome()
        return await withCheckedContinuation { continuation in
            outcome.continuation = continuation
            Task {
                do { try await socket.ping(); outcome.resolve(nil) }
                catch { outcome.resolve(error) }
            }
            Task {
                try? await Task.sleep(nanoseconds: timeout)
                outcome.resolve(SessionLinkFailure.transport("Heartbeat timed out"))
            }
        }
    }

    private func transportFailed(attempt: UInt64, error: Error) async {
        guard activeAttempt == attempt else { return }
        let expectedLifecycle = lifecycle
        activeAttempt = nil
        let previousSocket = socket
        socket = nil
        connectedRoute = nil
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
        guard !routes.isEmpty, credential != nil, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in await self?.reconnectLoop(lifecycle: expectedLifecycle) }
    }

    private func reconnectLoop(lifecycle expectedLifecycle: UInt64) async {
        var delay = configuration.initialReconnectDelayNanoseconds
        while !Task.isCancelled, expectedLifecycle == lifecycle, !routes.isEmpty {
            do { try await Task.sleep(nanoseconds: delay) }
            catch { break }
            guard expectedLifecycle == lifecycle, !routes.isEmpty else { break }
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
        routes = []
        connectedRoute = nil
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
        routes = []
        connectedRoute = nil
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
        handshakeTask?.cancel()
        handshakeTask = nil
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
            routes = []
            connectedRoute = nil
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

private final class OpenedSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (any WebSocketConnection)?
    var socket: (any WebSocketConnection)? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class PingOutcome: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<Error?, Never>?

    func resolve(_ error: Error?) {
        let pending: CheckedContinuation<Error?, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: error)
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
