import CorralContracts
import CorralServices
import XCTest

final class GeometryPolicyTests: XCTestCase {
    func testSubTwoPixelJitterIsDebouncedButCrossGridChangeIsNot() {
        let policy = DefaultGeometryPolicy()
        let old = sample(width: 100, grid: GridSize(rows: 24, columns: 80))
        let jitter = sample(width: 101.5, grid: GridSize(rows: 24, columns: 80))
        let crossGrid = sample(width: 100.5, grid: GridSize(rows: 24, columns: 81))

        XCTAssertTrue(policy.shouldDebounceViewportDelta(from: old, to: jitter))
        XCTAssertFalse(policy.shouldDebounceViewportDelta(from: old, to: crossGrid))
        XCTAssertTrue(policy.shouldPublishResize(from: old, to: crossGrid))
    }

    func testExactlyTwoPixelsIsNotDebouncedAndAuthoritativeSizeWins() {
        let policy = DefaultGeometryPolicy(authoritativeGridSize: GridSize(rows: 40, columns: 120))
        let old = sample(width: 100, grid: GridSize(rows: 24, columns: 80))
        let changed = sample(width: 102, grid: GridSize(rows: 25, columns: 81))

        XCTAssertEqual(policy.resolvedGridSize(proposed: changed.grid), GridSize(rows: 40, columns: 120))
        XCTAssertFalse(policy.shouldDebounceViewportDelta(from: old, to: changed))
        XCTAssertFalse(policy.shouldPublishResize(from: old, to: changed))
    }

    private func sample(width: Double, grid: GridSize) -> GeometrySample {
        GeometrySample(
            viewport: StageViewportRect(x: 0, y: 0, width: width, height: 100),
            backingScale: 1,
            grid: grid,
            metricsGeneration: 1
        )
    }
}
