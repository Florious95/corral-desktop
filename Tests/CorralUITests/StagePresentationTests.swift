import CorralContracts
import CorralUI
import XCTest

final class StagePresentationTests: XCTestCase {
    func testStableStagePresentationSeparatesVisibilityAndApplicationFocus() {
        let stageID = UUID()
        let stage = StagePresentation(
            viewportStageID: stageID,
            viewport: StageViewportRect(x: 0, y: 0, width: 800, height: 600),
            layoutGeneration: LayoutGeneration(2),
            metricsGeneration: MetricsGeneration(5),
            visibility: .tabHidden,
            applicationActivity: .inactive,
            sleepState: .tabHidden
        )
        XCTAssertEqual(stage.viewportStageID, stageID)
        XCTAssertFalse(stage.visibility.allowsPresentation)
        XCTAssertTrue(RenderSleepState.applicationInactive.allowsDrawing)
    }
}
