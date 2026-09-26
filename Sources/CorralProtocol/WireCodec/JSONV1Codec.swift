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
    case unsupportedCapability(String)
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
        case .createSession:
            // This command remains capability-gated; it is not part of the frozen v1 WebSocket type set.
            throw V1ControlCodecError.unsupportedCapability("create_session")
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
            guard (value.ok && (value.reason == nil || value.reason == "")) || (!value.ok && !(value.reason ?? "").isEmpty) else {
                throw V1ControlCodecError.invalidField("auth_ack.reason")
            }
            return .authAck(ok: value.ok, reason: value.reason)
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
        let record = WireSessionRecord(
            reference: try SessionReference(payload.reference),
            name: payload.name,
            workingDirectory: payload.workingDirectory,
            state: payload.state,
            rows: payload.rows,
            columns: payload.columns,
            provider: payload.provider,
            activity: payload.activity
        )
        guard record.isValid else { throw V1ControlCodecError.invalidField("session") }
        return record
    }

    private func decodeWorkspace(_ payload: WorkspacePayload) throws -> WorkspaceRecord {
        let record = WorkspaceRecord(
            workingDirectory: payload.workingDirectory,
            sessionCount: payload.sessionCount,
            aggregateState: payload.aggregateState,
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
private struct SubscribePayload: Encodable {
    let ref: String
    let rows: UInt16
    let columns: UInt16
    enum CodingKeys: String, CodingKey { case ref, rows, columns = "cols" }
}

private struct InputPayload: Encodable {
    let requestID: UInt32
    let reference: String
    var text: String?
    var keys: [String]?
    var attachmentPath: String?

    enum CodingKeys: String, CodingKey { case requestID = "req_id", reference = "ref", text, keys, attachmentPath = "attachment_path" }
    init(requestID: UInt32, reference: String) { self.requestID = requestID; self.reference = reference }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(reference, forKey: .reference)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(keys, forKey: .keys)
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

private struct AuthAckPayload: Decodable { let ok: Bool; let reason: String? }
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
    let aggregateState: WireAgentState
    let sessions: [WireSessionPayload]?
    enum CodingKeys: String, CodingKey { case workingDirectory = "cwd", sessionCount = "session_count", aggregateState = "aggregate_state", sessions }
}
private struct WireSessionPayload: Decodable {
    let reference: String
    let name: String
    let workingDirectory: String
    let state: WireAgentState
    let rows: UInt16
    let columns: UInt16
    let provider: String?
    let activity: String?
    enum CodingKeys: String, CodingKey { case reference = "ref", name, workingDirectory = "cwd", state, rows, columns = "cols", provider, activity }
