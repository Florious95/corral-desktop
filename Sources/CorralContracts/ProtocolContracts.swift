import Foundation

public enum ContractVersion {
    public static let current = 0
}

public enum ProtocolV1 {
    public static let magic: [UInt8] = [0x52, 0x41] // "RA"
    public static let version: UInt8 = 0x01
    public static let headerByteCount = 5 // magic(2), version, kind, reference length
    public static let maximumReferenceBytes = 255
    public static let maximumTerminalPayloadBytes = 1_048_576
}

public enum FrameKind: UInt8, Codable, CaseIterable, Sendable {
    case snapshot = 1
    case delta = 2
    case scrollback = 3
}

public struct BinaryFrame: Codable, Equatable, Sendable {
    public let kind: FrameKind
    public let reference: String
    public let payload: Data

    public init(kind: FrameKind, reference: String, payload: Data) {
        self.kind = kind
        self.reference = reference
        self.payload = payload
    }
}

public enum ProtocolContractError: Error, Equatable, Sendable {
    case invalidMagic
    case unsupportedVersion(UInt8)
    case unknownFrameKind(UInt8)
    case invalidReference
    case referenceTooLong
    case payloadTooLarge
    case truncatedFrame
}

public struct SessionID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    public let rawValue: String
    public var id: String { rawValue }

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ConnectionEpoch: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let initial = ConnectionEpoch(0)
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ConnectionState: Codable, Equatable, Sendable {
    case disconnected
    case connecting
    case connected(ConnectionEpoch)
    case failed(SessionLinkFailure)
}

public enum SessionLinkFailure: Error, Codable, Equatable, Sendable {
    case unauthorized
    case disconnected
    case protocolViolation(String)
    case transport(String)
    case eventBufferOverflow
}

/// User-originated terminal bytes have a distinct type; engine-generated replies cannot be passed as input.
public struct UserInputBytes: Codable, Hashable, Sendable {
    public let data: Data
    public init(_ data: Data) { self.data = data }
}

public enum ControlMessage: Codable, Equatable, Sendable {
    case auth(credential: CredentialHandle)
    case authAck(accepted: Bool)
    case subscribe(sessionID: SessionID, initialSize: GridSize?)
    case unsubscribe(sessionID: SessionID)
    case input(sessionID: SessionID, bytes: UserInputBytes)
    case resize(sessionID: SessionID, size: GridSize)
    case ping(nonce: UInt64)
    case pong(nonce: UInt64)
    case sessionList(requestID: UInt64)
    case sessionListResult(requestID: UInt64, sessions: [SessionDescriptor])
    case createSession(requestID: UInt64, deviceID: DeviceID, name: String, workingDirectory: String?)
    case createSessionResult(requestID: UInt64, session: SessionDescriptor?)
    case failure(code: String, message: String)
}

public enum SessionEvent: Codable, Equatable, Sendable {
    case connectionChanged(ConnectionState)
    case frame(BinaryFrame)
    case control(ControlMessage)
    case failed(SessionLinkFailure)
}

/// Pull-based to allow bounded buffering/backpressure without silently discarding terminal frames.
public protocol SessionEventStream: Sendable {
    func next() async throws -> SessionEvent?
}

public protocol WireCodecProtocol: Sendable {
    func encodeBinaryFrame(_ frame: BinaryFrame) throws -> Data
    func decodeBinaryFrame(_ bytes: Data) throws -> BinaryFrame
}

public protocol SessionLinkProtocol: Sendable {
    func connect(to endpoint: ApprovedEndpoint, credential: CredentialHandle) async throws
    func eventStream() async -> any SessionEventStream
    func send(_ message: ControlMessage) async throws
    func disconnect() async
}
