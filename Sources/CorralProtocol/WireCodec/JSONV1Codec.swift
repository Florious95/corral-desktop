import CorralContracts
import Foundation

public enum V1ControlCodecError: Error, Equatable, Sendable {
    case missingVersion
    case unsupportedVersion(UInt16)
    case unknownType(String)
    case malformedEnvelope
    case invalidPayload
    case invalidField(String)
    case payloadTooLarge
}

/// Explicit v1 `{v,type,payload}` mapping. Synthesized Codable on ClientCommand is never wire output.
public struct JSONV1Codec: V1ControlCodecProtocol {
    public static let maximumControlMessageBytes = 65_536

    public init() {}

    public func encodeAuthentication(_ token: AuthToken) throws -> Data {
        guard !token.rawValue.isEmpty else { throw V1ControlCodecError.invalidField("token") }
        return try encodeEnvelope(type: "auth", payload: AuthPayload(token: token.rawValue))
    }

    public func encodeClientCommand(_ command: ClientCommand) throws -> Data {
        switch command {
        case let .list(requestID):
            guard requestID > 0 else { throw V1ControlCodecError.invalidField("req_id") }
            return try encodeEnvelope(type: "list", payload: ListPayload(requestID: requestID))
        case let .subscribe(reference, size):
            guard size.fitsProtocolV1 else { throw V1ControlCodecError.invalidField("rows/cols") }
            return try encodeEnvelope(type: "subscribe", payload: SubscribePayload(ref: reference.rawValue, rows: UInt16(size.rows), columns: UInt16(size.columns)))
        case let .unsubscribe(reference):
            return try encodeEnvelope(type: "unsubscribe", payload: ReferencePayload(ref: reference.rawValue))
        case let .input(request):
            var payload = InputPayload(requestID: request.sequence, reference: request.reference.rawValue)
            switch request.payload {
            case let .text(text, attachmentPath):
                payload.text = text.isEmpty ? nil : text
                payload.attachmentPath = attachmentPath
            case let .keys(keys):
                guard !keys.isEmpty else { throw V1ControlCodecError.invalidField("keys") }
                payload.keys = keys.map(\.rawValue)
            case let .bytes(bytes):
                guard !bytes.isEmpty, bytes.count <= ProtocolV1.maximumInputBytes else {
                    throw V1ControlCodecError.invalidField("bytes")
                }
                payload.bytes = bytes.base64EncodedString()
            case .bareEnter:
                break // Empty text and keys are the v1 bare-Enter representation.
            }
            return try encodeEnvelope(type: "input", payload: payload)
        case let .scrollback(reference, metadata):
            return try encodeEnvelope(type: "scrollback", payload: ScrollbackPayload(
                requestID: metadata.requestID,
                ref: reference.rawValue,
                fromLine: metadata.fromLine,
                count: metadata.lineCount
            ))
        case let .resize(reference, size):
            guard size.fitsProtocolV1 else { throw V1ControlCodecError.invalidField("rows/cols") }
            return try encodeEnvelope(type: "resize", payload: ResizePayload(ref: reference.rawValue, rows: UInt16(size.rows), columns: UInt16(size.columns)))
        case let .attachPreview(reference, path):
            guard !path.isEmpty else { throw V1ControlCodecError.invalidField("path") }
            return try encodeEnvelope(type: "attach_preview", payload: AttachPreviewPayload(ref: reference.rawValue, path: path))
        case let .scrollWheel(reference, delta):
            guard delta != 0 else { throw V1ControlCodecError.invalidField("delta") }
            return try encodeEnvelope(type: "scroll_wheel", payload: ScrollWheelPayload(ref: reference.rawValue, delta: delta))
        case let .level2Subscribe(workspace):
            guard !workspace.isEmpty else { throw V1ControlCodecError.invalidField("level2_subscribe.workspace") }
            return try encodeEnvelope(type: "level2_subscribe", payload: Level2SubscribePayload(workspace: workspace))
        case let .level2Unsubscribe(workspace):
            return try encodeEnvelope(type: "level2_unsubscribe", payload: Level2UnsubscribePayload(workspace: workspace))
        case let .overlaySubscribe(socket, rows, columns):
            guard !socket.isEmpty else { throw V1ControlCodecError.invalidField("overlay_subscribe.socket") }
            return try encodeEnvelope(type: "overlay_subscribe", payload: OverlaySubscribePayload(socket: socket, rows: rows, columns: columns))
        case .overlayUnsubscribe:
            return try encodeEnvelope(type: "overlay_unsubscribe", payload: EmptyPayload())
        case let .createAgent(request):
            guard request.requestID > 0 else { throw V1ControlCodecError.invalidField("create_agent.req_id") }
            guard !request.workspace.isEmpty else { throw V1ControlCodecError.invalidField("create_agent.workspace") }
            guard let anchor = request.anchorReference, !anchor.rawValue.isEmpty else {
                throw V1ControlCodecError.invalidField("create_agent.anchor_ref")
            }
            guard !request.provider.isEmpty else { throw V1ControlCodecError.invalidField("create_agent.provider") }
            let scalars = request.name.unicodeScalars
            guard !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  scalars.count <= 64,
                  !scalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw V1ControlCodecError.invalidField("create_agent.name")
            }
            return try encodeEnvelope(type: "create_agent", payload: CreateAgentPayload(request: request, anchor: anchor))
        case let .closeSession(request):
            guard request.requestID > 0 else { throw V1ControlCodecError.invalidField("close_session.req_id") }
            return try encodeEnvelope(type: "close_session", payload: CloseSessionPayload(request: request))
        }
    }

    public func decodeControlMessage(_ bytes: Data) throws -> ControlMessage {
        guard bytes.count <= Self.maximumControlMessageBytes else { throw V1ControlCodecError.payloadTooLarge }
        let envelope: IncomingEnvelope
        do {
            envelope = try JSONDecoder().decode(IncomingEnvelope.self, from: bytes)
        } catch {
            throw V1ControlCodecError.malformedEnvelope
        }
        guard let version = envelope.version else { throw V1ControlCodecError.missingVersion }
        guard version == UInt16(ProtocolV1.version) else { throw V1ControlCodecError.unsupportedVersion(version) }
        guard let type = envelope.type, !type.isEmpty else { throw V1ControlCodecError.malformedEnvelope }
        guard let payload = envelope.payload else { throw V1ControlCodecError.invalidPayload }

        switch type {
        case "auth_ack":
            let value = try decodePayload(AuthAckPayload.self, from: payload)
            let launchers = value.agentLaunchers ?? []
            guard (value.ok && (value.reason == nil || value.reason == "")) || (!value.ok && !(value.reason ?? "").isEmpty) else {
                throw V1ControlCodecError.invalidField("auth_ack.reason")
            }
            var providers = Set<String>()
            for launcher in launchers {
                guard !launcher.provider.isEmpty, !launcher.displayName.isEmpty, providers.insert(launcher.provider).inserted else {
                    throw V1ControlCodecError.invalidField("auth_ack.agent_launchers")
                }
            }
            return .authAck(ok: value.ok, reason: value.reason, launchers: launchers)
        case "listing":
            let value = try decodePayload(ListingPayload.self, from: payload)
            let workspaces = try value.workspaces.map(decodeWorkspace)
            let listing = SessionListing(requestID: value.requestID, sequence: value.sequence, workspaces: workspaces)
            guard listing.isValid else { throw V1ControlCodecError.invalidField("listing") }
            return .listing(listing)
        case "list_delta":
            let value = try decodePayload(ListDeltaPayload.self, from: payload)
            let delta = SessionListDelta(
                sequence: value.sequence,
                addedSessions: try (value.addedSessions ?? []).map(decodeSession),
                removedReferences: try (value.removedReferences ?? []).map(SessionReference.init),
                changedSessions: try (value.changedSessions ?? []).map(decodeSession),
                changedWorkspaces: try (value.changedWorkspaces ?? []).map(decodeWorkspace)
            )
            guard delta.isValid else { throw V1ControlCodecError.invalidField("list_delta") }
            return .listDelta(delta)
        case "create_agent_result":
            let value = try decodePayload(CreateAgentResultPayload.self, from: payload)
            guard value.requestID > 0 else { throw V1ControlCodecError.invalidField("create_agent_result.req_id") }
            let reference = try value.reference.map(SessionReference.init)
            if value.ok {
                guard reference != nil, let name = value.name, !name.isEmpty, value.naming != nil, value.reason == nil else {
                    throw V1ControlCodecError.invalidField("create_agent_result")
                }
            } else if reference != nil || value.name != nil || value.naming != nil || value.reason == nil {
                throw V1ControlCodecError.invalidField("create_agent_result")
            }
            return .createAgentResult(CreateAgentResult(requestID: value.requestID, ok: value.ok, reference: reference, name: value.name, naming: value.naming, reason: value.reason))
        case "close_session_result":
            let value = try decodePayload(CloseSessionResultPayload.self, from: payload)
            guard value.requestID > 0,
                  (value.ok && value.reason == nil) || (!value.ok && value.reason != nil) else {
                throw V1ControlCodecError.invalidField("close_session_result")
            }
            return .closeSessionResult(CloseSessionResult(requestID: value.requestID, ok: value.ok, reason: value.reason))
        case "input_ack":
            let value = try decodePayload(InputAckPayload.self, from: payload)
            guard value.requestID > 0 else { throw V1ControlCodecError.invalidField("input_ack.req_id") }
            let reason = value.reason.flatMap(InputFailureReason.init(rawValue:))
            guard (value.ok && (value.reason == nil || value.reason == "")) || (!value.ok && reason != nil) else {
                throw V1ControlCodecError.invalidField("input_ack.reason")
            }
            return .inputAck(seq: value.requestID, ok: value.ok, reason: reason)
        case "error":
            let value = try decodePayload(ErrorPayload.self, from: payload)
            guard let code = WireErrorCode(rawValue: value.code) else { throw V1ControlCodecError.invalidField("error.code") }
            return .error(code: code, reason: value.reason)
        case "pane_mode_changed":
            let value = try decodePayload(PaneModePayload.self, from: payload)
            return .paneModeChanged(reference: try SessionReference(value.reference), inCopyMode: value.inCopyMode)
        case "presence_update":
            let value = try decodePayload(PresenceUpdatePayload.self, from: payload)
            guard value.hasMobile == (value.mobileCount > 0) else { throw V1ControlCodecError.invalidField("presence_update.has_mobile") }
            return .presenceUpdate(
                reference: try SessionReference(value.reference),
                hasMobile: value.hasMobile,
                mobileCount: value.mobileCount,
                desktopCount: value.desktopCount
            )
        case "level2_frame":
            let value = try decodePayload(Level2FramePayload.self, from: payload)
            guard !value.workspace.isEmpty, value.sequence > 0 else { throw V1ControlCodecError.invalidField("level2_frame") }
            return .level2Frame(workspace: value.workspace, sequence: value.sequence, sessions: try value.sessions.map(decodeSession))
        case "level2_heartbeat":
            let value = try decodePayload(Level2HeartbeatPayload.self, from: payload)
            guard !value.workspace.isEmpty, value.sequence > 0 else { throw V1ControlCodecError.invalidField("level2_heartbeat") }
            return .level2Heartbeat(workspace: value.workspace, sequence: value.sequence)
        case "overlay_frame":
            let value = try decodePayload(OverlayFramePayload.self, from: payload)
            guard value.sequence > 0, !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw V1ControlCodecError.invalidField("overlay_frame")
            }
            return .overlayFrame(sequence: value.sequence, text: value.text, rows: value.rows ?? 0, columns: value.columns ?? 0)
        default:
            throw V1ControlCodecError.unknownType(type)
        }
    }

    private func encodeEnvelope<Payload: Encodable>(type: String, payload: Payload) throws -> Data {
        let data = try JSONEncoder().encode(OutgoingEnvelope(version: UInt16(ProtocolV1.version), type: type, payload: payload))
        guard data.count <= Self.maximumControlMessageBytes else { throw V1ControlCodecError.payloadTooLarge }
        return data
    }

    private func decodePayload<Payload: Decodable>(_ type: Payload.Type, from value: JSONValue) throws -> Payload {
        guard case .object = value else { throw V1ControlCodecError.invalidPayload }
        do {
            return try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
        } catch {
            throw V1ControlCodecError.invalidPayload
        }
    }

    private func decodeSession(_ payload: WireSessionPayload) throws -> WireSessionRecord {
        let state = payload.state ?? payload.activity.flatMap(WireAgentState.init(rawValue:)) ?? payload.status.flatMap(WireAgentState.init(rawValue:)) ?? .unknown
        let record = WireSessionRecord(
            reference: try SessionReference(payload.reference),
            name: payload.name,
            workingDirectory: payload.workingDirectory,
            state: state,
            rows: payload.rows,
            columns: payload.columns,
            provider: payload.provider,
            activity: payload.activity,
            windowName: payload.windowName ?? "",
            windowIndex: payload.windowIndex ?? "",
            title: payload.title ?? "",
            sessionName: payload.sessionName,
            health: payload.health ?? "",
            status: payload.status ?? payload.activity
        )
        guard record.isValid else { throw V1ControlCodecError.invalidField("session") }
        return record
    }

    private func decodeWorkspace(_ payload: WorkspacePayload) throws -> WorkspaceRecord {
        let workingCount = payload.workingCount ?? 0
        let record = WorkspaceRecord(
            workingDirectory: payload.workingDirectory,
            sessionCount: payload.sessionCount,
            aggregateState: payload.aggregateState ?? (workingCount > 0 ? .working : .idle),
            workingCount: workingCount,
            sessions: try (payload.sessions ?? []).map(decodeSession)
        )
        guard record.isValid else { throw V1ControlCodecError.invalidField("workspace") }
        return record
    }
}

