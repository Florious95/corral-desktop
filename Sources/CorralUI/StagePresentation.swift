import CorralContracts
import Foundation
import CorralMetalTerminal
import CorralServices

public struct StagePresentation: ViewportStageIdentifiable, Sendable {
    public let viewportStageID: UUID
    public let viewport: StageViewportRect
    public let sleepState: RenderSleepState
    public let dirtyGeneration: DirtyGeneration

    public init(
        viewportStageID: UUID = UUID(),
        viewport: StageViewportRect,
        sleepState: RenderSleepState,
        dirtyGeneration: DirtyGeneration
    ) {
        self.viewportStageID = viewportStageID
        self.viewport = viewport
        self.sleepState = sleepState
        self.dirtyGeneration = dirtyGeneration
    }
}

/// Injected policy and renderer are shared by every stage; tab visibility only changes presentation state.
public struct CorralUIComposition: Sendable {
    public let geometryPolicy: any GeometryPolicy
    public let renderer: any TerminalRendering

    public init(
        renderer: any TerminalRendering,
        geometryPolicy: any GeometryPolicy = DefaultGeometryPolicy()
    ) {
        self.renderer = renderer
        self.geometryPolicy = geometryPolicy
    }
}
