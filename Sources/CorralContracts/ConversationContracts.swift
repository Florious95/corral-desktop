import Foundation

/// `conversation_v1` + `conversation_window_v1` (Core docs/contracts 06 and 11): structured Agent conversations
/// multiplexed over the same authenticated `/ws`, with bounded HTTP history. These are wire values, not UI state.
public enum ConversationCapability {
    public static let conversation = "conversation_v1"
    public static let window = "conversation_window_v1"
    /// Offered in `auth`; GUI frames are only sent after `auth_ack` echoes both.
    public static let offered = [conversation, window]
}

public enum ConversationWire {
    public static let summaryBytes = 1_024
    public static let historyRequestBytes = 4 << 10
    public static let liveFrameBytes = 16 << 10
    /// Core rejects command ids outside 1...64 bytes.
    public static let maximumCommandIDBytes = 64
}

/// One independently renderable, stable producer item. Kinds seen on the wire: user, assistant, reasoning,
/// tool, notice. Unknown kinds are preserved so the UI can show them honestly instead of inventing a role.
public struct ConversationItem: Codable, Equatable, Sendable {
    public let id: String
    public let revision: UInt64
    public let orderKey: String
    public let kind: String
    public let summary: String
    public let bodyRef: String?
    /// `complete` (summary is the whole text) or `deferred` (only reachable through `bodyRef`).
    public let bodyState: String
    /// `complete` or `observed_suffix` (a cold attach missed the prefix; never fabricated).
    public let contentState: String?
    public let timestampMS: Int64?
    public let streaming: Bool
    public let toolID: String?
    public let toolName: String?
    /// pending, running, succeeded, failed; unknown values stay unknown.
    public let toolPhase: String?
    public let imageCount: Int
    public let redacted: Bool

    public init(id: String, revision: UInt64, orderKey: String, kind: String, summary: String, bodyRef: String? = nil,
                bodyState: String = "complete", contentState: String? = nil, timestampMS: Int64? = nil, streaming: Bool = false,
                toolID: String? = nil, toolName: String? = nil, toolPhase: String? = nil, imageCount: Int = 0, redacted: Bool = false) {
        self.id = id
        self.revision = revision
        self.orderKey = orderKey
        self.kind = kind
        self.summary = summary
        self.bodyRef = bodyRef
        self.bodyState = bodyState
        self.contentState = contentState
        self.timestampMS = timestampMS
        self.streaming = streaming
        self.toolID = toolID
        self.toolName = toolName
        self.toolPhase = toolPhase
        self.imageCount = imageCount
        self.redacted = redacted
    }

    public var isDeferred: Bool { bodyState == "deferred" && bodyRef?.isEmpty == false }

    private enum CodingKeys: String, CodingKey {
        case id, revision, kind, summary, streaming, redacted
        case orderKey = "order_key", bodyRef = "body_ref", bodyState = "body_state", contentState = "content_state"
        case timestampMS = "timestamp_ms", toolID = "tool_id", toolName = "tool_name", toolPhase = "tool_phase", imageCount = "image_count"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        revision = try values.decode(UInt64.self, forKey: .revision)
        orderKey = try values.decode(String.self, forKey: .orderKey)
        kind = try values.decode(String.self, forKey: .kind)
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        bodyRef = try values.decodeIfPresent(String.self, forKey: .bodyRef)
        bodyState = try values.decodeIfPresent(String.self, forKey: .bodyState) ?? "complete"
        contentState = try values.decodeIfPresent(String.self, forKey: .contentState)
        timestampMS = try values.decodeIfPresent(Int64.self, forKey: .timestampMS)
        streaming = try values.decodeIfPresent(Bool.self, forKey: .streaming) ?? false
        toolID = try values.decodeIfPresent(String.self, forKey: .toolID)
        toolName = try values.decodeIfPresent(String.self, forKey: .toolName)
        toolPhase = try values.decodeIfPresent(String.self, forKey: .toolPhase)
        imageCount = try values.decodeIfPresent(Int.self, forKey: .imageCount) ?? 0
        redacted = try values.decodeIfPresent(Bool.self, forKey: .redacted) ?? false
        guard !id.isEmpty, !orderKey.isEmpty, !kind.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: values, debugDescription: "incomplete conversation item")
        }
    }
}

/// `conversation_ready` for a windowed view. Legacy (non-windowed) readies are never adopted by this client.
public struct ConversationReady: Equatable, Sendable {
    public let reference: SessionReference
    /// rpc or tui; older workers send no mode, which means rpc.
    public let mode: String
    public let running: Bool
    public let sessionID: String
    public let viewID: String
    public let sourceEpoch: String
    public let snapshotSeq: UInt64
    public let windowToken: String
    /// complete, retained_window or unsupported.
    public let historySupport: String
    public let sourceOmitted: Bool

    public init(reference: SessionReference, mode: String, running: Bool, sessionID: String, viewID: String, sourceEpoch: String,
                snapshotSeq: UInt64, windowToken: String, historySupport: String, sourceOmitted: Bool) {
        self.reference = reference
        self.mode = mode.isEmpty ? "rpc" : mode
        self.running = running
        self.sessionID = sessionID
        self.viewID = viewID
        self.sourceEpoch = sourceEpoch
        self.snapshotSeq = snapshotSeq
        self.windowToken = windowToken
        self.historySupport = historySupport
        self.sourceOmitted = sourceOmitted
    }
}

/// Small authoritative run state carried by a live commit; HTTP history never supplies it.
public struct ConversationLiveState: Codable, Equatable, Sendable {
    public let running: Bool
    public let queued: Int
    public let mode: String
    public init(running: Bool, queued: Int, mode: String) { self.running = running; self.queued = queued; self.mode = mode }
}