public struct ProtocolV1Codec: WireCodecProtocol {
    private let binary = BinaryV1Codec()
    private let json = JSONV1Codec()

    public init() {}
    public func encodeBinaryFrame(_ frame: BinaryFrame) throws -> Data { try binary.encodeBinaryFrame(frame) }
    public func decodeBinaryFrame(_ bytes: Data) throws -> BinaryFrame { try binary.decodeBinaryFrame(bytes) }
    public func encodeAuthentication(_ token: AuthToken) throws -> Data { try json.encodeAuthentication(token) }
    public func encodeClientCommand(_ command: ClientCommand) throws -> Data { try json.encodeClientCommand(command) }
    public func decodeControlMessage(_ bytes: Data) throws -> ControlMessage { try json.decodeControlMessage(bytes) }
}

private struct OutgoingEnvelope<Payload: Encodable>: Encodable {
    let version: UInt16
    let type: String
    let payload: Payload

    enum CodingKeys: String, CodingKey { case version = "v", type, payload }
}

private struct IncomingEnvelope: Decodable {
    let version: UInt16?
    let type: String?
    let payload: JSONValue?

    enum CodingKeys: String, CodingKey { case version = "v", type, payload }
}

private enum JSONValue: Codable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int64)
    case unsigned(UInt64)
    case decimal(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            var values: [JSONValue] = []
            while !array.isAtEnd { values.append(try array.decode(JSONValue.self)) }
            self = .array(values)
            return
        }
        if let object = try? decoder.container(keyedBy: DynamicKey.self) {
            var values: [String: JSONValue] = [:]
            for key in object.allKeys { values[key.stringValue] = try object.decode(JSONValue.self, forKey: key) }
            self = .object(values)
            return
        }
        let scalar = try decoder.singleValueContainer()
        if scalar.decodeNil() { self = .null }
        else if let value = try? scalar.decode(Bool.self) { self = .bool(value) }
        else if let value = try? scalar.decode(Int64.self) { self = .integer(value) }
        else if let value = try? scalar.decode(UInt64.self) { self = .unsigned(value) }
        else if let value = try? scalar.decode(Double.self) { self = .decimal(value) }
        else if let value = try? scalar.decode(String.self) { self = .string(value) }
        else { throw V1ControlCodecError.invalidPayload }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .object(values):
            var container = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in values { try container.encode(value, forKey: DynamicKey(key)) }
        case let .array(values):
            var container = encoder.unkeyedContainer()
            for value in values { try container.encode(value) }
        case let .string(value): var container = encoder.singleValueContainer(); try container.encode(value)
        case let .integer(value): var container = encoder.singleValueContainer(); try container.encode(value)
        case let .unsigned(value): var container = encoder.singleValueContainer(); try container.encode(value)
        case let .decimal(value): var container = encoder.singleValueContainer(); try container.encode(value)
        case let .bool(value): var container = encoder.singleValueContainer(); try container.encode(value)
        case .null: var container = encoder.singleValueContainer(); try container.encodeNil()
        }
    }
}

