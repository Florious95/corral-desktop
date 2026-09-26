import CorralContracts
import CorralMetalTerminal
import CorralServices
import CorralUI
import XCTest

final class HistoricalContractRegressionTests: XCTestCase {
    func testDarkThemeSurfaceTokenAndTextContrast() {
        XCTAssertEqual(DesignTokens.Color.surface0, 0x171B22)
        XCTAssertGreaterThanOrEqual(
            contrastRatio(foreground: DesignTokens.Color.text, background: DesignTokens.Color.surface0),
            7
        )
    }

    func testMultiDeviceBadgeWidthTokenHonorsLegacyCap() {
        XCTAssertEqual(DesignTokens.multiDeviceBadgeMaximumWidthPixels, 64)
        XCTAssertLessThanOrEqual(DesignTokens.multiDeviceBadgeMaximumWidthPixels, 64)
    }

    func testWorkspaceLayoutAcceptsInteriorSplitRatios() {
        for numerator in 1...999 {
            let ratio = Double(numerator) / 1_000
            let layout = WorkspaceLayoutNode.split(
                direction: .horizontal,
                ratio: ratio,
                first: .session(SessionID("left-\(numerator)")),
                second: .session(SessionID("right-\(numerator)"))
            )
            XCTAssertTrue(layout.isValid, "Expected ratio \(ratio) to be valid")
        }
    }

    func testWorkspaceLayoutRejectsNonFiniteAndBoundarySplitRatios() {
        for ratio in [Double.nan, .infinity, -.infinity, -0.01, 0, 1, 1.01] {
            let layout = WorkspaceLayoutNode.split(
                direction: .vertical,
                ratio: ratio,
                first: .session(SessionID("first")),
                second: .session(SessionID("second"))
            )
            XCTAssertFalse(layout.isValid, "Expected ratio \(ratio) to be invalid")
        }
    }

    func testRepeatedTabVisibilitySnapshotsPreserveStageStateAndDoNotPublishResize() {
        let stageID = UUID()
        let viewport = StageViewportRect(x: 12, y: 24, width: 960, height: 640)
        let sample = GeometrySample(
            viewport: viewport,
            backingScale: 2,
            grid: GridSize(rows: 43, columns: 120),
            metricsGeneration: MetricsGeneration(9)
        )
        let layoutGeneration = LayoutGeneration(43)
        let policy = DefaultGeometryPolicy()

        for _ in 0..<10 {
            let hidden = StagePresentation(
                viewportStageID: stageID,
                viewport: viewport,
                layoutGeneration: layoutGeneration,
                metricsGeneration: sample.metricsGeneration,
                visibility: .tabHidden,
                applicationActivity: .active,
                sleepState: .tabHidden
            )
            let visible = StagePresentation(
                viewportStageID: stageID,
                viewport: viewport,
                layoutGeneration: layoutGeneration,
                metricsGeneration: sample.metricsGeneration,
                visibility: .visible,
                applicationActivity: .active,
                sleepState: .active
            )

            XCTAssertFalse(hidden.sleepState.allowsDrawing)
            XCTAssertTrue(visible.sleepState.allowsDrawing)
            XCTAssertEqual(hidden.viewportStageID, visible.viewportStageID)
            XCTAssertEqual(hidden.viewport, visible.viewport)
            XCTAssertEqual(hidden.layoutGeneration, visible.layoutGeneration)
            XCTAssertEqual(hidden.metricsGeneration, visible.metricsGeneration)
            XCTAssertTrue(policy.shouldDebounceViewportDelta(from: sample, to: sample))
            XCTAssertFalse(policy.shouldPublishResize(lastCommittedServerGrid: sample.grid, proposed: sample))
        }
    }

    private func contrastRatio(foreground: UInt32, background: UInt32) -> Double {
        let foregroundLuminance = relativeLuminance(foreground)
        let backgroundLuminance = relativeLuminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ color: UInt32) -> Double {
        let channels = [16, 8, 0].map { shift -> Double in
            let channel = Double((color >> shift) & 0xFF) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
}
