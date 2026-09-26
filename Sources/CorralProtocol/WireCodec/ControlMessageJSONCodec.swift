import CorralContracts
import Foundation

extension BinaryV1Codec {
    public func encodeControlMessage(_ message: ControlMessage) throws -> Data {
        let envelope: ControlEnvelope
        switch message {
        case let .auth(credential):
            envelope = ControlEnvelope(type: "auth", token: credential.rawValue)
        case let .authAck(accepted):
            envelope = ControlEnvelope(type: "auth_ack", success: accepted)
        case let .subscribe(sessionID, initialSize):
            envelope = ControlEnvelope(
                type: "subscribe",
                sessionID: sessionID.rawValue,
                cols: initialSize?.columns,
                rows: initialSize?.rows
            )
        case let .unsubscribe(sessionID):
            envelope = ControlEnvelope(type: "unsubscribe", sessionID: sessionID.rawValue)
        case let .input(sessionID, bytes):
            envelope = ControlEnvelope(type: "input", sessionID: sessionID.rawValue, data: bytes.data.base64EncodedString())
        case let .resize(sessionID, size):
            envelope = ControlEnvelope(type: "resize", sessionID: sessionID.rawValue, cols: size.columns, rows: size.rows)
        case let .ping(nonce):
            envelope = ControlEnvelope(type: "ping", nonce: nonce == 0 ? nil : nonce)
        case let .pong(nonce):
            envelope = ControlEnvelope(type: "pong", nonce: nonce == 0 ? nil : nonce)
        case let .sessionList(requestID):
            envelope = ControlEnvelope(type: "list", requestID: requestID == 0 ? nil : requestID)
        case let .sessionListResult(requestID, sessions):
            envelope = ControlEnvelope(
                type: "listing",
                requestID: requestID == 0 ? nil : requestID,
                sessions: sessions.map(SessionEnvelope.init)
            )
        case let .createSession(requestID, deviceID, name, workingDirectory):
            envelope = ControlEnvelope(
                type: "create_session",
                requestID: requestID,
                deviceID: deviceID.rawValue,
                name: name,
                workingDirectory: workingDirectory
            )
        case let .createSessionResult(requestID, session):
            envelope = ControlEnvelope(
                type: "create_session_result",
                requestID: requestID,
                session: session.map(SessionEnvelope.init)
            )
        case let .failure(code, message):
            envelope = ControlEnvelope(type: "failure", code: code, message: message)
        }
        return try JSONEncoder().encode(envelope)
    }

    public func decodeControlMessage(from data: Data) throws -> ControlMessage {
        let envelope = try JSONDecoder().decode(ControlEnvelope.self, from: data)
        switch envelope.type {
        case "auth":
            return .auth(credential: CredentialHandle(try envelope.required(envelope.token, "token")))
        case "auth_ack":
            return .authAck(accepted: try envelope.required(envelope.success, "success"))
        case "subscribe":
            let sessionID = SessionID(try envelope.required(envelope.sessionID, "session_id"))
            switch (envelope.cols, envelope.rows) {
            case (nil, nil): return .subscribe(sessionID: sessionID, initialSize: nil)
            case let (.some(columns), .some(rows)):
                return .subscribe(sessionID: sessionID, initialSize: GridSize(rows: rows, columns: columns))
            default: throw envelope.malformed("subscribe requires both cols and rows")
            }
        case "unsubscribe":
            return .unsubscribe(sessionID: SessionID(try envelope.required(envelope.sessionID, "session_id")))
        case "input":
            let sessionID = SessionID(try envelope.required(envelope.sessionID, "session_id"))
            let encoded = try envelope.required(envelope.data, "data")
            guard let bytes = Data(base64Encoded: encoded) else { throw envelope.malformed("data must be base64") }
            return .input(sessionID: sessionID, bytes: UserInputBytes(bytes))
        case "resize":
            return .resize(
                sessionID: SessionID(try envelope.required(envelope.sessionID, "session_id")),
                size: GridSize(
                    rows: try envelope.required(envelope.rows, "rows"),
                    columns: try envelope.required(envelope.cols, "cols")
                )
            )
        case "ping": return .ping(nonce: envelope.nonce ?? 0)
        case "pong": return .pong(nonce: envelope.nonce ?? 0)
        case "list": return .sessionList(requestID: envelope.requestID ?? 0)
        case "listing":
            let sessions = try envelope.required(envelope.sessions, "sessions").map { try $0.model() }
            return .sessionListResult(requestID: envelope.requestID ?? 0, sessions: sessions)
        case "create_session":
            return .createSession(
                requestID: try envelope.required(envelope.requestID, "request_id"),
                deviceID: DeviceID(try envelope.required(envelope.deviceID, "device_id")),
                name: try envelope.required(envelope.name, "name"),
                workingDirectory: envelope.workingDirectory
            )
        case "create_session_result":
            return .createSessionResult(requestID: try envelope.required(envelope.requestID, "request_id"), session: try envelope.session?.model())
        case "failure":
            return .failure(code: try envelope.required(envelope.code, "code"), message: try envelope.required(envelope.message, "message"))
        default:
            throw envelope.malformed("unknown control message type: \(envelope.type)")
        }
    }
}

