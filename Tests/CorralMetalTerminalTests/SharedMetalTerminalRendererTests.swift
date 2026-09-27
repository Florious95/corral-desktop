import CorralContracts
import Metal
import XCTest
@testable import CorralMetalTerminal

final class SharedMetalTerminalRendererTests: XCTestCase {
    @MainActor
    func testHiddenStageBatchReturnsDeferredContractReceipt() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal is unavailable on this machine") }
        let renderer = try SharedMetalTerminalRenderer(device: device)
        XCTAssertTrue(renderer.glyphAtlasPool === GlyphAtlasPool.shared)
        XCTAssertEqual(renderer.appearance, .dark)
        renderer.setAppearance(.light)
        XCTAssertEqual(renderer.palette.background.hexRGB, "#fbfaf8")
        renderer.setAppearance(.dark)
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

    @MainActor
    func testOffscreenMetalPixelsKeepGlyphUprightAndRowZeroAtTop() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal is unavailable on this machine") }
        let atlas = GlyphAtlasPool(device: device, memoryBudget: .appDefault, pageSize: 128)
        let renderer = try SharedMetalTerminalRenderer(device: device, glyphAtlas: atlas)
        let width = 64
        let height = 48
        renderer.configureStage(sizeInPoints: CGSize(width: width, height: height), backingScale: 1)

        let foreground = TerminalColor.rgba(RGBAColor(red: 255, green: 255, blue: 255))
        let background = TerminalColor.rgba(RGBAColor(red: 0, green: 0, blue: 0))
        let cells = (0..<8).map { index in
            TerminalCell(
                content: index == 0 ? .cluster("L", columns: .one) : .blank,
                foreground: foreground,
                background: background
            )
        }
        let generation = DirtyGeneration(1)
        let snapshot = TerminalGridSnapshot(
            size: GridSize(rows: 2, columns: 4),
            cells: cells,
            cursor: CursorDescriptor(row: 0, column: 0, isVisible: false),
            generation: generation
        )
        let pane = PaneFrameSnapshot(
            paneID: UUID(),
            session: SessionKey(deviceID: DeviceID("orientation-test"), reference: try SessionReference("session")),
            viewport: StageViewportRect(x: 0, y: 0, width: Double(width), height: Double(height)),
            contentGeneration: generation,
            snapshot: snapshot
        )
        let request = StageFrameRequest(
            stageID: UUID(),
            layoutGeneration: LayoutGeneration(1),
            metricsGeneration: MetricsGeneration(1),
            visibility: .visible,
            panes: [pane]
        )
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        let receipt = await renderer.renderOffscreenForTesting(request, into: output)
        XCTAssertEqual(receipt.outcome, FrameOutcome.completed)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            output.getBytes(
                buffer.baseAddress!,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        var rowInk = [Int](repeating: 0, count: 24)
        var columnInk = [Int](repeating: 0, count: 16)
        for y in 0..<24 {
            for x in 0..<16 {
                let offset = y * width * 4 + x * 4
                if pixels[offset] > 96 && pixels[offset + 1] > 96 && pixels[offset + 2] > 96 {
                    rowInk[y] += 1
                    columnInk[x] += 1
                }
            }
        }
        let activeRows = rowInk.indices.filter { rowInk[$0] > 0 }
        XCTAssertFalse(activeRows.isEmpty, "offscreen texture must contain the atlas glyph")
        let firstRow = try XCTUnwrap(activeRows.first)
        let lastRow = try XCTUnwrap(activeRows.last)
        XCTAssertLessThan(lastRow, 24, "row zero belongs in the top half of the stage")
        XCTAssertGreaterThan(rowInk[lastRow], rowInk[firstRow], "upright L has its wider foot at the bottom")
        XCTAssertGreaterThan(columnInk[0..<8].reduce(0, +), columnInk[8..<16].reduce(0, +), "L's vertical stem stays on the left")
    }

    @MainActor
    func testStageResizeProducesAFullSizeFreshDrawable() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal is unavailable on this machine") }
        let renderer = try SharedMetalTerminalRenderer(device: device)
        let layer = renderer.stageLayer
        renderer.configureStage(sizeInPoints: CGSize(width: 64, height: 48), backingScale: 1)
        let stageID = UUID()
        let firstRequest = StageFrameRequest(
            stageID: stageID,
            layoutGeneration: LayoutGeneration(1),
            metricsGeneration: MetricsGeneration(1),
            visibility: .visible,
            panes: []
        )
        let firstOutput = try makeOutputTexture(device: device, width: 64, height: 48)
        let firstReceipt = await renderer.renderOffscreenForTesting(firstRequest, into: firstOutput)
        XCTAssertEqual(firstReceipt.outcome, FrameOutcome.completed)

