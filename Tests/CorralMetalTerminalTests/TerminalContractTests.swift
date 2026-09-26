import CorralContracts
import XCTest

final class TerminalContractTests: XCTestCase {
    private let foreground = TerminalColor.indexed(7)
    private let background = TerminalColor.indexed(0)

    func testGraphemeClustersAndWideContinuationAreRepresentable() {
        let combining = TerminalCell(content: .cluster("e\u{301}", columns: .one), foreground: foreground, background: background)
        let wide = TerminalCell(content: .cluster("👩‍💻", columns: .two), foreground: foreground, background: background)
        let continuation = TerminalCell(content: .continuation, foreground: foreground, background: background)
        let blank = TerminalCell(content: .blank, foreground: foreground, background: background)
        let snapshot = TerminalGridSnapshot(
            size: GridSize(rows: 1, columns: 4),
            cells: [combining, wide, continuation, blank],
            cursor: CursorDescriptor(row: 0, column: 3),
            generation: DirtyGeneration(4)
        )

        XCTAssertTrue(snapshot.isValid)
        XCTAssertEqual(snapshot.cells[0].content, .cluster("e\u{301}", columns: .one))
        XCTAssertEqual(snapshot.cells[1].content, .cluster("👩‍💻", columns: .two))
        XCTAssertEqual(snapshot.cells[2].content, .continuation)
    }

    func testSnapshotRejectsOrphanContinuationInvalidCursorAndRightEdgeWideCell() {
        let blank = TerminalCell(content: .blank, foreground: foreground, background: background)
        let continuation = TerminalCell(content: .continuation, foreground: foreground, background: background)
        let wide = TerminalCell(content: .cluster("界", columns: .two), foreground: foreground, background: background)

        XCTAssertFalse(snapshot(cells: [continuation, blank], columns: 2, cursor: CursorDescriptor(row: 0, column: 0)).isValid)
        XCTAssertFalse(snapshot(cells: [blank, wide], columns: 2, cursor: CursorDescriptor(row: 0, column: 0)).isValid)
        XCTAssertFalse(snapshot(cells: [blank, blank], columns: 2, cursor: CursorDescriptor(row: 0, column: 2)).isValid)
        XCTAssertFalse(snapshot(cells: [blank, blank], columns: 2, cursor: CursorDescriptor(row: 0, column: 0, wrapPending: true)).isValid)
    }

    func testSnapshotsRespectExplicitMemoryBudgets() {
        let blank = TerminalCell(content: .blank, foreground: foreground, background: background)
        let snapshot = snapshot(cells: [blank, blank], columns: 2, cursor: CursorDescriptor(row: 0, column: 0))
        XCTAssertTrue(snapshot.isValid(with: TerminalSnapshotBudget(maximumCells: 2, maximumClusterBytesTotal: 0)))
        XCTAssertFalse(snapshot.isValid(with: TerminalSnapshotBudget(maximumCells: 1, maximumClusterBytesTotal: 100)))
    }

    func testAtlasBudgetAndSleepStateContracts() {
        let budget = AtlasMemoryBudget(maximumGPUBytes: 1024, maximumPages: 2, maximumCPUShadowBytes: 512)
        XCTAssertEqual(budget.maximumGPUBytes, 1024)
        XCTAssertEqual(budget.maximumPages, 2)
        XCTAssertFalse(RenderSleepState.paused.allowsDrawing)
        XCTAssertFalse(RenderSleepState.tabHidden.allowsDrawing)
        XCTAssertTrue(RenderSleepState.applicationInactive.allowsDrawing)
        XCTAssertNil(DirtyGeneration(UInt64.max).next())

        let first = GlyphKey(fontInstanceID: "primary:Regular", glyphID: 42, variationSignature: "", rasterWidthPixels: 12, rasterHeightPixels: 16, rasterScale256: 256)
        let fallback = GlyphKey(fontInstanceID: "emoji:fallback", glyphID: 42, variationSignature: "", rasterWidthPixels: 12, rasterHeightPixels: 16, rasterScale256: 256)
        XCTAssertNotEqual(first, fallback)
        let domain = UUID()
        let resource = AtlasResourceIdentity(deviceDomainID: domain, resourceID: UUID(), generation: 3)
        let nextGeneration = AtlasResourceIdentity(deviceDomainID: domain, resourceID: resource.resourceID, generation: 4)
        XCTAssertNotEqual(resource, nextGeneration)
        let location = GlyphLocation(resource: resource, coordinates: AtlasCoordinates(page: 0, x: 0, y: 0, width: 12, height: 16))
        let lease = FrameAtlasLease(leaseID: UUID(), resources: [resource], locations: [first: location])
        XCTAssertEqual(lease.locations[first]?.resource, resource)
    }

    func testFrameReceiptCannotClearNewerContentOrNewLayoutDirtyState() {
        let paneID = UUID()
        let stageID = UUID()
        let receipt = FrameReceipt(
            submissionID: UUID(),
            stageID: stageID,
            layoutGeneration: LayoutGeneration(3),
            metricsGeneration: MetricsGeneration(7),
            visibility: .visible,
            panes: [PaneFrameReceipt(paneID: paneID, contentGeneration: DirtyGeneration(10))],
            outcome: .completed
        )
        XCTAssertEqual(receipt.presentedGeneration(for: paneID, currentStageID: stageID, currentLayout: LayoutGeneration(3), currentMetrics: MetricsGeneration(7), parsedGeneration: DirtyGeneration(11)), DirtyGeneration(10))
        XCTAssertNil(receipt.presentedGeneration(for: paneID, currentStageID: UUID(), currentLayout: LayoutGeneration(3), currentMetrics: MetricsGeneration(7), parsedGeneration: DirtyGeneration(11)))
        XCTAssertNil(receipt.presentedGeneration(for: paneID, currentStageID: stageID, currentLayout: LayoutGeneration(4), currentMetrics: MetricsGeneration(7), parsedGeneration: DirtyGeneration(11)))
        XCTAssertNil(receipt.presentedGeneration(for: paneID, currentStageID: stageID, currentLayout: LayoutGeneration(3), currentMetrics: MetricsGeneration(7), parsedGeneration: DirtyGeneration(9)))
        let hiddenReceipt = FrameReceipt(
            submissionID: UUID(),
            stageID: stageID,
            layoutGeneration: LayoutGeneration(3),
            metricsGeneration: MetricsGeneration(7),
            visibility: .tabHidden,
            panes: [PaneFrameReceipt(paneID: paneID, contentGeneration: DirtyGeneration(11))],
            outcome: .completed
        )
        XCTAssertNil(hiddenReceipt.presentedGeneration(for: paneID, currentStageID: stageID, currentLayout: LayoutGeneration(3), currentMetrics: MetricsGeneration(7), parsedGeneration: DirtyGeneration(11)))
    }

    private func snapshot(cells: [TerminalCell], columns: Int, cursor: CursorDescriptor) -> TerminalGridSnapshot {
        TerminalGridSnapshot(size: GridSize(rows: 1, columns: columns), cells: cells, cursor: cursor, generation: .initial)
    }
}
