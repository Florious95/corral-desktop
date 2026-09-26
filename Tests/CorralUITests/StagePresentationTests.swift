import CorralContracts
import CorralMetalTerminal
import CorralUI
import XCTest

private struct StubTerminalRenderer: TerminalRendering {
    func present(_ snapshot: TerminalGridSnapshot, in viewport: StageViewportRect, dirtyGeneration: DirtyGeneration) async {}
    func setSleepState(_ state: RenderSleepState) async {}
}

final class StagePresentationTests: XCTestCase {
    func testStageVisibilityOnlyControlsRendering() {
        let stage = StagePresentation(
            viewportStageID: UUID(),
            viewport: StageViewportRect(x: 0, y: 0, width: 800, height: 600),
            sleepState: .tabHidden,
            dirtyGeneration: .initial
        )
        let composition = CorralUIComposition(renderer: StubTerminalRenderer())

        XCTAssertFalse(stage.sleepState.allowsDrawing)
        XCTAssertNotNil(composition.geometryPolicy)
        XCTAssertNotNil(composition.renderer)
    }
}