        renderer.configureStage(sizeInPoints: CGSize(width: 80, height: 48), backingScale: 1)
        XCTAssertTrue(renderer.stageLayer === layer)
        XCTAssertEqual(renderer.stageLayer.drawableSize, CGSize(width: 80, height: 48))
        let resizedRequest = StageFrameRequest(
            stageID: stageID,
            layoutGeneration: LayoutGeneration(2),
            metricsGeneration: MetricsGeneration(1),
            visibility: .visible,
            panes: []
        )
        let resizedOutput = try makeOutputTexture(device: device, width: 80, height: 48)
        let receipt = await renderer.renderOffscreenForTesting(resizedRequest, into: resizedOutput)
        XCTAssertEqual(receipt.outcome, FrameOutcome.completed)

        var pixels = [UInt8](repeating: 0, count: 80 * 48 * 4)
        pixels.withUnsafeMutableBytes { buffer in
            resizedOutput.getBytes(buffer.baseAddress!, bytesPerRow: 80 * 4,
                                  from: MTLRegionMake2D(0, 0, 80, 48), mipmapLevel: 0)
        }
        let rightEdge = (24 * 80 + 79) * 4
        XCTAssertEqual(Array(pixels[rightEdge..<(rightEdge + 3)]), [21, 17, 15], "new drawable is cleared across the expanded stage")
    }

    @MainActor
    func testOffscreenCJKWideCellUsesOneBackgroundSpan() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal is unavailable on this machine") }
        let renderer = try SharedMetalTerminalRenderer(
            device: device,
            glyphAtlas: GlyphAtlasPool(device: device, memoryBudget: .appDefault, pageSize: 128)
        )
        let width = 80
        let height = 32
        renderer.configureStage(sizeInPoints: CGSize(width: width, height: height), backingScale: 1)

        let white = TerminalColor.rgba(RGBAColor(red: 255, green: 255, blue: 255))
        let black = TerminalColor.rgba(RGBAColor(red: 0, green: 0, blue: 0))
        let red = TerminalColor.rgba(RGBAColor(red: 255, green: 0, blue: 0))
        let cells = [
            TerminalCell(content: .cluster("界", columns: .two), foreground: white, background: black),
            TerminalCell(content: .continuation, foreground: white, background: red),
            TerminalCell(content: .blank, foreground: white, background: black),
            TerminalCell(content: .blank, foreground: white, background: black)
        ]
        let generation = DirtyGeneration(1)
        let snapshot = TerminalGridSnapshot(
            size: GridSize(rows: 1, columns: 4),
            cells: cells,
            cursor: CursorDescriptor(row: 0, column: 0, isVisible: false),
            generation: generation
        )
        let pane = PaneFrameSnapshot(
            paneID: UUID(),
            session: SessionKey(deviceID: DeviceID("cjk-span-test"), reference: try SessionReference("session")),
            viewport: StageViewportRect(x: 0, y: 0, width: Double(width), height: Double(height)),
            contentGeneration: generation,
            snapshot: snapshot
        )
        let request = StageFrameRequest(
            stageID: UUID(),
            layoutGeneration: LayoutGeneration(1),
            metricsGeneration: MetricsGeneration(1),
            visibility: .visible,
            panes: [pane]
        )
        let output = try makeOutputTexture(device: device, width: width, height: height)
        let receipt = await renderer.renderOffscreenForTesting(request, into: output)
        XCTAssertEqual(receipt.outcome, .completed)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            output.getBytes(buffer.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let cleanSpacerPixel = (1 * width + 39) * 4
        XCTAssertEqual(Array(pixels[cleanSpacerPixel..<(cleanSpacerPixel + 3)]), [0, 0, 0],
                       "the wide leading cell background must cover both columns; no spacer-color step")
        let rightHalfGlyphPixels = (0..<height).reduce(into: 0) { count, y in
            for x in 20..<40 {
                let offset = (y * width + x) * 4
                if pixels[offset] > 96 && pixels[offset + 1] > 96 && pixels[offset + 2] > 96 { count += 1 }
            }
        }
        XCTAssertGreaterThan(rightHalfGlyphPixels, 0, "CJK glyph ink must still reach the second cell")
    }

    @MainActor
    func testVisiblePaneSamplesSharedAtlasForSingleWideAndZWJGraphemes() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal is unavailable on this machine") }
        let atlas = GlyphAtlasPool(device: device, memoryBudget: .appDefault, pageSize: 128)
        let renderer = try SharedMetalTerminalRenderer(device: device, glyphAtlas: atlas)
        renderer.configureStage(sizeInPoints: CGSize(width: 160, height: 32), backingScale: 1)

        let foreground = TerminalColor.rgba(RGBAColor(red: 230, green: 230, blue: 230))
        let background = TerminalColor.rgba(RGBAColor(red: 20, green: 20, blue: 20))
        let cells = [
            TerminalCell(content: .cluster("A", columns: .one), foreground: foreground, background: background),
            TerminalCell(content: .cluster("界", columns: .two), foreground: foreground, background: background),
            TerminalCell(content: .continuation, foreground: foreground, background: background),
            TerminalCell(content: .cluster("👩‍👩‍👧‍👦", columns: .two), foreground: foreground, background: background),
            TerminalCell(content: .continuation, foreground: foreground, background: background)
        ]
        let generation = DirtyGeneration(1)
        let snapshot = TerminalGridSnapshot(
            size: GridSize(rows: 1, columns: 5),
            cells: cells,
            cursor: CursorDescriptor(row: 0, column: 0),
            generation: generation
        )
        let paneID = UUID()
        let pane = PaneFrameSnapshot(
            paneID: paneID,
            session: SessionKey(deviceID: DeviceID("renderer-test"), reference: try SessionReference("session")),
            viewport: StageViewportRect(x: 0, y: 0, width: 160, height: 32),
            contentGeneration: generation,
            snapshot: snapshot
        )
        let request = StageFrameRequest(
            stageID: UUID(),
            layoutGeneration: LayoutGeneration(1),
            metricsGeneration: MetricsGeneration(1),
            visibility: .visible,
            panes: [pane]
        )

        let receipt = await renderer.render(request)
        XCTAssertEqual(receipt.outcome, .completed)
        XCTAssertGreaterThanOrEqual(renderer.statistics.lastFrameReferencedAtlasPages, 2)
        XCTAssertEqual(renderer.statistics.lastFrameSampledGlyphs, 3)
        XCTAssertGreaterThan(renderer.statistics.metalDrawCalls, 0)
        XCTAssertEqual(renderer.statistics.fullStageBitmapUploads, 0)
        XCTAssertEqual(renderer.statistics.atlasFrameLeasesAcquired, 1)
        XCTAssertEqual(renderer.statistics.atlasFrameLeasesReleased, 1)
        XCTAssertGreaterThanOrEqual(atlas.statistics.rasterizedGlyphs, 3)

        let idleReceipt = await renderer.render(request)
        XCTAssertEqual(idleReceipt.outcome, .deferred)
        XCTAssertEqual(renderer.statistics.submittedCommandBuffers, 1)
    }

    func testCellGridTopMapsToViewportTopInMetalNDC() throws {
        let mapping = try XCTUnwrap(MetalViewportMapper.map(
            StageViewportRect(x: 10, y: 20, width: 100, height: 60),
            stage: MetalStagePixelSize(width: 300, height: 200),
            backingScale: 1
        ))
        let viewport = mapping.viewport
        let topLeft = viewport.normalizedDevicePosition(x: viewport.x, y: viewport.y)
        let bottomRight = viewport.normalizedDevicePosition(x: viewport.x + viewport.width, y: viewport.y + viewport.height)

        XCTAssertEqual(topLeft.x, -1, accuracy: 0.0001)
        XCTAssertEqual(topLeft.y, 1, accuracy: 0.0001)
        XCTAssertEqual(bottomRight.x, 1, accuracy: 0.0001)
        XCTAssertEqual(bottomRight.y, -1, accuracy: 0.0001)
    }

    func testGlyphAtlasUVMatchesTopDownTextureRows() throws {
        let uv = try XCTUnwrap(MetalAtlasUVMapper.map(
            coordinates: AtlasCoordinates(page: 0, x: 7, y: 13, width: 4, height: 6),
            textureSize: MetalStagePixelSize(width: 64, height: 128)
        ))

        XCTAssertEqual(uv.topLeft.x, Float(7.5 / 64), accuracy: 0.0001)
        XCTAssertEqual(uv.topLeft.y, Float(13.5 / 128), accuracy: 0.0001)
        XCTAssertEqual(uv.bottomRight.x, Float(10.5 / 64), accuracy: 0.0001)
        XCTAssertEqual(uv.bottomRight.y, Float(18.5 / 128), accuracy: 0.0001)
        XCTAssertLessThan(uv.topLeft.y, uv.bottomRight.y)
    }

    private func makeOutputTexture(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
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
