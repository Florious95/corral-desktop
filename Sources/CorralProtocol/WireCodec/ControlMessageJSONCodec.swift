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
        if let version = envelope.version, version != 1 {
            throw envelope.malformed("unsupported control envelope version: \(version)")
        }
        switch envelope.type {
        case "auth":
            return .auth(credential: CredentialHandle(try envelope.required(envelope.token, "token")))
        case "auth_ack":
            return .authAck(accepted: try envelope.required(envelope.success ?? envelope.payload?.ok, "success/payload.ok"))
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
            let wireSessions: [SessionEnvelope]?
            if let sessions = envelope.sessions {
                wireSessions = sessions
            } else if let workspaces = envelope.payload?.workspaces {
                wireSessions = try workspaces.flatMap { try envelope.required($0.sessions, "workspace.sessions") }
            } else {
                wireSessions = nil
            }
            let sessions = try envelope.required(wireSessions, "sessions/workspaces").map { try $0.model() }
            return .sessionListResult(requestID: envelope.requestID ?? envelope.payload?.requestID ?? 0, sessions: sessions)
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
    var version: Int?
    var payload: ControlPayload?
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
        version: Int? = nil,
        payload: ControlPayload? = nil,
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
        self.version = version
        self.payload = payload
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
        case type, payload, token, success, data, cols, rows, nonce, sessions, name, session, code, message
        case version = "v"
        case sessionID = "session_id"
        case requestID = "request_id"
        case deviceID = "device_id"
        case workingDirectory = "working_directory"
    }
}

private struct ControlPayload: Codable {
    var ok: Bool?
    var requestID: UInt64?
    var sequence: UInt64?
    var workspaces: [WorkspaceEnvelope]?

    enum CodingKeys: String, CodingKey {
        case ok, workspaces
        case requestID = "req_id"
        case sequence = "seq"
    }
}

private struct WorkspaceEnvelope: Codable {
    var cwd: String?
    var sessionCount: Int?
    var aggregateState: String?
    var sessions: [SessionEnvelope]?

    enum CodingKeys: String, CodingKey {
        case cwd, sessions
        case sessionCount = "session_count"
        case aggregateState = "aggregate_state"
    }
}

private struct SessionEnvelope: Codable {
    var id: String?
    var ref: String?
    var deviceID: String?
    var name: String?
    var workingDirectory: String?
    var cwd: String?
    var state: String?
    var rows: Int?
    var cols: Int?

    init(_ session: SessionDescriptor) {
        id = session.id.rawValue
        ref = nil
        deviceID = session.deviceID.rawValue
        name = session.name
        workingDirectory = session.workingDirectory
        cwd = nil
        state = session.state.rawValue
        rows = nil
        cols = nil
    }

    func model() throws -> SessionDescriptor {
        guard let id = id ?? ref, let name else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "session requires id/ref and name"))
        }
        // Contracts v0 has no device ID and does not know server states such as "idle".
        let lifecycle = state.flatMap(SessionLifecycleState.init(rawValue:)) ?? .unknown
        return SessionDescriptor(
            id: SessionID(id),
            deviceID: DeviceID(deviceID ?? ""),
            name: name,
            workingDirectory: workingDirectory ?? cwd,
            state: lifecycle
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, ref, name, state, cwd, rows, cols
        case deviceID = "device_id"
        case workingDirectory = "working_directory"
    }
}

