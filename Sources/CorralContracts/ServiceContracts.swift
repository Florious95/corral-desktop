import Foundation

public struct DeviceID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    public let rawValue: String
    public var id: String { rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A session identity is device-scoped; wire references are opaque and may collide across devices.
public struct SessionKey: Codable, Hashable, Sendable {
    public let deviceID: DeviceID
    public let reference: SessionReference

    public init(deviceID: DeviceID, reference: SessionReference) {
        self.deviceID = deviceID
        self.reference = reference
    }
}

public struct DeviceRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: DeviceID
    public var name: String
    public let endpoint: ApprovedEndpoint
    public let credential: CredentialHandle

    public init(id: DeviceID, name: String, endpoint: ApprovedEndpoint, credential: CredentialHandle) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.credential = credential
    }
}

public enum WireAgentState: String, Codable, Sendable {
    case working
    case idle
    case blocked
    case done
    case unknown
}

public enum SessionLifecycleState: String, Codable, Sendable {
    case running
    case done
    case exited
    case unknown
}

/// Lossless agentmirrord v1 session projection. `state` is a compatibility view;
/// the server's actual axes are provider/activity/health/status and are preserved below.
public struct WireSessionRecord: Codable, Equatable, Sendable {
    public let reference: SessionReference
    public let name: String
    public let workingDirectory: String
    public let state: WireAgentState
    public let rows: UInt16
    public let columns: UInt16
    public let provider: String?
    public let activity: String?
    public let windowName: String
    public let windowIndex: String
    public let title: String
    public let sessionName: String?
    public let health: String
    public let status: String

    public init(
        reference: SessionReference,
        name: String,
        workingDirectory: String,
        state: WireAgentState,
        rows: UInt16,
        columns: UInt16,
        provider: String? = nil,
        activity: String? = nil,
        windowName: String = "",
        windowIndex: String = "",
        title: String = "",
        sessionName: String? = nil,
        health: String = "",
        status: String? = nil
    ) {
        self.reference = reference
        self.name = name
        self.workingDirectory = workingDirectory
        self.state = state
        self.rows = rows
        self.columns = columns
        self.provider = provider
        self.activity = activity
        self.windowName = windowName
        self.windowIndex = windowIndex
        self.title = title
        self.sessionName = sessionName
        self.health = health
        self.status = status ?? activity ?? ""
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let activity = try values.decodeIfPresent(String.self, forKey: .activity)
        let legacyState = try values.decodeIfPresent(WireAgentState.self, forKey: .legacyState)
        self.reference = try SessionReference(values.decode(String.self, forKey: .reference))
        self.name = try values.decode(String.self, forKey: .name)
        self.workingDirectory = try values.decode(String.self, forKey: .workingDirectory)
        self.state = legacyState ?? activity.flatMap(WireAgentState.init(rawValue:)) ?? .unknown
        self.rows = try values.decode(UInt16.self, forKey: .rows)
        self.columns = try values.decode(UInt16.self, forKey: .columns)
        self.provider = try values.decodeIfPresent(String.self, forKey: .provider)
        self.activity = activity
        self.windowName = try values.decodeIfPresent(String.self, forKey: .windowName) ?? ""
        self.windowIndex = try values.decodeIfPresent(String.self, forKey: .windowIndex) ?? ""
        self.title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.sessionName = try values.decodeIfPresent(String.self, forKey: .sessionName)
        self.health = try values.decodeIfPresent(String.self, forKey: .health) ?? ""
        self.status = try values.decodeIfPresent(String.self, forKey: .status) ?? activity ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(reference.rawValue, forKey: .reference)
        try values.encode(name, forKey: .name)
        try values.encode(windowName, forKey: .windowName)
        try values.encode(windowIndex, forKey: .windowIndex)
        try values.encode(workingDirectory, forKey: .workingDirectory)
        try values.encode(title, forKey: .title)
        try values.encode(provider ?? "", forKey: .provider)
        try values.encode(activity ?? "", forKey: .activity)
        try values.encodeIfPresent(sessionName, forKey: .sessionName)
        try values.encode(health, forKey: .health)
        try values.encode(status, forKey: .status)
        try values.encode(rows, forKey: .rows)
        try values.encode(columns, forKey: .columns)
    }

    private enum CodingKeys: String, CodingKey {
        case name, provider, activity, title, health, status, rows
        case reference = "ref"
        case workingDirectory = "cwd"
        case windowName = "window_name"
        case windowIndex = "window_index"
        case sessionName = "session_name"
        case columns = "cols"
        case legacyState = "state"
    }
}

public struct WorkspaceRecord: Codable, Equatable, Sendable {
    public let workingDirectory: String
    public let sessionCount: Int
    public let workingCount: Int
    public let aggregateState: WireAgentState
    public let sessions: [WireSessionRecord]

