import CoreGraphics
import Metal
import QuartzCore
import CorralContracts
import Foundation

public enum SharedMetalTerminalRendererError: Error {
    case noMetalDevice
    case commandQueueUnavailable
    case pipelineUnavailable
    case samplerUnavailable
}

public struct SharedMetalTerminalRendererStatistics: Sendable, Equatable {
    public let lastFrameReferencedAtlasPages: Int
    public let lastFrameSampledGlyphs: Int
    public let submittedCommandBuffers: UInt64
    public let metalDrawCalls: UInt64
    /// Always zero: the renderer has no stage-sized CPU bitmap or upload path.
    public let fullStageBitmapUploads: UInt64

    public static let zero = Self(
        lastFrameReferencedAtlasPages: 0,
        lastFrameSampledGlyphs: 0,
        submittedCommandBuffers: 0,
        metalDrawCalls: 0,
        fullStageBitmapUploads: 0
    )
}

/// One instance owns the window's only CAMetalLayer. Terminal glyphs are sampled from the app-wide atlas.
@MainActor
public final class SharedMetalTerminalRenderer: MetalTerminalRenderer {
    private enum GlyphFormat: Int, Hashable {
        case coverageR8
        case colorBGRA8
    }

    private struct QuadVertex {
        var position: SIMD2<Float>
        var textureCoordinate: SIMD2<Float>
        var color: SIMD4<Float>
    }

    private struct GlyphBatchKey: Hashable {
        let page: UInt16
        let format: GlyphFormat
    }

    private struct DrawRange {
        let start: Int
        let count: Int
    }

    private struct GlyphDrawBatch {
        let key: GlyphBatchKey
        let texture: MTLTexture
        let range: DrawRange
    }

    private struct PaneDrawPlan {
        let mapping: MetalPaneViewport
        let background: DrawRange
        let blockCursor: DrawRange
        let glyphs: [GlyphDrawBatch]
        let overlays: DrawRange
    }

    private struct PaneState {
        var snapshot: TerminalGridSnapshot
        var viewport: StageViewportRect
        var generation: DirtyGeneration
    }

    public let stageLayer: CAMetalLayer
    public let device: MTLDevice
    public let glyphAtlasPool: GlyphAtlasPool
    public private(set) var statistics = SharedMetalTerminalRendererStatistics.zero

    private let maximumFrameCount: UInt32 = 3

    private let commandQueue: MTLCommandQueue
    private let fillPipeline: MTLRenderPipelineState
    private let coveragePipeline: MTLRenderPipelineState
    private let colorPipeline: MTLRenderPipelineState
    private let samplerState: MTLSamplerState
    private var stageSize = MetalStagePixelSize(width: 0, height: 0)
    private var stageSizeInPoints: CGSize?
    private var backingScale = 1.0
    private var panes: [UUID: PaneState] = [:]
    private var visiblePaneIDs: Set<UUID> = []
    private var scheduler = MetalRenderFrameScheduler()
    private var applicationSleepState: RenderSleepState = .active
    private var latestRequest: StageFrameRequest?
    private var stageID: UUID?
    private var layoutGeneration: LayoutGeneration?
    private var metricsGeneration: MetricsGeneration?
    private var inFlightFrames: UInt32 = 0
    private var cursorBlinkingIsEnabled = false
    private var cursorBlinkVisible = true


