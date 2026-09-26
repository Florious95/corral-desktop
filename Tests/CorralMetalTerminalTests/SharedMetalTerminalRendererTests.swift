import CorralContracts
import CorralMetalTerminal
import Metal
import XCTest

final class SharedMetalTerminalRendererTests: XCTestCase {
    @MainActor
    func testHiddenStageBatchReturnsDeferredContractReceipt() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal is unavailable on this machine") }
        let renderer = try SharedMetalTerminalRenderer(device: device)
        let stageID = UUID()
        let request = StageFrameRequest(
            stageID: stageID,
            layoutGeneration: LayoutGeneration(1),
            metricsGeneration: MetricsGeneration(1),
            visibility: .tabHidden,
            panes: []
        )

        let receipt = await renderer.render(request)
        let maximumInFlightFrames = await renderer.maximumInFlightFrames
        XCTAssertEqual(maximumInFlightFrames, 3)
        XCTAssertEqual(receipt.stageID, stageID)
        XCTAssertEqual(receipt.layoutGeneration, LayoutGeneration(1))
        XCTAssertEqual(receipt.outcome, .deferred)
    }

    func testSinglePaneMapsPointsToPhysicalViewportAndScissor() throws {
        let mapped = try XCTUnwrap(MetalViewportMapper.map(
            StageViewportRect(x: 10, y: 20, width: 300, height: 150),
            stage: MetalStagePixelSize(width: 1600, height: 1200),
            backingScale: 2
        ))

        XCTAssertEqual(mapped.viewport.x, 20)
        XCTAssertEqual(mapped.viewport.y, 40)
        XCTAssertEqual(mapped.viewport.width, 600)
        XCTAssertEqual(mapped.viewport.height, 300)
        XCTAssertEqual(mapped.scissor.x, 20)
        XCTAssertEqual(mapped.scissor.y, 40)
        XCTAssertEqual(mapped.scissor.width, 600)
        XCTAssertEqual(mapped.scissor.height, 300)
    }

    func testSideBySidePanesPartitionStageWithoutScissorOverlap() throws {
        let stage = MetalStagePixelSize(width: 200, height: 80)
        let left = try XCTUnwrap(MetalViewportMapper.map(
            StageViewportRect(x: 0, y: 0, width: 50, height: 40), stage: stage, backingScale: 2
        ))
        let right = try XCTUnwrap(MetalViewportMapper.map(
            StageViewportRect(x: 50, y: 0, width: 50, height: 40), stage: stage, backingScale: 2
        ))

        XCTAssertEqual(left.scissor.x, 0)
        XCTAssertEqual(left.scissor.width, 100)
        XCTAssertEqual(right.scissor.x, 100)
        XCTAssertEqual(right.scissor.width, 100)
        XCTAssertEqual(left.scissor.x + left.scissor.width, right.scissor.x)
        XCTAssertEqual(left.viewport.width, 100)
        XCTAssertEqual(right.viewport.x, 100)
    }

    func testScissorClipsOffstagePaneButKeepsViewportGeometry() throws {
        let mapped = try XCTUnwrap(MetalViewportMapper.map(
            StageViewportRect(x: -10, y: 5, width: 30, height: 20),
            stage: MetalStagePixelSize(width: 200, height: 100),
            backingScale: 2
        ))

        XCTAssertEqual(mapped.viewport.x, -20)
        XCTAssertEqual(mapped.viewport.width, 60)
        XCTAssertEqual(mapped.scissor.x, 0)
        XCTAssertEqual(mapped.scissor.width, 40)
        XCTAssertEqual(mapped.scissor.y, 10)
        XCTAssertEqual(mapped.scissor.height, 40)
    }

    func testInvalidOrInvisibleViewportIsRejected() {
        let stage = MetalStagePixelSize(width: 100, height: 100)
        XCTAssertNil(MetalViewportMapper.map(
            StageViewportRect(x: .nan, y: 0, width: 10, height: 10), stage: stage, backingScale: 1
        ))
        XCTAssertNil(MetalViewportMapper.map(
            StageViewportRect(x: 100, y: 10, width: 10, height: 10), stage: stage, backingScale: 1
        ))
        XCTAssertNil(MetalViewportMapper.map(
            StageViewportRect(x: 0, y: 0, width: 10, height: 10), stage: stage, backingScale: 0
        ))
    }

    func testDirtyGenerationSubmitsOnceAndIgnoresStaleWork() {
        var scheduler = MetalRenderFrameScheduler(paused: false)
        XCTAssertFalse(scheduler.shouldSubmit)

        scheduler.invalidate(generation: DirtyGeneration(4))
        XCTAssertTrue(scheduler.shouldSubmit)
        scheduler.markSubmitted()
        XCTAssertEqual(scheduler.submittedGeneration, DirtyGeneration(4))
        XCTAssertFalse(scheduler.shouldSubmit)

        scheduler.invalidate(generation: DirtyGeneration(3))
        XCTAssertFalse(scheduler.shouldSubmit)
        scheduler.invalidate(generation: DirtyGeneration(4), force: true)
        XCTAssertTrue(scheduler.shouldSubmit)
    }

    func testPausedUpdatesCoalesceUntilResume() {
        var scheduler = MetalRenderFrameScheduler(paused: false)
        scheduler.markSubmitted()
        scheduler.pause()
        scheduler.invalidate(generation: DirtyGeneration(2))
        scheduler.invalidate(generation: DirtyGeneration(5))
        XCTAssertFalse(scheduler.shouldSubmit)
        XCTAssertEqual(scheduler.latestGeneration, DirtyGeneration(5))

        scheduler.resume()
        XCTAssertTrue(scheduler.shouldSubmit)
        scheduler.markSubmitted()
        XCTAssertEqual(scheduler.submittedGeneration, DirtyGeneration(5))
        XCTAssertFalse(scheduler.shouldSubmit)
    }

    func testContractSleepStatesPauseAndResumeTheScheduler() {
        var scheduler = MetalRenderFrameScheduler(paused: false)
        scheduler.markSubmitted()
        scheduler.setSleepState(.tabHidden)
        scheduler.invalidate(generation: DirtyGeneration(1))
        XCTAssertFalse(scheduler.shouldSubmit)
        scheduler.setSleepState(.active)
        XCTAssertTrue(scheduler.shouldSubmit)
    }

    func testCursorBlinkOnlySubmitsWhenAFrameIsDue() {
        var scheduler = MetalRenderFrameScheduler(paused: false)
        scheduler.setCursorBlinking(true)
        XCTAssertFalse(scheduler.shouldSubmit)

        scheduler.cursorBlinkDidTick()
        XCTAssertTrue(scheduler.shouldSubmit)
        scheduler.markSubmitted()
        XCTAssertFalse(scheduler.shouldSubmit)

        scheduler.cursorBlinkDidTick()
        XCTAssertTrue(scheduler.shouldSubmit)
        scheduler.setCursorBlinking(false)
        XCTAssertFalse(scheduler.shouldSubmit)
    }
}
