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

/// Lossless two-level v1 listing DTOs. `seq` is server listing order, not a request ID or frame ACK.
public struct WireSessionRecord: Codable, Equatable, Sendable {
    public let reference: SessionReference
    public let name: String
    public let workingDirectory: String
    public let state: WireAgentState
    public let rows: UInt16
    public let columns: UInt16
    public let provider: String?
    public let activity: String?

    public init(reference: SessionReference, name: String, workingDirectory: String, state: WireAgentState, rows: UInt16, columns: UInt16, provider: String? = nil, activity: String? = nil) {
        self.reference = reference
        self.name = name
        self.workingDirectory = workingDirectory
        self.state = state
        self.rows = rows
        self.columns = columns
        self.provider = provider
        self.activity = activity
    }
}

public struct WorkspaceRecord: Codable, Equatable, Sendable {
    public let workingDirectory: String
    public let sessionCount: Int
    public let aggregateState: WireAgentState
    public let sessions: [WireSessionRecord]

    public init(workingDirectory: String, sessionCount: Int, aggregateState: WireAgentState, sessions: [WireSessionRecord] = []) {
        self.workingDirectory = workingDirectory
        self.sessionCount = sessionCount
        self.aggregateState = aggregateState
        self.sessions = sessions
    }

    public var isValid: Bool {
        !workingDirectory.isEmpty && sessionCount >= 0 && sessions.allSatisfy { !$0.workingDirectory.isEmpty && $0.rows > 0 && $0.columns > 0 }
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
}

public extension WireSessionRecord {
    var isValid: Bool { !workingDirectory.isEmpty && rows > 0 && columns > 0 }
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