    public init(device suppliedDevice: MTLDevice? = nil, glyphAtlas: GlyphAtlasPool? = nil) throws {
        guard let device = suppliedDevice ?? MTLCreateSystemDefaultDevice() else {
            throw SharedMetalTerminalRendererError.noMetalDevice
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw SharedMetalTerminalRendererError.commandQueueUnavailable
        }
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard let vertexFunction = library.makeFunction(name: "stage_vertex"),
              let fillFragment = library.makeFunction(name: "fill_fragment"),
              let coverageFragment = library.makeFunction(name: "coverage_fragment"),
              let colorFragment = library.makeFunction(name: "color_fragment") else {
            throw SharedMetalTerminalRendererError.pipelineUnavailable
        }

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = MemoryLayout<QuadVertex>.offset(of: \.position)!
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<QuadVertex>.offset(of: \.textureCoordinate)!
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .float4
        vertexDescriptor.attributes[2].offset = MemoryLayout<QuadVertex>.offset(of: \.color)!
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<QuadVertex>.stride

        func makePipeline(fragment: MTLFunction, pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragment
            descriptor.vertexDescriptor = vertexDescriptor
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        guard let fillPipeline = try? makePipeline(fragment: fillFragment, pixelFormat: .bgra8Unorm),
              let coveragePipeline = try? makePipeline(fragment: coverageFragment, pixelFormat: .bgra8Unorm),
              let colorPipeline = try? makePipeline(fragment: colorFragment, pixelFormat: .bgra8Unorm) else {
            throw SharedMetalTerminalRendererError.pipelineUnavailable
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let samplerState = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw SharedMetalTerminalRendererError.samplerUnavailable
        }

        let stageLayer = CAMetalLayer()
        stageLayer.device = device
        stageLayer.pixelFormat = .bgra8Unorm
        stageLayer.framebufferOnly = true
        stageLayer.presentsWithTransaction = false

        self.device = device
        self.glyphAtlasPool = glyphAtlas ?? .shared
        self.commandQueue = commandQueue
        self.fillPipeline = fillPipeline
        self.coveragePipeline = coveragePipeline
        self.colorPipeline = colorPipeline
        self.samplerState = samplerState
        self.stageLayer = stageLayer
    }

    public func configureStage(sizeInPoints: CGSize, backingScale: CGFloat) {
        guard sizeInPoints.width.isFinite, sizeInPoints.height.isFinite,
              sizeInPoints.width >= 0, sizeInPoints.height >= 0,
              backingScale.isFinite, backingScale > 0 else { return }
        let pixelWidth = sizeInPoints.width * backingScale
        let pixelHeight = sizeInPoints.height * backingScale
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth < CGFloat(Int.max / 4), pixelHeight < CGFloat(Int.max / 4) else { return }
        let nextSize = MetalStagePixelSize(
            width: Int(pixelWidth.rounded()),
            height: Int(pixelHeight.rounded())
        )
        guard nextSize != stageSize || Double(backingScale) != self.backingScale
                || stageSizeInPoints != sizeInPoints else { return }

        stageSize = nextSize
        stageSizeInPoints = sizeInPoints
        self.backingScale = Double(backingScale)
        stageLayer.frame = CGRect(origin: .zero, size: sizeInPoints)
        stageLayer.contentsScale = backingScale
        stageLayer.drawableSize = CGSize(width: nextSize.width, height: nextSize.height)
        scheduler.invalidate(generation: scheduler.latestGeneration, force: true)
    }

    public var maximumInFlightFrames: UInt32 { get async { maximumFrameCount } }

    public func render(_ request: StageFrameRequest) async -> FrameReceipt {
        guard request.isValid else { return Self.receipt(for: request, outcome: .failed(.invalidRequest)) }
        if let stageID, stageID != request.stageID {
            return Self.receipt(for: request, outcome: .failed(.invalidRequest))
        }
        stageID = request.stageID
        let previousRequest = latestRequest
        latestRequest = request

        let layoutChanged = layoutGeneration != request.layoutGeneration
        let metricsChanged = metricsGeneration != request.metricsGeneration
        let visibilityChanged = previousRequest?.visibility != request.visibility
        layoutGeneration = request.layoutGeneration
        metricsGeneration = request.metricsGeneration

        var paneChanged = false
        for pane in request.panes {
            paneChanged = storePane(
                id: pane.paneID,
                snapshot: pane.snapshot,
                viewport: pane.viewport,
                generation: pane.contentGeneration
            ) || paneChanged
        }
        let nextVisiblePaneIDs = Set(request.panes.map(\.paneID))
        if nextVisiblePaneIDs != visiblePaneIDs { paneChanged = true }
        visiblePaneIDs = nextVisiblePaneIDs

        let sleepState = sleepState(for: request.visibility)
        scheduler.setSleepState(sleepState)
        if layoutChanged || metricsChanged || visibilityChanged || paneChanged {
            let generation = request.panes.map(\.contentGeneration).max() ?? scheduler.latestGeneration
            scheduler.invalidate(generation: generation, force: true)
        }
        guard request.visibility == .visible, !scheduler.isPaused else {
            return Self.receipt(for: request, outcome: .deferred)
        }
        guard scheduler.shouldSubmit else { return Self.receipt(for: request, outcome: .deferred) }

        return await withCheckedContinuation { continuation in
            submit(request, continuation: continuation)
        }
    }

    public func setSleepState(_ state: RenderSleepState, for stageID: UUID) async {
        guard self.stageID == nil || self.stageID == stageID else { return }
        self.stageID = stageID
        applicationSleepState = state
        scheduler.setSleepState(sleepState(for: latestRequest?.visibility ?? .visible))
        if scheduler.shouldSubmit, let latestRequest {
            _ = await render(latestRequest)
        }
    }

    public func setCursorBlinking(_ enabled: Bool) {
        guard cursorBlinkingIsEnabled != enabled else { return }
        cursorBlinkingIsEnabled = enabled
        cursorBlinkVisible = true
        scheduler.setCursorBlinking(enabled)
        scheduler.invalidate(generation: scheduler.latestGeneration, force: true)
        scheduleCachedRender()
    }

    public func cursorBlinkDidTick() {
        guard cursorBlinkingIsEnabled else { return }
        cursorBlinkVisible.toggle()
        scheduler.cursorBlinkDidTick()
        scheduleCachedRender()
    }

    private func sleepState(for visibility: StageVisibility) -> RenderSleepState {
        switch visibility {
        case .visible: applicationSleepState
        case .tabHidden: .tabHidden
        case .windowMinimized: .windowMinimized
        case .occluded: .occluded
        }
    }

    private func storePane(
        id: UUID,
        snapshot: TerminalGridSnapshot,
        viewport: StageViewportRect,
        generation: DirtyGeneration
    ) -> Bool {
        guard snapshot.isValid else { return false }
        guard let previous = panes[id] else {
            panes[id] = PaneState(snapshot: snapshot, viewport: viewport, generation: generation)
            return true
        }
        let newSnapshot = generation > previous.generation
        let newViewport = viewport != previous.viewport
        guard newSnapshot || newViewport else { return false }
        panes[id] = PaneState(
            snapshot: newSnapshot ? snapshot : previous.snapshot,
            viewport: viewport,
            generation: newSnapshot ? generation : previous.generation
        )
        return true
    }

    private func submit(_ request: StageFrameRequest, continuation: CheckedContinuation<FrameReceipt, Never>) {
        guard stageSize.width > 0, stageSize.height > 0 else {
            continuation.resume(returning: Self.receipt(for: request, outcome: .failed(.noDrawable)))
            return
        }
        guard inFlightFrames < maximumFrameCount else {
            continuation.resume(returning: Self.receipt(for: request, outcome: .deferred))
            return
        }
        guard let drawable = stageLayer.nextDrawable() else {
            continuation.resume(returning: Self.receipt(for: request, outcome: .failed(.noDrawable)))
            return
        }

        let prepared = prepareDraws(for: request.panes)
        let vertexBuffer: MTLBuffer?
        if prepared.vertices.isEmpty {
            vertexBuffer = nil
        } else if let allocated = makeVertexBuffer(prepared.vertices) {
            vertexBuffer = allocated
        } else {
            continuation.resume(returning: Self.receipt(for: request, outcome: .failed(.commandBuffer("Unable to allocate pane vertices"))))
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            continuation.resume(returning: Self.receipt(for: request, outcome: .failed(.commandBuffer("Unable to allocate command buffer"))))
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            continuation.resume(returning: Self.receipt(for: request, outcome: .failed(.commandBuffer("Unable to create render encoder"))))
            return
        }

        if let vertexBuffer { encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0) }
        var drawCalls = 0
        for pane in prepared.panes {
            let viewport = pane.mapping.viewport
            encoder.setViewport(MTLViewport(
                originX: viewport.x, originY: viewport.y,
                width: viewport.width, height: viewport.height,
                znear: 0, zfar: 1
            ))
            let scissor = pane.mapping.scissor
            encoder.setScissorRect(MTLScissorRect(
                x: scissor.x, y: scissor.y, width: scissor.width, height: scissor.height
            ))
            if pane.background.count > 0 {
                encoder.setRenderPipelineState(fillPipeline)
                encoder.drawPrimitives(type: .triangle, vertexStart: pane.background.start, vertexCount: pane.background.count)
                drawCalls += 1
            }
            if pane.blockCursor.count > 0 {
                encoder.setRenderPipelineState(fillPipeline)
                encoder.drawPrimitives(type: .triangle, vertexStart: pane.blockCursor.start, vertexCount: pane.blockCursor.count)
                drawCalls += 1
            }
            for glyph in pane.glyphs {
                encoder.setRenderPipelineState(glyph.key.format == .coverageR8 ? coveragePipeline : colorPipeline)
                encoder.setFragmentTexture(glyph.texture, index: 0)
                encoder.setFragmentSamplerState(samplerState, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: glyph.range.start, vertexCount: glyph.range.count)
                drawCalls += 1
            }
            if pane.overlays.count > 0 {
                encoder.setRenderPipelineState(fillPipeline)
                encoder.drawPrimitives(type: .triangle, vertexStart: pane.overlays.start, vertexCount: pane.overlays.count)
                drawCalls += 1
            }
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)

        inFlightFrames += 1
        scheduler.markSubmitted()
        statistics = SharedMetalTerminalRendererStatistics(
            lastFrameReferencedAtlasPages: prepared.referencedPages,
            lastFrameSampledGlyphs: prepared.sampledGlyphs,
            submittedCommandBuffers: statistics.submittedCommandBuffers &+ 1,
            metalDrawCalls: statistics.metalDrawCalls &+ UInt64(drawCalls),
            fullStageBitmapUploads: 0
        )
        commandBuffer.addCompletedHandler { [weak self] completedBuffer in
            let succeeded = completedBuffer.status == .completed
            let failureMessage = completedBuffer.error.map(String.init(describing:))
            Task { @MainActor [weak self] in
                guard let self else {
                    continuation.resume(returning: Self.receipt(for: request, outcome: .failed(.commandBuffer("Renderer was released"))))
                    return
                }
                self.inFlightFrames -= 1
                let outcome: FrameOutcome
                if succeeded {
                    outcome = .completed
                } else {
                    outcome = .failed(.commandBuffer(failureMessage ?? "Metal command buffer failed"))
                    self.scheduler.invalidate(generation: self.scheduler.latestGeneration, force: true)
                }
                continuation.resume(returning: Self.receipt(for: request, outcome: outcome))
            }
        }
        commandBuffer.commit()
    }

