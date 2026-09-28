import Foundation

/// Internal API version; deliberately independent of the frozen network wire version.
public enum ContractVersion {
    public static let major = 0
    public static let minor = 1
    public static let string = "0.1"
}

public enum ProtocolV1 {
    public static let magic: [UInt8] = [0x52, 0x41] // "RA"
    public static let version: UInt8 = 0x01
    public static let headerByteCount = 5 // magic(2), version, kind, reference length
    public static let maximumReferenceBytes = 255
    /// Client receive/send policy; measured on ANSI bytes, excluding the scrollback metadata header.
    public static let maximumANSIBytes = 1_048_576
    public static let maximumInputBytes = 1_048_576
    public static let scrollbackMetadataByteCount = 12
}

public enum FrameKind: UInt8, Codable, CaseIterable, Sendable {
    case snapshot = 1
    case delta = 2
    case scrollback = 3
}

public enum ProtocolContractError: Error, Equatable, Sendable {
    case invalidMagic
    case unsupportedVersion(UInt8)
    case unknownFrameKind(UInt8)
    case invalidReference
    case referenceTooLong
    case invalidScrollbackMetadata
    case truncatedFrame
    case payloadTooLarge
    case invalidEnvelope
    case invalidReceiveOrdinal
    case unsupportedCommand
}

/// Opaque, non-empty protocol reference. UTF-8 length—not Character count—is the wire limit.
public struct SessionReference: Hashable, Sendable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let byteCount = rawValue.utf8.count
        guard byteCount > 0 else { throw ProtocolContractError.invalidReference }
        guard byteCount <= ProtocolV1.maximumReferenceBytes else { throw ProtocolContractError.referenceTooLong }
        self.rawValue = rawValue
    }

    private enum CodingKeys: String, CodingKey { case rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(container.decode(String.self, forKey: .rawValue))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }
}

public struct ScrollbackMetadata: Hashable, Sendable, Codable {
    public let requestID: UInt32
    public let fromLine: Int32
    public let lineCount: UInt32

    public init(requestID: UInt32, fromLine: Int32, lineCount: UInt32) throws {
        guard requestID > 0, lineCount > 0 else { throw ProtocolContractError.invalidScrollbackMetadata }
        self.requestID = requestID
        self.fromLine = fromLine
        self.lineCount = lineCount
    }

    private enum CodingKeys: String, CodingKey { case requestID, fromLine, lineCount }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestID: container.decode(UInt32.self, forKey: .requestID),
            fromLine: container.decode(Int32.self, forKey: .fromLine),
            lineCount: container.decode(UInt32.self, forKey: .lineCount)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(fromLine, forKey: .fromLine)
        try container.encode(lineCount, forKey: .lineCount)
    }
}

public enum BinaryFrame: Equatable, Sendable {
    case snapshot(reference: SessionReference, ansi: Data)
    case delta(reference: SessionReference, ansi: Data)
    case scrollback(reference: SessionReference, metadata: ScrollbackMetadata, ansi: Data)

    public var kind: FrameKind {
        switch self {
        case .snapshot: .snapshot
        case .delta: .delta
        case .scrollback: .scrollback
        }
    }

    public var reference: SessionReference {
        switch self {
        case let .snapshot(reference, _), let .delta(reference, _), let .scrollback(reference, _, _): reference
        }
    }

    public var ansi: Data {
        switch self {
        case let .snapshot(_, ansi), let .delta(_, ansi), let .scrollback(_, _, ansi): ansi
        }
    }
}

public struct SessionID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    public let rawValue: String
    public var id: String { rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct LinkInstanceID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// Allocated once by a link and never reused across reconnects; zero means "not connected".
public struct ConnectionEpoch: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let initial = ConnectionEpoch(0)
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Local receive order only; it is never sent over Protocol v1 and is not a network ACK.
public struct ReceiveOrdinal: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case transportOpen(ConnectionEpoch)
    case authenticating(ConnectionEpoch)
    case authenticatedReady(ConnectionEpoch)
    case failed(SessionLinkFailure)
}

public enum SessionLinkFailure: Error, Equatable, Sendable {
    case unauthorized
    case disconnected
    case unauthenticated
    case protocolViolation(String)
    case transport(String)
    case eventStreamAlreadyClaimed
    case concurrentEventRead
    case eventBufferOverflow
    case inputOutcomeUnknown(requestID: UInt32)
}

public enum SessionEvent: Equatable, Sendable {
    case connectionChanged(ConnectionState)
    case frame(BinaryFrame)
    case control(ControlMessage)
    case failed(SessionLinkFailure)
}

public struct AuthenticatedConnection: Equatable, Sendable {
    public let linkInstanceID: LinkInstanceID
    public let deviceID: DeviceID
    public let connectionEpoch: ConnectionEpoch