private struct DynamicKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil
    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

private struct AuthPayload: Encodable {
    let token: String
}

private struct ListPayload: Encodable {
    let requestID: UInt32
    enum CodingKeys: String, CodingKey { case requestID = "req_id" }
}

private struct ReferencePayload: Encodable { let ref: String }
private struct CreateAgentPayload: Encodable {
    let requestID: UInt32
    let workspace: String
    let anchorReference: String
    let provider: String
    let name: String
    let bypass: Bool

    init(request: CreateAgentRequest, anchor: SessionReference) {
        requestID = request.requestID
        workspace = request.workspace
        anchorReference = anchor.rawValue
        provider = request.provider
        name = request.name
        bypass = request.bypass
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "req_id"
        case workspace, provider, name, bypass
        case anchorReference = "anchor_ref"
    }
}
private struct CloseSessionPayload: Encodable {
    let requestID: UInt32
    let reference: String
    init(request: CloseSessionRequest) { requestID = request.requestID; reference = request.reference.rawValue }
    enum CodingKeys: String, CodingKey { case requestID = "req_id", reference = "ref" }
}
private struct SubscribePayload: Encodable {
    let ref: String
    let rows: UInt16
    let columns: UInt16
    /// Registers this mirror in Core's presence set, which then reports phones on the same session.
    let clientType = "desktop"
    enum CodingKeys: String, CodingKey { case ref, rows, columns = "cols", clientType = "client_type" }
}