    private func prepareDraws(for paneSnapshots: [PaneFrameSnapshot]) -> (vertices: [QuadVertex], panes: [PaneDrawPlan], referencedPages: Int, sampledGlyphs: Int) {
        var vertices: [QuadVertex] = []
        var panePlans: [PaneDrawPlan] = []
        var pageTextures: [UInt16: MTLTexture] = [:]
        var referencedPages = Set<UInt16>()
        var sampledGlyphs = 0

        for pane in paneSnapshots {
            guard let mapping = MetalViewportMapper.map(pane.viewport, stage: stageSize, backingScale: backingScale) else { continue }
            let viewport = mapping.viewport
            let snapshot = pane.snapshot
            let cellWidth = viewport.width / Double(snapshot.size.columns)
            let cellHeight = viewport.height / Double(snapshot.size.rows)
            guard cellWidth > 0, cellHeight > 0 else { continue }

            let backgroundStart = vertices.count
            for row in 0..<snapshot.size.rows {
                for column in 0..<snapshot.size.columns {
                    let cell = snapshot.cells[row * snapshot.size.columns + column]
                    let inverse = cell.attributes.contains(.inverse)
                    let background = terminalColor(inverse ? cell.foreground : cell.background)
                    appendSolidQuad(
                        into: &vertices,
                        rect: CGRect(x: viewport.x + Double(column) * cellWidth, y: viewport.y + Double(row) * cellHeight, width: cellWidth, height: cellHeight),
                        viewport: viewport,
                        color: background
                    )
                }
            }
            let backgroundRange = DrawRange(start: backgroundStart, count: vertices.count - backgroundStart)

            let blockCursorStart = vertices.count
            if cursorBlinkVisible, snapshot.cursor.isVisible, snapshot.cursor.shape == .block {
                let column = snapshot.cursor.column
                let row = snapshot.cursor.row
                let cell = snapshot.cells[row * snapshot.size.columns + column]
                let span: Double
                if case let .cluster(_, columns) = cell.content {
                    span = Double(columns.rawValue)
                } else {
                    span = 1
                }
                appendSolidQuad(
                    into: &vertices,
                    rect: CGRect(x: viewport.x + Double(column) * cellWidth, y: viewport.y + Double(row) * cellHeight, width: cellWidth * span, height: cellHeight),
                    viewport: viewport,
                    color: terminalColor(cell.attributes.contains(.inverse) ? cell.background : cell.foreground)
                )
            }
            let blockCursorRange = DrawRange(start: blockCursorStart, count: vertices.count - blockCursorStart)

            var groupedGlyphs: [GlyphBatchKey: [QuadVertex]] = [:]
            for row in 0..<snapshot.size.rows {
                for column in 0..<snapshot.size.columns {
                    let cell = snapshot.cells[row * snapshot.size.columns + column]
                    guard case let .cluster(text, columns) = cell.content else { continue }
                    let pixelSize = UInt16(max(1, min(128, Int((cellHeight * 0.82).rounded()))))
                    guard let entry = glyphAtlasPool.glyph(
                        for: text,
                        fontPostScriptName: "Menlo-Regular",
                        pixelSize: pixelSize,
                        isBold: cell.attributes.contains(.bold),
                        isItalic: cell.attributes.contains(.italic)
                    ), entry.coordinates.width > 0, entry.coordinates.height > 0 else { continue }
                    let page = entry.coordinates.page
                    let texture: MTLTexture
                    if let cached = pageTextures[page] {
                        texture = cached
                    } else {
                        guard let loaded = glyphAtlasPool.texture(forPage: page), loaded.device.registryID == device.registryID else { continue }
                        texture = loaded
                        pageTextures[page] = loaded
                    }
                    let span = Double(columns.rawValue)
                    let cellRect = CGRect(
                        x: viewport.x + Double(column) * cellWidth,
                        y: viewport.y + Double(row) * cellHeight,
                        width: cellWidth * span,
                        height: cellHeight
                    )
                    let baselineX = cellRect.minX + max(0, (cellRect.width - entry.advanceX) / 2)
                    let baselineY = cellRect.minY + (cellRect.height - entry.ascent - entry.descent) / 2 + entry.ascent
                    let glyphRect = CGRect(
                        x: baselineX + entry.imageOriginX,
                        y: baselineY - (entry.imageOriginY + Double(entry.coordinates.height)),
                        width: Double(entry.coordinates.width),
                        height: Double(entry.coordinates.height)
                    )
                    let cursorHere = cursorBlinkVisible && snapshot.cursor.isVisible
                        && snapshot.cursor.row == row && snapshot.cursor.column == column
                    let inverse = cell.attributes.contains(.inverse)
                    let textColor = cursorHere && snapshot.cursor.shape == .block
                        ? terminalColor(inverse ? cell.foreground : cell.background)
                        : terminalColor(inverse ? cell.background : cell.foreground)
                    let tint = entry.format == .coverageR8 ? textColor : SIMD4<Float>(1, 1, 1, 1)
                    guard let quad = glyphQuad(
                        imageRect: glyphRect,
                        clipRect: cellRect,
                        viewport: viewport,
                        coordinates: entry.coordinates,
                        textureSize: CGSize(width: texture.width, height: texture.height),
                        color: tint
                    ) else { continue }
                    let format: GlyphFormat = entry.format == .coverageR8 ? .coverageR8 : .colorBGRA8
                    groupedGlyphs[GlyphBatchKey(page: page, format: format), default: []].append(contentsOf: quad)
                    referencedPages.insert(page)
                    sampledGlyphs += 1
                }
            }

            var glyphBatches: [GlyphDrawBatch] = []
            for key in groupedGlyphs.keys.sorted(by: {
                $0.page == $1.page ? $0.format.rawValue < $1.format.rawValue : $0.page < $1.page
            }) {
                guard let group = groupedGlyphs[key], let texture = pageTextures[key.page] else { continue }
                let start = vertices.count
                vertices.append(contentsOf: group)
                glyphBatches.append(GlyphDrawBatch(
                    key: key,
                    texture: texture,
                    range: DrawRange(start: start, count: group.count)
                ))
            }

            let overlayStart = vertices.count
            for row in 0..<snapshot.size.rows {
                for column in 0..<snapshot.size.columns {
                    let cell = snapshot.cells[row * snapshot.size.columns + column]
                    let cellRect = CGRect(x: viewport.x + Double(column) * cellWidth, y: viewport.y + Double(row) * cellHeight, width: cellWidth, height: cellHeight)
                    let visibleForeground = terminalColor(cell.attributes.contains(.inverse) ? cell.background : cell.foreground)
                    if cell.attributes.contains(.underline) {
                        let thickness = min(2, max(1, cellHeight * 0.06))
                        appendSolidQuad(
                            into: &vertices,
                            rect: CGRect(x: cellRect.minX, y: cellRect.maxY - thickness, width: cellRect.width, height: thickness),
                            viewport: viewport,
                            color: visibleForeground
                        )
                    }
                    guard cursorBlinkVisible, snapshot.cursor.isVisible,
                          snapshot.cursor.row == row, snapshot.cursor.column == column else { continue }
                    let cursorSpan: Double
                    if case .cluster(_, columns: .two) = cell.content { cursorSpan = 2 } else { cursorSpan = 1 }
                    let cursorRect = CGRect(x: cellRect.minX, y: cellRect.minY, width: cellWidth * cursorSpan, height: cellHeight)
                    let cursorColor = visibleForeground
                    switch snapshot.cursor.shape {
                    case .block:
                        break
                    case .bar:
                        appendSolidQuad(into: &vertices, rect: CGRect(x: cursorRect.minX, y: cursorRect.minY, width: max(1, cellWidth * 0.1), height: cursorRect.height), viewport: viewport, color: cursorColor)
                    case .underline:
                        let thickness = min(2, max(1, cellHeight * 0.1))
                        appendSolidQuad(into: &vertices, rect: CGRect(x: cursorRect.minX, y: cursorRect.maxY - thickness, width: cursorRect.width, height: thickness), viewport: viewport, color: cursorColor)
                    }
                }
            }
            let overlayRange = DrawRange(start: overlayStart, count: vertices.count - overlayStart)
            panePlans.append(PaneDrawPlan(
                mapping: mapping,
                background: backgroundRange,
                blockCursor: blockCursorRange,
                glyphs: glyphBatches,
                overlays: overlayRange
            ))
        }
        return (vertices, panePlans, referencedPages.count, sampledGlyphs)
    }