/// One atomic live projection commit `(base_seq, commit_seq]`.
public struct ConversationUpdate: Equatable, Sendable {
    public let reference: SessionReference
    public let viewID: String
    public let sourceEpoch: String
    public let baseSeq: UInt64
    public let commitSeq: UInt64
    public let upserts: [ConversationItem]
    public let removes: [String]
    public let state: ConversationLiveState?

    public init(reference: SessionReference, viewID: String, sourceEpoch: String, baseSeq: UInt64, commitSeq: UInt64,
                upserts: [ConversationItem], removes: [String], state: ConversationLiveState?) {
        self.reference = reference
        self.viewID = viewID
        self.sourceEpoch = sourceEpoch
        self.baseSeq = baseSeq
        self.commitSeq = commitSeq
        self.upserts = upserts
        self.removes = removes
        self.state = state
    }
}

/// A native control record (`response`, `extension_ui_request`, ...). `event` is the native JSON object, kept raw.
public struct ConversationEvent: Equatable, Sendable {
    public let reference: SessionReference
    public let viewID: String?
    public let sourceEpoch: String?
    public let event: Data
    public init(reference: SessionReference, viewID: String?, sourceEpoch: String?, event: Data) {
        self.reference = reference
        self.viewID = viewID
        self.sourceEpoch = sourceEpoch
        self.event = event
    }
}

public enum ConversationClosedReason: String, Codable, Sendable {
    /// The ref is not a managed conversation pane.
    case unavailable
    /// The managed agent process is gone.
    case exited
    /// The stream dropped while the agent is alive.
    case lost
}

public struct ConversationHistoryRequest: Encodable, Equatable, Sendable {
    public enum Operation: String, Encodable, Sendable { case initial, before, after, body }
    public let reference: SessionReference
    public let viewID: String
    public let requestID: String
    public let operation: Operation
    public let cursor: String
    public let bodyRef: String?

    public init(reference: SessionReference, viewID: String, requestID: String, operation: Operation, cursor: String, bodyRef: String? = nil) {
        self.reference = reference
        self.viewID = viewID
        self.requestID = requestID
        self.operation = operation
        self.cursor = cursor
        self.bodyRef = bodyRef
    }

    private enum CodingKeys: String, CodingKey { case ref, cursor, op, viewID = "view_id", requestID = "request_id", bodyRef = "body_ref" }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(reference.rawValue, forKey: .ref)
        try values.encode(viewID, forKey: .viewID)
        try values.encode(requestID, forKey: .requestID)
        try values.encode(operation, forKey: .op)
        try values.encode(cursor, forKey: .cursor)
        try values.encodeIfPresent(bodyRef, forKey: .bodyRef)
    }
}

/// An immutable page at H, or one body chunk. It never advances the live watermark or run state.
public struct ConversationHistoryPage: Decodable, Equatable, Sendable {
    public let requestID: String
    public let viewID: String
    public let sourceEpoch: String
    public let snapshotSeq: UInt64
    public let items: [ConversationItem]
    public let beforeCursor: String?
    public let afterCursor: String?
    public let hasMoreBefore: Bool
    public let hasMoreAfter: Bool
    public let historySupport: String
    public let sourceOmitted: Bool
    public let bodyRef: String?
    public let body: String?
    public let bodyCursor: String?
    public let bodyComplete: Bool

    private enum CodingKeys: String, CodingKey {
        case items, body
        case requestID = "request_id", viewID = "view_id", sourceEpoch = "source_epoch", snapshotSeq = "snapshot_seq"
        case beforeCursor = "before_cursor", afterCursor = "after_cursor", hasMoreBefore = "has_more_before", hasMoreAfter = "has_more_after"
        case historySupport = "history_support", sourceOmitted = "source_omitted", bodyRef = "body_ref", bodyCursor = "body_cursor"
        case bodyComplete = "body_complete"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try values.decode(String.self, forKey: .requestID)
        viewID = try values.decode(String.self, forKey: .viewID)
        sourceEpoch = try values.decode(String.self, forKey: .sourceEpoch)
        snapshotSeq = try values.decode(UInt64.self, forKey: .snapshotSeq)
        items = try values.decodeIfPresent([ConversationItem].self, forKey: .items) ?? []
        beforeCursor = try values.decodeIfPresent(String.self, forKey: .beforeCursor)
        afterCursor = try values.decodeIfPresent(String.self, forKey: .afterCursor)
        hasMoreBefore = try values.decodeIfPresent(Bool.self, forKey: .hasMoreBefore) ?? false
        hasMoreAfter = try values.decodeIfPresent(Bool.self, forKey: .hasMoreAfter) ?? false
        historySupport = try values.decodeIfPresent(String.self, forKey: .historySupport) ?? "unsupported"
        sourceOmitted = try values.decodeIfPresent(Bool.self, forKey: .sourceOmitted) ?? false
        bodyRef = try values.decodeIfPresent(String.self, forKey: .bodyRef)
        body = try values.decodeIfPresent(String.self, forKey: .body)
        bodyCursor = try values.decodeIfPresent(String.self, forKey: .bodyCursor)
        bodyComplete = try values.decodeIfPresent(Bool.self, forKey: .bodyComplete) ?? false
    }
}

/// Closed local history failures (`busy`, `deadline`, `stale_view`, `cursor_expired`, `source_unavailable`,
/// `too_large`, `cancelled`) plus transport/HTTP failures. None of them closes a healthy WebSocket.
public struct ConversationHistoryFailure: Error, Equatable, Sendable {
    public let code: String
    public init(_ code: String) { self.code = code }
    /// The view itself is gone; only a fresh subscription can recover it.
    public var retiresView: Bool { ["stale_view", "source_unavailable", "cursor_expired"].contains(code) }
}
