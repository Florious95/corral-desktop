import CorralContracts
import CorralServices
import XCTest

final class GeometryPolicyTests: XCTestCase {
    func testSubTwoPixelNoiseDebouncesButGridAndMetricsChangesDoNot() {
        let policy = DefaultGeometryPolicy()
        let grid = GridSize(rows: 24, columns: 80)
        let old = sample(width: 100, grid: grid, metrics: 1)
        let jitter = sample(width: 101.5, grid: grid, metrics: 1)
        let crossGrid = sample(width: 100.5, grid: GridSize(rows: 24, columns: 81), metrics: 1)
        let fontChange = sample(width: 100, grid: grid, metrics: 2)

        XCTAssertTrue(policy.shouldDebounceViewportDelta(from: old, to: jitter))
        XCTAssertFalse(policy.shouldDebounceViewportDelta(from: old, to: crossGrid))
        XCTAssertFalse(policy.shouldDebounceViewportDelta(from: old, to: fontChange))
        XCTAssertTrue(policy.shouldPublishResize(lastCommittedServerGrid: old.grid, proposed: crossGrid))
    }

    func testDebounceThresholdUsesBackingPixelsForBothViewportDimensions() {
        let policy = DefaultGeometryPolicy()
        let grid = GridSize(rows: 24, columns: 80)
        let old = sample(width: 100, height: 100, scale: 2, grid: grid, metrics: 1)
        let subThreshold = sample(width: 100.75, height: 100.5, scale: 2, grid: grid, metrics: 1)
        let widthAboveThreshold = sample(width: 101.1, height: 100, scale: 2, grid: grid, metrics: 1)
        let heightAboveThreshold = sample(width: 100, height: 101.1, scale: 2, grid: grid, metrics: 1)

        XCTAssertTrue(policy.shouldDebounceViewportDelta(from: old, to: subThreshold))
        XCTAssertFalse(policy.shouldDebounceViewportDelta(from: old, to: widthAboveThreshold))
        XCTAssertFalse(policy.shouldDebounceViewportDelta(from: old, to: heightAboveThreshold))
    }

    func testAuthorityChangeComparesAgainstPreviouslyCommittedServerGrid() {
        let oldGrid = GridSize(rows: 30, columns: 100)
        let newAuthority = DefaultGeometryPolicy(authoritativeGridSize: GridSize(rows: 40, columns: 120))
        let unchangedMeasurement = sample(width: 900, grid: GridSize(rows: 24, columns: 80), metrics: 1)

        XCTAssertTrue(newAuthority.shouldPublishResize(lastCommittedServerGrid: oldGrid, proposed: unchangedMeasurement))
        XCTAssertFalse(newAuthority.shouldPublishResize(lastCommittedServerGrid: GridSize(rows: 40, columns: 120), proposed: unchangedMeasurement))
    }

    func testGridDimensionsHaveSeparateWireRepresentabilityCheck() {
        XCTAssertTrue(GridSize(rows: 65_535, columns: 80).fitsProtocolV1)
        XCTAssertFalse(GridSize(rows: 65_536, columns: 80).fitsProtocolV1)
        XCTAssertFalse(GridSize(rows: 0, columns: 80).fitsProtocolV1)
    }

    private func sample(width: Double, grid: GridSize, metrics: UInt64) -> GeometrySample {
        sample(width: width, height: 100, scale: 1, grid: grid, metrics: metrics)
    }

    private func sample(width: Double, height: Double, scale: Double, grid: GridSize, metrics: UInt64) -> GeometrySample {
        GeometrySample(
            viewport: StageViewportRect(x: 0, y: 0, width: width, height: height),
            backingScale: scale,
            grid: grid,
            metricsGeneration: MetricsGeneration(metrics)
        )
    }
}