    private func appendSolidQuad(into vertices: inout [QuadVertex], rect: CGRect, viewport: MetalPixelViewport, color: SIMD4<Float>) {
        vertices.append(contentsOf: quadVertices(rect: rect, viewport: viewport, color: color, uvTopLeft: .zero, uvBottomRight: .zero))
    }

    private func glyphQuad(
        imageRect: CGRect,
        clipRect: CGRect,
        viewport: MetalPixelViewport,
        coordinates: AtlasCoordinates,
        textureSize: CGSize,
        color: SIMD4<Float>
    ) -> [QuadVertex]? {
        let clipped = imageRect.intersection(clipRect)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0,
              imageRect.width > 0, imageRect.height > 0,
              textureSize.width > 0, textureSize.height > 0 else { return nil }
        let uStart = (CGFloat(coordinates.x) + 0.5) / textureSize.width
        let uEnd = (CGFloat(coordinates.x + coordinates.width) - 0.5) / textureSize.width
        let vTop = (CGFloat(coordinates.y + coordinates.height) - 0.5) / textureSize.height
        let vBottom = (CGFloat(coordinates.y) + 0.5) / textureSize.height
        let leftRatio = (clipped.minX - imageRect.minX) / imageRect.width
        let rightRatio = (clipped.maxX - imageRect.minX) / imageRect.width
        let topRatio = (clipped.minY - imageRect.minY) / imageRect.height
        let bottomRatio = (clipped.maxY - imageRect.minY) / imageRect.height
        let uvTopLeft = SIMD2<Float>(Float(uStart + (uEnd - uStart) * leftRatio), Float(vTop + (vBottom - vTop) * topRatio))
        let uvBottomRight = SIMD2<Float>(Float(uStart + (uEnd - uStart) * rightRatio), Float(vTop + (vBottom - vTop) * bottomRatio))
        return quadVertices(rect: clipped, viewport: viewport, color: color, uvTopLeft: uvTopLeft, uvBottomRight: uvBottomRight)
    }