private struct InputPayload: Encodable {
    let requestID: UInt32
    let reference: String
    var text: String?
    var keys: [String]?
    var attachmentPath: String?
    var bytes: String?

    enum CodingKeys: String, CodingKey { case requestID = "req_id", reference = "ref", text, keys, bytes, attachmentPath = "attachment_path" }
    init(requestID: UInt32, reference: String) { self.requestID = requestID; self.reference = reference }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(reference, forKey: .reference)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(keys, forKey: .keys)
        try container.encodeIfPresent(bytes, forKey: .bytes)
        try container.encodeIfPresent(attachmentPath, forKey: .attachmentPath)
    }
}

private struct ScrollbackPayload: Encodable {
    let requestID: UInt32
    let ref: String
    let fromLine: Int32
    let count: UInt32
    enum CodingKeys: String, CodingKey { case requestID = "req_id", ref, fromLine = "from_line", count }
}
private struct ResizePayload: Encodable {
    let ref: String
    let rows: UInt16
    let columns: UInt16
    enum CodingKeys: String, CodingKey { case ref, rows, columns = "cols" }
}
private struct AttachPreviewPayload: Encodable { let ref: String; let path: String }
private struct ScrollWheelPayload: Encodable { let ref: String; let delta: Int32 }
private struct Level2SubscribePayload: Encodable { let workspace: String }
private struct Level2UnsubscribePayload: Encodable {
    let workspace: String?
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: DynamicKey.self)
        try values.encodeIfPresent(workspace, forKey: DynamicKey("workspace"))
    }
}
private struct OverlaySubscribePayload: Encodable {
    let socket: String
    let rows: UInt16?
    let columns: UInt16?
    enum CodingKeys: String, CodingKey { case socket, rows, columns = "cols" }
}
private struct EmptyPayload: Encodable {}

