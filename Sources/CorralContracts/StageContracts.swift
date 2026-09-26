import Foundation

public protocol ViewportStageIdentifiable: Sendable {
    /// Allocated by the owning window lifecycle and stable across value updates.
    var viewportStageID: UUID { get }
}

public struct LayoutGeneration: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct MetricsGeneration: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct DirtyGeneration: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let initial = DirtyGeneration(0)
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Returns nil rather than wrapping and violating the generation's total order.
    public func next() -> Self? {
        guard rawValue < UInt64.max else { return nil }
        return DirtyGeneration(rawValue + 1)
    }
}

public enum StageVisibility: String, Codable, Sendable {
    case visible
    case tabHidden
    case windowMinimized
    case occluded

    public var allowsPresentation: Bool { self == .visible }
}

/// Application focus is independent from visibility: an inactive app can still have visible windows.
public enum ApplicationActivity: String, Codable, Sendable {
    case active
    case inactive
}

/// Top-left-origin stage coordinates in points, not device pixels.
public struct StageViewportRect: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite && width >= 0 && height >= 0
    }
}

public enum RenderSleepState: String, Codable, Sendable {
    case active
    case paused
    case tabHidden
    case windowMinimized
    case occluded
    case applicationInactive

    /// Focus loss alone never sleeps a visible stage.
    public var allowsDrawing: Bool { self == .active || self == .applicationInactive }
}

public struct PaneFrameSnapshot: Equatable, Sendable {
    public let paneID: UUID
    public let session: SessionKey
    public let viewport: StageViewportRect
    public let contentGeneration: DirtyGeneration
    public let snapshot: TerminalGridSnapshot

    public init(paneID: UUID, session: SessionKey, viewport: StageViewportRect, contentGeneration: DirtyGeneration, snapshot: TerminalGridSnapshot) {
        self.paneID = paneID
        self.session = session
        self.viewport = viewport
        self.contentGeneration = contentGeneration
        self.snapshot = snapshot
    }
}

/// One complete visible-window batch; hiding a tab changes presentation only, never VT/session lifetime.
public struct StageFrameRequest: Equatable, Sendable {
    public let stageID: UUID
    public let layoutGeneration: LayoutGeneration
    public let metricsGeneration: MetricsGeneration
    public let visibility: StageVisibility
    public let panes: [PaneFrameSnapshot]

    public init(stageID: UUID, layoutGeneration: LayoutGeneration, metricsGeneration: MetricsGeneration, visibility: StageVisibility, panes: [PaneFrameSnapshot]) {
        self.stageID = stageID
        self.layoutGeneration = layoutGeneration
        self.metricsGeneration = metricsGeneration
        self.visibility = visibility
        self.panes = panes
    }

    public var isValid: Bool {
        let paneIDs = panes.map(\.paneID)
        return Set(paneIDs).count == paneIDs.count &&
            panes.allSatisfy { $0.viewport.isValid && $0.snapshot.isValid && $0.snapshot.generation == $0.contentGeneration }
    }
}

public struct PaneFrameReceipt: Equatable, Sendable {
    public let paneID: UUID
    public let contentGeneration: DirtyGeneration

    public init(paneID: UUID, contentGeneration: DirtyGeneration) {
        self.paneID = paneID
        self.contentGeneration = contentGeneration
    }
}

public enum FrameFailure: Equatable, Sendable {
    case noDrawable
    case commandBuffer(String)
    case invalidRequest
}

public enum FrameOutcome: Equatable, Sendable {
    case submitted
    case completed
    case deferred
    case failed(FrameFailure)
}

/// A receipt describes submission/completion, not display scanout. Stale layout receipts never advance presentation.
public struct FrameReceipt: Equatable, Sendable {
    public let submissionID: UUID
    public let stageID: UUID
    public let layoutGeneration: LayoutGeneration
    public let metricsGeneration: MetricsGeneration
    public let visibility: StageVisibility
    public let panes: [PaneFrameReceipt]
    public let outcome: FrameOutcome

    public init(submissionID: UUID, stageID: UUID, layoutGeneration: LayoutGeneration, metricsGeneration: MetricsGeneration, visibility: StageVisibility, panes: [PaneFrameReceipt], outcome: FrameOutcome) {
        self.submissionID = submissionID
        self.stageID = stageID
        self.layoutGeneration = layoutGeneration
        self.metricsGeneration = metricsGeneration
        self.visibility = visibility
        self.panes = panes
        self.outcome = outcome
    }

    public func presentedGeneration(
        for paneID: UUID,
        currentStageID: UUID,
        currentLayout: LayoutGeneration,
        currentMetrics: MetricsGeneration,
        parsedGeneration: DirtyGeneration
    ) -> DirtyGeneration? {
        guard outcome == .completed, visibility == .visible,
              stageID == currentStageID,
              layoutGeneration == currentLayout,
              metricsGeneration == currentMetrics,
              let pane = panes.first(where: { $0.paneID == paneID }),
              pane.contentGeneration <= parsedGeneration else { return nil }
        return pane.contentGeneration
    }
}

public protocol StageRendererProtocol: Sendable {
    /// Bounded in-flight command buffers for this shared renderer/resource domain.
    var maximumInFlightFrames: UInt32 { get async }
    /// Receives one complete stage batch rather than one independently queued call per pane.
    func render(_ request: StageFrameRequest) async -> FrameReceipt
    func setSleepState(_ state: RenderSleepState, for stageID: UUID) async
}