    private func quadVertices(
        rect: CGRect,
        viewport: MetalPixelViewport,
        color: SIMD4<Float>,
        uvTopLeft: SIMD2<Float>,
        uvBottomRight: SIMD2<Float>
    ) -> [QuadVertex] {
        let left = Float((Double(rect.minX) - viewport.x) / viewport.width * 2 - 1)
        let right = Float((Double(rect.maxX) - viewport.x) / viewport.width * 2 - 1)
        let top = Float(1 - (Double(rect.minY) - viewport.y) / viewport.height * 2)
        let bottom = Float(1 - (Double(rect.maxY) - viewport.y) / viewport.height * 2)
        let topLeft = QuadVertex(position: SIMD2(left, top), textureCoordinate: uvTopLeft, color: color)
        let topRight = QuadVertex(position: SIMD2(right, top), textureCoordinate: SIMD2(uvBottomRight.x, uvTopLeft.y), color: color)
        let bottomLeft = QuadVertex(position: SIMD2(left, bottom), textureCoordinate: SIMD2(uvTopLeft.x, uvBottomRight.y), color: color)
        let bottomRight = QuadVertex(position: SIMD2(right, bottom), textureCoordinate: uvBottomRight, color: color)
        return [topLeft, bottomLeft, topRight, topRight, bottomLeft, bottomRight]
    }