    public init(linkInstanceID: LinkInstanceID, deviceID: DeviceID, connectionEpoch: ConnectionEpoch) throws {
        guard connectionEpoch.rawValue > 0 else { throw ProtocolContractError.invalidEnvelope }
        self.linkInstanceID = linkInstanceID
        self.deviceID = deviceID
        self.connectionEpoch = connectionEpoch
    }
}

public struct SessionEventOrigin: Equatable, Hashable, Sendable {
    public let linkInstanceID: LinkInstanceID
    public let deviceID: DeviceID
    public let connectionEpoch: ConnectionEpoch
    public let receiveOrdinal: ReceiveOrdinal

    public init(linkInstanceID: LinkInstanceID, deviceID: DeviceID, connectionEpoch: ConnectionEpoch, receiveOrdinal: ReceiveOrdinal) {
        self.linkInstanceID = linkInstanceID
        self.deviceID = deviceID
        self.connectionEpoch = connectionEpoch
        self.receiveOrdinal = receiveOrdinal
    }

    public func belongs(to connection: AuthenticatedConnection) -> Bool {
        linkInstanceID == connection.linkInstanceID && deviceID == connection.deviceID && connectionEpoch == connection.connectionEpoch
    }
}

/// Envelope assigned before asynchronous dispatch. Ordinals are monotonic within one link epoch.
public struct SessionEventEnvelope: Equatable, Sendable {
    public let origin: SessionEventOrigin
    /// Zero for locally generated connection/failure events; event-count budget still accounts for them.
    public let wireByteCount: UInt64
    public let event: SessionEvent

    public init(origin: SessionEventOrigin, wireByteCount: UInt64, event: SessionEvent) throws {
        guard origin.connectionEpoch.rawValue > 0, origin.receiveOrdinal.rawValue > 0 else {
            throw ProtocolContractError.invalidEnvelope
        }
        self.origin = origin
        self.wireByteCount = wireByteCount
        self.event = event
    }
}

public enum WireErrorCode: String, Codable, Sendable {
    case unauthorized
    case badFrame = "bad_frame"
    case unsupportedVersion = "unsupported_version"
    case unsupportedType = "unsupported_type"
    case invalidField = "invalid_field"
    case sessionNotFound = "session_not_found"
    case internalFailure = "internal"
}

public enum InputFailureReason: String, Codable, Sendable {
    case sessionNotFound = "session_not_found"
    case notSubscribed = "not_subscribed"
    case injectFailed = "inject_failed"
    case tooLarge = "too_large"
    case internalFailure = "internal"
}

public enum WireInputKey: String, Codable, CaseIterable, Sendable {
    case escape = "esc"
    case controlC = "ctrl_c"
    case tab
    case up
    case down
    case left
    case right
    case backspace
}

public enum ClientInputPayload: Equatable, Sendable {
    case text(String, attachmentPath: String?)
    case keys([WireInputKey])
    case bytes(Data)
    case bareEnter
}

public struct ClientInputRequest: Equatable, Sendable {
    public let sequence: UInt32
    public let reference: SessionReference
    public let payload: ClientInputPayload

    public init(sequence: UInt32, reference: SessionReference, payload: ClientInputPayload) throws {
        guard sequence > 0 else { throw ProtocolContractError.invalidEnvelope }
        if case let .keys(keys) = payload, keys.isEmpty { throw ProtocolContractError.invalidEnvelope }
        if case let .text(_, path) = payload, path == "" { throw ProtocolContractError.invalidEnvelope }
        if case let .bytes(bytes) = payload, bytes.isEmpty || bytes.count > ProtocolV1.maximumInputBytes {
            throw ProtocolContractError.invalidEnvelope
        }
        self.sequence = sequence
        self.reference = reference
        self.payload = payload
    }
}

public struct AuthToken: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { "<redacted>" }
}

public enum AgentNamingMode: String, Codable, Sendable {
    case cli
    case tmux
}

public struct AgentLauncher: Codable, Equatable, Sendable {
    public let provider: String
    public let displayName: String
    public let supportsBypass: Bool
    public let naming: AgentNamingMode

    public init(provider: String, displayName: String, supportsBypass: Bool, naming: AgentNamingMode) {
        self.provider = provider
        self.displayName = displayName
        self.supportsBypass = supportsBypass
        self.naming = naming
    }

    enum CodingKeys: String, CodingKey {
        case provider, naming
        case displayName = "display_name"
        case supportsBypass = "supports_bypass"
    }
}

public struct CreateAgentRequest: Equatable, Sendable {
    public let requestID: UInt32
    public let workspace: String
    public let anchorReference: SessionReference?
    public let provider: String
    public let name: String
    public let bypass: Bool

