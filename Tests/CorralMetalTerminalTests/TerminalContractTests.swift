import CorralContracts
import XCTest

final class TerminalContractTests: XCTestCase {
    func testAtlasBudgetAndEvictionSentinel() {
        let budget = AtlasMemoryBudget(maximumBytes: 1024, maximumPages: 2)
        XCTAssertTrue(budget.allowsAllocation(currentBytes: 512, additionalBytes: 512))
        XCTAssertFalse(budget.allowsAllocation(currentBytes: UInt64.max, additionalBytes: 1))
        XCTAssertTrue(budget.allowsPageAllocation(currentPages: 1))
        XCTAssertFalse(budget.allowsPageAllocation(currentPages: 2))
        XCTAssertTrue(AtlasCoordinates.zero.isZeroed)
    }

    func testHiddenStagesSleepWithoutChangingSessionState() {
        XCTAssertTrue(RenderSleepState.active.allowsDrawing)
        XCTAssertFalse(RenderSleepState.tabHidden.allowsDrawing)
        XCTAssertFalse(RenderSleepState.applicationInactive.allowsDrawing)
    }
}