    private func makeVertexBuffer(_ vertices: [QuadVertex]) -> MTLBuffer? {
        vertices.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: baseAddress,
                length: buffer.count * MemoryLayout<QuadVertex>.stride,
                options: .storageModeShared
            )
        }
    }

    private func terminalColor(_ color: TerminalColor) -> SIMD4<Float> {
        let rgb: (UInt8, UInt8, UInt8, UInt8)
        switch color {
        case .rgba(let value): rgb = (value.red, value.green, value.blue, value.alpha)
        case .indexed(let index):
            let value = indexedColor(index)
            rgb = (value.0, value.1, value.2, 255)
        }
        return SIMD4<Float>(Float(rgb.0) / 255, Float(rgb.1) / 255, Float(rgb.2) / 255, Float(rgb.3) / 255)
    }

    private func indexedColor(_ index: UInt8) -> (UInt8, UInt8, UInt8) {
        let ansi: [(UInt8, UInt8, UInt8)] = [
            (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
            (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
            (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
            (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)
        ]
        let value = Int(index)
        if value < 16 { return ansi[value] }
        if value < 232 {
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            let cube = value - 16
            return (levels[cube / 36], levels[(cube / 6) % 6], levels[cube % 6])
        }
        let gray = UInt8(8 + (value - 232) * 10)
        return (gray, gray, gray)
    }

    private static func receipt(for request: StageFrameRequest, outcome: FrameOutcome) -> FrameReceipt {
        FrameReceipt(
            submissionID: UUID(),
            stageID: request.stageID,
            layoutGeneration: request.layoutGeneration,
            metricsGeneration: request.metricsGeneration,
            visibility: request.visibility,
            panes: request.panes.map { PaneFrameReceipt(paneID: $0.paneID, contentGeneration: $0.contentGeneration) },
            outcome: outcome
        )
    }

    private func scheduleCachedRender() {
        guard let latestRequest else { return }
        Task { @MainActor [weak self] in
            guard let self, self.latestRequest == latestRequest else { return }
            _ = await self.render(latestRequest)
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VertexIn {
        float2 position [[attribute(0)]];
        float2 textureCoordinate [[attribute(1)]];
        float4 color [[attribute(2)]];
    };
    struct VertexOut {
        float4 position [[position]];
        float2 textureCoordinate;
        float4 color;
    };
    vertex VertexOut stage_vertex(VertexIn in [[stage_in]]) {
        VertexOut out;
        out.position = float4(in.position, 0.0, 1.0);
        out.textureCoordinate = in.textureCoordinate;
        out.color = in.color;
        return out;
    }
    fragment float4 fill_fragment(VertexOut in [[stage_in]]) {
        return float4(in.color.rgb * in.color.a, in.color.a);
    }
    fragment float4 coverage_fragment(VertexOut in [[stage_in]],
                                      texture2d<float> atlas [[texture(0)]],
                                      sampler atlasSampler [[sampler(0)]]) {
        float coverage = atlas.sample(atlasSampler, in.textureCoordinate).r;
        float alpha = coverage * in.color.a;
        return float4(in.color.rgb * alpha, alpha);
    }
    fragment float4 color_fragment(VertexOut in [[stage_in]],
                                   texture2d<float> atlas [[texture(0)]],
                                   sampler atlasSampler [[sampler(0)]]) {
        return atlas.sample(atlasSampler, in.textureCoordinate);
    }
    """
}