    public init(requestID: UInt32, workspace: String, anchorReference: SessionReference?, provider: String, name: String, bypass: Bool) {
        self.requestID = requestID
        self.workspace = workspace
        self.anchorReference = anchorReference
        self.provider = provider
        self.name = name
        self.bypass = bypass
    }
}

public struct CloseSessionRequest: Equatable, Sendable {
    public let requestID: UInt32
    public let reference: SessionReference

    public init(requestID: UInt32, reference: SessionReference) {
        self.requestID = requestID
        self.reference = reference
    }
}

public enum CreateAgentFailureReason: String, Codable, Sendable {
    case invalidField = "invalid_field"
    case targetNotFound = "target_not_found"
    case providerUnavailable = "provider_unavailable"
    case unsupportedBypass = "unsupported_bypass"
    case launchFailed = "launch_failed"
}

public struct CreateAgentResult: Codable, Equatable, Sendable {
    public let requestID: UInt32
    public let ok: Bool
    public let reference: SessionReference?
    public let name: String?
    public let naming: AgentNamingMode?
    public let reason: CreateAgentFailureReason?

    public init(requestID: UInt32, ok: Bool, reference: SessionReference? = nil, name: String? = nil, naming: AgentNamingMode? = nil, reason: CreateAgentFailureReason? = nil) {
        self.requestID = requestID
        self.ok = ok
        self.reference = reference
        self.name = name
        self.naming = naming
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case requestID = "req_id", ok, reference = "ref", name, naming, reason }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try values.decode(UInt32.self, forKey: .requestID)
        ok = try values.decode(Bool.self, forKey: .ok)
        reference = try values.decodeIfPresent(String.self, forKey: .reference).map(SessionReference.init)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        naming = try values.decodeIfPresent(AgentNamingMode.self, forKey: .naming)
        reason = try values.decodeIfPresent(CreateAgentFailureReason.self, forKey: .reason)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(requestID, forKey: .requestID)
        try values.encode(ok, forKey: .ok)
        try values.encodeIfPresent(reference?.rawValue, forKey: .reference)
        try values.encodeIfPresent(name, forKey: .name)
        try values.encodeIfPresent(naming, forKey: .naming)
        try values.encodeIfPresent(reason, forKey: .reason)
    }
}

public enum CloseSessionFailureReason: String, Codable, Sendable {
    case sessionNotFound = "session_not_found"
    case closeFailed = "close_failed"
}

public struct CloseSessionResult: Codable, Equatable, Sendable {
    public let requestID: UInt32
    public let ok: Bool
    public let reason: CloseSessionFailureReason?

    public init(requestID: UInt32, ok: Bool, reason: CloseSessionFailureReason? = nil) {
        self.requestID = requestID
        self.ok = ok
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case requestID = "req_id", ok, reason }
}

public struct AgentMirrorWhoAmIResponse: Codable, Equatable, Sendable {
    public let version: UInt16
    public let hostID: String
    public let name: String
    public let port: UInt16
    public let addresses: [String]

    public init(version: UInt16 = 1, hostID: String, name: String, port: UInt16, addresses: [String]) {
        self.version = version
        self.hostID = hostID
        self.name = name
        self.port = port
        self.addresses = addresses
    }

    enum CodingKeys: String, CodingKey { case version = "v", hostID = "host_id", name, port, addresses }
}

public struct AgentMirrorIdentifyRequest: Codable, Equatable, Sendable {
    public let version: UInt16
    public let hostID: String?
    public let nonce: String
    public let destinationIP: String

    public init(version: UInt16 = 1, hostID: String? = nil, nonce: String, destinationIP: String) {
        self.version = version
        self.hostID = hostID
        self.nonce = nonce
        self.destinationIP = destinationIP
    }

    enum CodingKeys: String, CodingKey { case version = "v", hostID = "host_id", nonce, destinationIP = "dest_ip" }
}

public struct AgentMirrorIdentifyResponse: Codable, Equatable, Sendable {
    public let version: UInt16
    public let hostID: String
    public let name: String
    public let bound: String
    public let mac: String

    public init(version: UInt16 = 1, hostID: String, name: String, bound: String, mac: String) {
        self.version = version
        self.hostID = hostID
        self.name = name
        self.bound = bound
        self.mac = mac
    }

    enum CodingKeys: String, CodingKey { case version = "v", hostID = "host_id", name, bound, mac }
}

public struct AgentMirrorHTTPError: Codable, Equatable, Sendable {
    public let code: String
    public let reason: String?
    public init(code: String, reason: String? = nil) { self.code = code; self.reason = reason }
}

/// Multipart body input for POST /upload; the HTTP field name is intentionally unspecified by the server.
public struct AgentMirrorUploadRequest: Equatable, Sendable {
    public let fileName: String
    public let bytes: Data
    public init(fileName: String, bytes: Data) { self.fileName = fileName; self.bytes = bytes }
}