private struct ControlEnvelope: Codable {
    let type: String
    var token: String?
    var success: Bool?
    var sessionID: String?
    var data: String?
    var cols: Int?
    var rows: Int?
    var nonce: UInt64?
    var requestID: UInt64?
    var sessions: [SessionEnvelope]?
    var deviceID: String?
    var name: String?
    var workingDirectory: String?
    var session: SessionEnvelope?
    var code: String?
    var message: String?

    init(
        type: String,
        token: String? = nil,
        success: Bool? = nil,
        sessionID: String? = nil,
        data: String? = nil,
        cols: Int? = nil,
        rows: Int? = nil,
        nonce: UInt64? = nil,
        requestID: UInt64? = nil,
        sessions: [SessionEnvelope]? = nil,
        deviceID: String? = nil,
        name: String? = nil,
        workingDirectory: String? = nil,
        session: SessionEnvelope? = nil,
        code: String? = nil,
        message: String? = nil
    ) {
        self.type = type
        self.token = token
        self.success = success
        self.sessionID = sessionID
        self.data = data
        self.cols = cols
        self.rows = rows
        self.nonce = nonce
        self.requestID = requestID
        self.sessions = sessions
        self.deviceID = deviceID
        self.name = name
        self.workingDirectory = workingDirectory
        self.session = session
        self.code = code
        self.message = message
    }

    func required<T>(_ value: T?, _ key: String) throws -> T {
        guard let value else { throw malformed("missing required field: \(key)") }
        return value
    }

    func malformed(_ message: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: message))
    }

    enum CodingKeys: String, CodingKey {
        case type, token, success, data, cols, rows, nonce, sessions, name, session, code, message
        case sessionID = "session_id"
        case requestID = "request_id"
        case deviceID = "device_id"
        case workingDirectory = "working_directory"
    }
}

private struct SessionEnvelope: Codable {
    let id: String
    let deviceID: String
    let name: String
    var workingDirectory: String?
    var state: String

    init(_ session: SessionDescriptor) {
        id = session.id.rawValue
        deviceID = session.deviceID.rawValue
        name = session.name
        workingDirectory = session.workingDirectory
        state = session.state.rawValue
    }

    func model() throws -> SessionDescriptor {
        guard let state = SessionLifecycleState(rawValue: state) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown session state: \(state)"))
        }
        return SessionDescriptor(
            id: SessionID(id),
            deviceID: DeviceID(deviceID),
            name: name,
            workingDirectory: workingDirectory,
            state: state
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, name, state
        case deviceID = "device_id"
        case workingDirectory = "working_directory"
    }
}