private struct AuthAckPayload: Decodable {
    let ok: Bool
    let reason: String?
    let agentLaunchers: [AgentLauncher]?
    enum CodingKeys: String, CodingKey { case ok, reason, agentLaunchers = "agent_launchers" }
}
private struct CreateAgentResultPayload: Decodable {
    let requestID: UInt32
    let ok: Bool
    let reference: String?
    let name: String?
    let naming: AgentNamingMode?
    let reason: CreateAgentFailureReason?
    enum CodingKeys: String, CodingKey { case requestID = "req_id", ok, reference = "ref", name, naming, reason }
}
private struct CloseSessionResultPayload: Decodable {
    let requestID: UInt32
    let ok: Bool
    let reason: CloseSessionFailureReason?
    enum CodingKeys: String, CodingKey { case requestID = "req_id", ok, reason }
}
private struct InputAckPayload: Decodable {
    let requestID: UInt32
    let ok: Bool
    let reason: String?
    enum CodingKeys: String, CodingKey { case requestID = "req_id", ok, reason }
}
private struct ErrorPayload: Decodable { let code: String; let reason: String? }
private struct PaneModePayload: Decodable {
    let reference: String
    let inCopyMode: Bool
    enum CodingKeys: String, CodingKey { case reference = "ref", inCopyMode = "in_copy_mode" }
}
private struct PresenceUpdatePayload: Decodable {
    let reference: String
    let hasMobile: Bool
    let mobileCount: UInt32
    let desktopCount: UInt32
    enum CodingKeys: String, CodingKey {
        case reference = "ref"
        case hasMobile = "has_mobile"
        case mobileCount = "mobile_count"
        case desktopCount = "desktop_count"
    }
}
private struct Level2FramePayload: Decodable {
    let workspace: String
    let sequence: UInt64
    let sessions: [WireSessionPayload]
    enum CodingKeys: String, CodingKey { case workspace, sequence = "seq", sessions }
}
private struct Level2HeartbeatPayload: Decodable {
    let workspace: String
    let sequence: UInt64
    enum CodingKeys: String, CodingKey { case workspace, sequence = "seq" }
}
private struct OverlayFramePayload: Decodable {
    let sequence: UInt64
    let text: String
    let rows: UInt16?
    let columns: UInt16?
    enum CodingKeys: String, CodingKey { case sequence = "seq", text, rows, columns = "cols" }
}
private struct ListingPayload: Decodable {
    let requestID: UInt32
    let sequence: UInt64
    let workspaces: [WorkspacePayload]
    enum CodingKeys: String, CodingKey { case requestID = "req_id", sequence = "seq", workspaces }
}
private struct ListDeltaPayload: Decodable {
    let sequence: UInt64
    let addedSessions: [WireSessionPayload]?
    let removedReferences: [String]?
    let changedSessions: [WireSessionPayload]?
    let changedWorkspaces: [WorkspacePayload]?
    enum CodingKeys: String, CodingKey {
        case sequence = "seq"
        case addedSessions = "added_sessions"
        case removedReferences = "removed_refs"
        case changedSessions = "changed_sessions"
        case changedWorkspaces = "changed_workspaces"
    }
}
private struct WorkspacePayload: Decodable {
    let workingDirectory: String
    let sessionCount: Int
    let workingCount: Int?
    let aggregateState: WireAgentState?
    let sessions: [WireSessionPayload]?
    enum CodingKeys: String, CodingKey {
        case workingDirectory = "cwd"
        case sessionCount = "session_count"
        case workingCount = "working_count"
        case aggregateState = "aggregate_state"
        case sessions
    }
}
private struct WireSessionPayload: Decodable {
    let reference: String
    let name: String
    let workingDirectory: String
    let state: WireAgentState?
    let rows: UInt16
    let columns: UInt16
    let provider: String?
    let activity: String?
    let windowName: String?
    let windowIndex: String?
    let title: String?
    let sessionName: String?
    let health: String?
    let status: String?
    enum CodingKeys: String, CodingKey {
        case reference = "ref", name, workingDirectory = "cwd", state, rows, columns = "cols", provider, activity, title, health, status
        case windowName = "window_name"
        case windowIndex = "window_index"
        case sessionName = "session_name"
    }
}