public struct AgentMirrorUploadResponse: Codable, Equatable, Sendable {
    public let path: String
    public init(path: String) { self.path = path }
}

/// Client-to-server commands only. Server responses cannot be passed to a sender.
public enum ClientCommand: Equatable, Sendable {
    case list(requestID: UInt32)
    case subscribe(reference: SessionReference, size: GridSize?)
    case unsubscribe(reference: SessionReference)
    case input(ClientInputRequest)
    case scrollback(reference: SessionReference, metadata: ScrollbackMetadata)
    case resize(reference: SessionReference, size: GridSize)
    case attachPreview(reference: SessionReference, path: String)
    case scrollWheel(reference: SessionReference, delta: Int32)
    case level2Subscribe(workspace: String)
    case level2Unsubscribe(workspace: String?)
    case overlaySubscribe(socket: String, rows: UInt16?, columns: UInt16?)
    case overlayUnsubscribe
    case createAgent(CreateAgentRequest)
    case closeSession(CloseSessionRequest)
}

/// Server-to-client control messages only; these cases are decodable, never sendable by SessionLink.
public enum ControlMessage: Equatable, Sendable {
    case authAck(ok: Bool, reason: String?, launchers: [AgentLauncher] = [])
    case listing(SessionListing)
    case listDelta(SessionListDelta)
    case inputAck(seq: UInt32, ok: Bool, reason: InputFailureReason?)
    case createAgentResult(CreateAgentResult)
    case closeSessionResult(CloseSessionResult)
    case presenceUpdate(reference: SessionReference, hasMobile: Bool, mobileCount: UInt32, desktopCount: UInt32)
    case level2Frame(workspace: String, sequence: UInt64, sessions: [WireSessionRecord])
    case level2Heartbeat(workspace: String, sequence: UInt64)
    case overlayFrame(sequence: UInt64, text: String, rows: UInt16, columns: UInt16)
    case error(code: WireErrorCode, reason: String?)
    case paneModeChanged(reference: SessionReference, inCopyMode: Bool)
}

public struct CommandSendReceipt: Equatable, Sendable {
    public let requestID: UInt32?
    /// `send` returns only after the single FIFO sender has completed the socket write.
    public let socketWritten: Bool

    public init(requestID: UInt32?, socketWritten: Bool) {
        self.requestID = requestID
        self.socketWritten = socketWritten
    }
}

public struct SessionEventStreamBudget: Codable, Hashable, Sendable {
    public let maximumBufferedBytes: UInt64
    public let maximumBufferedEvents: UInt32
    public let maximumBufferedControls: UInt32

    public init(maximumBufferedBytes: UInt64, maximumBufferedEvents: UInt32, maximumBufferedControls: UInt32) {
        self.maximumBufferedBytes = maximumBufferedBytes
        self.maximumBufferedEvents = maximumBufferedEvents
        self.maximumBufferedControls = maximumBufferedControls
    }

    public var isValid: Bool {
        maximumBufferedBytes > 0 && maximumBufferedEvents > 0 && maximumBufferedControls <= maximumBufferedEvents
    }
}

/// Exactly one consumer and at most one outstanding `next` call. Implementations must backpressure
/// by byte budget or terminate with `eventBufferOverflow`; dropping ANSI frames is forbidden.
public protocol SessionEventStream: Sendable {
    var budget: SessionEventStreamBudget { get async }
    func next() async throws -> SessionEventEnvelope?
}

public protocol BinaryFrameCodecProtocol: Sendable {
    func encodeBinaryFrame(_ frame: BinaryFrame) throws -> Data
    func decodeBinaryFrame(_ bytes: Data) throws -> BinaryFrame
}

public protocol V1ControlCodecProtocol: Sendable {
    func encodeAuthentication(_ token: AuthToken) throws -> Data
    func encodeClientCommand(_ command: ClientCommand) throws -> Data
    func decodeControlMessage(_ bytes: Data) throws -> ControlMessage
}

public protocol WireCodecProtocol: BinaryFrameCodecProtocol, V1ControlCodecProtocol {}

/// Connect completes only after `auth_ack{ok:true}`. A link owns one receiver and one FIFO sender;
/// old-epoch work is rejected and side-effecting commands are never automatically replayed.
public protocol SessionLinkProtocol: Sendable {
    func connect(to endpoint: ApprovedEndpoint, deviceID: DeviceID, credential: CredentialHandle) async throws -> AuthenticatedConnection
    /// Claims the one event consumer; a second claim must fail explicitly.
    func eventStream() async throws -> any SessionEventStream
    func send(_ command: ClientCommand) async throws -> CommandSendReceipt
    func disconnect() async
}
