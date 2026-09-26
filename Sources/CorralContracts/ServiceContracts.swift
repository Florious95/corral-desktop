import Foundation

public struct DeviceID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    public let rawValue: String
    public var id: String { rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
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

public enum SessionLifecycleState: String, Codable, Sendable {
    case running
    case exited
    case unknown
}

public struct SessionDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: SessionID
    public let deviceID: DeviceID
    public var name: String
    public var workingDirectory: String?
    public var state: SessionLifecycleState

    public init(id: SessionID, deviceID: DeviceID, name: String, workingDirectory: String? = nil, state: SessionLifecycleState = .unknown) {
        self.id = id
        self.deviceID = deviceID
        self.name = name
        self.workingDirectory = workingDirectory
        self.state = state
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
        case let .session(id):
            return !id.rawValue.isEmpty
        case let .split(_, ratio, first, second):
            return ratio.isFinite && ratio > 0 && ratio < 1 && first.isValid && second.isValid
        }
    }
}

/// Geometry measurements preserve point and backing-pixel domains separately.
public struct GeometrySample: Codable, Hashable, Sendable {
    public let viewport: StageViewportRect
    public let backingScale: Double
    public let grid: GridSize
    public let metricsGeneration: UInt64

    public init(viewport: StageViewportRect, backingScale: Double, grid: GridSize, metricsGeneration: UInt64) {
        self.viewport = viewport
        self.backingScale = backingScale
        self.grid = grid
        self.metricsGeneration = metricsGeneration
    }

    public var isValid: Bool { viewport.isValid && backingScale.isFinite && backingScale > 0 && grid.isValid }
}

public protocol GeometryPolicy: Sendable {
    /// Non-nil locks server geometry to this authoritative size.
    var authoritativeGridSize: GridSize? { get }
}

public extension GeometryPolicy {
    func resolvedGridSize(proposed: GridSize) -> GridSize {
        authoritativeGridSize ?? proposed
    }

    /// Debounce only sub-2-device-pixel noise when the logical grid and font metrics are unchanged.
    /// A real rows/columns or metrics-generation change is never suppressed by this threshold.
    func shouldDebounceViewportDelta(from previous: GeometrySample, to proposed: GeometrySample) -> Bool {
        guard previous.isValid, proposed.isValid,
              resolvedGridSize(proposed: previous.grid) == resolvedGridSize(proposed: proposed.grid),
              previous.metricsGeneration == proposed.metricsGeneration,
              previous.backingScale == proposed.backingScale else { return false }
        let widthDelta = abs(previous.viewport.width - proposed.viewport.width) * proposed.backingScale
        let heightDelta = abs(previous.viewport.height - proposed.viewport.height) * proposed.backingScale
        return max(widthDelta, heightDelta) < 2
    }

    /// A resize is published only when the resolved rows/columns actually change.
    func shouldPublishResize(from previous: GeometrySample, to proposed: GeometrySample) -> Bool {
        guard previous.isValid, proposed.isValid else { return false }
        return resolvedGridSize(proposed: previous.grid) != resolvedGridSize(proposed: proposed.grid)
    }
}

public protocol DeviceRepositoryProtocol: Sendable {
    func listDevices() async throws -> [DeviceRecord]
    func save(_ device: DeviceRecord) async throws
    func delete(id: DeviceID) async throws
}

public protocol SessionOrchestratorProtocol: Sendable {
    func listSessions(on deviceID: DeviceID) async throws -> [SessionDescriptor]
    func subscribe(to sessionID: SessionID, initialSize: GridSize?) async throws
    func unsubscribe(from sessionID: SessionID) async throws
    func sendUserInput(_ bytes: UserInputBytes, to sessionID: SessionID) async throws
    func resize(_ sessionID: SessionID, to size: GridSize) async throws
    func createSession(on deviceID: DeviceID, name: String, workingDirectory: String?) async throws -> SessionDescriptor
}