    public init(workingDirectory: String, sessionCount: Int, aggregateState: WireAgentState, workingCount: Int = 0, sessions: [WireSessionRecord] = []) {
        self.workingDirectory = workingDirectory
        self.sessionCount = sessionCount
        self.workingCount = workingCount
        self.aggregateState = aggregateState
        self.sessions = sessions
    }

    public var isValid: Bool {
        !workingDirectory.isEmpty && sessionCount >= 0 && workingCount >= 0 && workingCount <= sessionCount && sessions.allSatisfy(\.isValid)
    }

    private enum CodingKeys: String, CodingKey {
        case aggregateState = "aggregate_state"
        case workingDirectory = "cwd"
        case sessionCount = "session_count"
        case workingCount = "working_count"
        case sessions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workingDirectory = try values.decode(String.self, forKey: .workingDirectory)
        sessionCount = try values.decode(Int.self, forKey: .sessionCount)
        workingCount = try values.decodeIfPresent(Int.self, forKey: .workingCount) ?? 0
        aggregateState = try values.decodeIfPresent(WireAgentState.self, forKey: .aggregateState)
            ?? (workingCount > 0 ? .working : .idle)
        sessions = try values.decodeIfPresent([WireSessionRecord].self, forKey: .sessions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(workingDirectory, forKey: .workingDirectory)
        try values.encode(sessionCount, forKey: .sessionCount)
        try values.encode(workingCount, forKey: .workingCount)
        try values.encode(aggregateState, forKey: .aggregateState)
        try values.encode(sessions, forKey: .sessions)
    }
}

public struct SessionListing: Codable, Equatable, Sendable {
    public let requestID: UInt32
    public let sequence: UInt64
    public let workspaces: [WorkspaceRecord]

    public init(requestID: UInt32, sequence: UInt64, workspaces: [WorkspaceRecord]) {
        self.requestID = requestID
        self.sequence = sequence
        self.workspaces = workspaces
    }

    public var isValid: Bool { requestID > 0 && sequence > 0 && workspaces.allSatisfy(\.isValid) }

    private enum CodingKeys: String, CodingKey { case requestID = "req_id", sequence = "seq", workspaces }
}

public struct SessionListDelta: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let addedSessions: [WireSessionRecord]
    public let removedReferences: [SessionReference]
    public let changedSessions: [WireSessionRecord]
    public let changedWorkspaces: [WorkspaceRecord]

    public init(sequence: UInt64, addedSessions: [WireSessionRecord] = [], removedReferences: [SessionReference] = [], changedSessions: [WireSessionRecord] = [], changedWorkspaces: [WorkspaceRecord] = []) {
        self.sequence = sequence
        self.addedSessions = addedSessions
        self.removedReferences = removedReferences
        self.changedSessions = changedSessions
        self.changedWorkspaces = changedWorkspaces
    }

    public var isValid: Bool {
        sequence > 0 && addedSessions.allSatisfy(\.isValid) && changedSessions.allSatisfy(\.isValid) &&
            changedWorkspaces.allSatisfy(\.isValid)
    }

    private enum CodingKeys: String, CodingKey {
        case sequence = "seq"
        case addedSessions = "added_sessions"
        case removedReferences = "removed_refs"
        case changedSessions = "changed_sessions"
        case changedWorkspaces = "changed_workspaces"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try values.decode(UInt64.self, forKey: .sequence)
        addedSessions = try values.decodeIfPresent([WireSessionRecord].self, forKey: .addedSessions) ?? []
        removedReferences = try (values.decodeIfPresent([String].self, forKey: .removedReferences) ?? []).map(SessionReference.init)
        changedSessions = try values.decodeIfPresent([WireSessionRecord].self, forKey: .changedSessions) ?? []
        changedWorkspaces = try values.decodeIfPresent([WorkspaceRecord].self, forKey: .changedWorkspaces) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sequence, forKey: .sequence)
        if !addedSessions.isEmpty { try values.encode(addedSessions, forKey: .addedSessions) }
        if !removedReferences.isEmpty { try values.encode(removedReferences.map(\.rawValue), forKey: .removedReferences) }
        if !changedSessions.isEmpty { try values.encode(changedSessions, forKey: .changedSessions) }
        if !changedWorkspaces.isEmpty { try values.encode(changedWorkspaces, forKey: .changedWorkspaces) }
    }
}

public extension WireSessionRecord {
    var isValid: Bool {
        guard !workingDirectory.isEmpty, rows > 0, columns > 0 else { return false }
        let hasFourAxis = !(provider ?? "").isEmpty || !(activity ?? "").isEmpty || !health.isEmpty
        guard hasFourAxis else {
            return status.isEmpty || ["working", "idle", "unknown"].contains(status)
        }
        guard let provider, !provider.isEmpty,
              let activity, ["working", "idle", "unknown"].contains(activity),
              health == "normal" || health == "abnormal" || health == "unknown" else { return false }
        return status.isEmpty || status == activity
    }
}

