import CorralContracts
import Foundation

/// Stable UI value for one owning window/stage; visibility is separate from app focus and session lifetime.
public struct StagePresentation: ViewportStageIdentifiable, Sendable {
    public let viewportStageID: UUID
    public let viewport: StageViewportRect
    public let layoutGeneration: LayoutGeneration
    public let metricsGeneration: MetricsGeneration
    public let visibility: StageVisibility
    public let applicationActivity: ApplicationActivity
    public let sleepState: RenderSleepState

    public init(
        viewportStageID: UUID,
        viewport: StageViewportRect,
        layoutGeneration: LayoutGeneration,
        metricsGeneration: MetricsGeneration,
        visibility: StageVisibility,
        applicationActivity: ApplicationActivity,
        sleepState: RenderSleepState
    ) {
        self.viewportStageID = viewportStageID
        self.viewport = viewport
        self.layoutGeneration = layoutGeneration
        self.metricsGeneration = metricsGeneration
        self.visibility = visibility
        self.applicationActivity = applicationActivity
        self.sleepState = sleepState
    }
}