public struct SessionFreshness: Codable, Hashable, Sendable {
    public let connectionEpoch: ConnectionEpoch
    public let receiveOrdinal: ReceiveOrdinal

    public init(connectionEpoch: ConnectionEpoch, receiveOrdinal: ReceiveOrdinal) {
        self.connectionEpoch = connectionEpoch
        self.receiveOrdinal = receiveOrdinal
    }
}

public struct SessionDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: SessionID
    public let key: SessionKey
    public var name: String
    public var workingDirectory: String
    public var provider: String?
    public var activity: String?
    public var state: SessionLifecycleState
    public var size: GridSize
    public var freshness: SessionFreshness?

    public init(id: SessionID, key: SessionKey, name: String, workingDirectory: String, provider: String? = nil, activity: String? = nil, state: SessionLifecycleState = .unknown, size: GridSize, freshness: SessionFreshness? = nil) {
        self.id = id
        self.key = key
        self.name = name
        self.workingDirectory = workingDirectory
        self.provider = provider
        self.activity = activity
        self.state = state
        self.size = size
        self.freshness = freshness
    }
}

public enum SplitDirection: String, Codable, Sendable {
    case horizontal
    case vertical
}

public indirect enum WorkspaceLayoutNode: Codable, Equatable, Sendable {
    case session(SessionID)
    case split(direction: SplitDirection, ratio: Double, first: WorkspaceLayoutNode, second: WorkspaceLayoutNode)

    public var isValid: Bool {
        switch self {
        case let .session(id): !id.rawValue.isEmpty
        case let .split(_, ratio, first, second): ratio.isFinite && ratio > 0 && ratio < 1 && first.isValid && second.isValid
        }
    }
}

/// Geometry measurements preserve point, device-pixel, grid, and font-metrics generations separately.
public struct GeometrySample: Codable, Hashable, Sendable {
    public let viewport: StageViewportRect
    public let backingScale: Double
    public let grid: GridSize
    public let metricsGeneration: MetricsGeneration

    public init(viewport: StageViewportRect, backingScale: Double, grid: GridSize, metricsGeneration: MetricsGeneration) {
        self.viewport = viewport
        self.backingScale = backingScale
        self.grid = grid
        self.metricsGeneration = metricsGeneration
    }

    public var isValid: Bool { viewport.isValid && backingScale.isFinite && backingScale > 0 && grid.isValid }
}

public protocol GeometryPolicy: Sendable {
    var authoritativeGridSize: GridSize? { get }
}

public extension GeometryPolicy {
    func resolvedGridSize(proposed: GridSize) -> GridSize {
        authoritativeGridSize ?? proposed
    }

    /// Debounce only sub-2-device-pixel noise when rows/columns, metrics, and backing scale are unchanged.
    func shouldDebounceViewportDelta(from previous: GeometrySample, to proposed: GeometrySample) -> Bool {
        guard previous.isValid, proposed.isValid,
              previous.grid == proposed.grid,
              previous.metricsGeneration == proposed.metricsGeneration,
              previous.backingScale == proposed.backingScale else { return false }
        let widthDelta = abs(previous.viewport.width - proposed.viewport.width) * proposed.backingScale
        let heightDelta = abs(previous.viewport.height - proposed.viewport.height) * proposed.backingScale
        return max(widthDelta, heightDelta) < 2
    }

    /// Compare against the last grid actually committed to the server; authority changes are not lost.
    func shouldPublishResize(lastCommittedServerGrid: GridSize, proposed: GeometrySample) -> Bool {
        guard proposed.isValid else { return false }
        return lastCommittedServerGrid != resolvedGridSize(proposed: proposed.grid)
    }
}

public protocol DeviceRepositoryProtocol: Sendable {
    func listDevices() async throws -> [DeviceRecord]
    func save(_ device: DeviceRecord) async throws
    func delete(id: DeviceID) async throws
}

public protocol SessionOrchestratorProtocol: Sendable {
    func listSessions(on deviceID: DeviceID) async throws -> [SessionDescriptor]
    func subscribe(to session: SessionKey, initialSize: GridSize?) async throws
    func unsubscribe(from session: SessionKey) async throws
    func sendUserInput(_ input: TerminalInput, to session: SessionKey) async throws -> UInt32
    func resize(_ session: SessionKey, to size: GridSize) async throws
    func createSession(on deviceID: DeviceID, name: String, workingDirectory: String?) async throws -> SessionDescriptor
}
