import CoreGraphics
import CoreText
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

/// A window owns one renderer and one CAMetalLayer; a fixed-size texture ring backs the shared stage.
/// Pane snapshots are retained as CPU data and composited into that stage only when dirty.
@MainActor
public final class SharedMetalTerminalRenderer: TerminalRendering {
    private struct PaneState {
        var snapshot: TerminalGridSnapshot
        var viewport: StageViewportRect
        var generation: DirtyGeneration
    }

    private struct FontStyle: Hashable {
        let bold: Bool
        let italic: Bool
        let pixelSize: Int
    }

    private struct QuadVertex {
        var position: SIMD2<Float>
        var textureCoordinate: SIMD2<Float>
    }

    private struct PreparedPane {
        let mapping: MetalPaneViewport
        let vertexStart: Int
    }

    public let stageLayer: CAMetalLayer
    public let device: MTLDevice

    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let samplerState: MTLSamplerState
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var stageSize = MetalStagePixelSize(width: 0, height: 0)
    private var stageSizeInPoints: CGSize?
    private var backingScale = 1.0
    private var sourceTextures: [MTLTexture] = []
    private var inFlightSourceTextureIDs: Set<ObjectIdentifier> = []
    private var panes: [UUID: PaneState] = [:]
    private var legacyPaneIDs: [StageViewportRect: UUID] = [:]
    private var visiblePaneIDs: Set<UUID> = []
    private var scheduler = MetalRenderFrameScheduler()
    private var cursorBlinkVisible = true

    public init(device suppliedDevice: MTLDevice? = nil) throws {
        guard let device = suppliedDevice ?? MTLCreateSystemDefaultDevice() else {
            throw SharedMetalTerminalRendererError.noMetalDevice
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw SharedMetalTerminalRendererError.commandQueueUnavailable
        }

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard let vertexFunction = library.makeFunction(name: "stage_vertex"),
              let fragmentFunction = library.makeFunction(name: "stage_fragment") else {
            throw SharedMetalTerminalRendererError.pipelineUnavailable
        }
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = MemoryLayout<QuadVertex>.offset(of: \.position)!
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<QuadVertex>.offset(of: \.textureCoordinate)!
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<QuadVertex>.stride

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "Corral shared terminal stage"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor) else {
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
        self.commandQueue = commandQueue
        self.pipelineState = pipelineState
        self.samplerState = samplerState
        self.stageLayer = stageLayer
    }

    /// Sets window geometry only when it actually changes; tab visibility never calls this method.
    public func configureStage(sizeInPoints: CGSize, backingScale: CGFloat) {
        guard sizeInPoints.width.isFinite, sizeInPoints.height.isFinite,
              backingScale.isFinite, backingScale > 0 else { return }
        let pixelWidth = sizeInPoints.width * backingScale
        let pixelHeight = sizeInPoints.height * backingScale
        let byteCount = Double(pixelWidth) * Double(pixelHeight) * 4
        guard pixelWidth >= 0, pixelHeight >= 0,
              pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth < CGFloat(Int.max / 4), pixelHeight < CGFloat(Int.max / 4),
              byteCount.isFinite, byteCount < Double(Int.max / 2) else { return }
        let nextSize = MetalStagePixelSize(
            width: Int(pixelWidth.rounded()),
            height: Int(pixelHeight.rounded())
        )
        let nextScale = Double(backingScale)
        guard nextSize != stageSize || nextScale != self.backingScale
                || stageSizeInPoints != sizeInPoints || sourceTextures.isEmpty else { return }

        let pixelsChanged = nextSize != stageSize
        stageSize = nextSize
        stageSizeInPoints = sizeInPoints
        self.backingScale = nextScale
        stageLayer.frame = CGRect(origin: .zero, size: sizeInPoints)
        stageLayer.contentsScale = backingScale
        stageLayer.drawableSize = CGSize(width: nextSize.width, height: nextSize.height)
        if pixelsChanged || sourceTextures.isEmpty {
            sourceTextures = (0..<3).compactMap { _ in makeStageTexture(size: nextSize) }
        }
        scheduler.invalidate(generation: scheduler.latestGeneration, force: true)
        renderIfNeeded()
    }

    /// Updates retained pane data. Hidden panes do not wake the GPU; activation will compose their latest snapshot.
    public func updatePane(
        id: UUID,
        snapshot: TerminalGridSnapshot,
        in viewport: StageViewportRect,
        dirtyGeneration: DirtyGeneration
    ) {
        guard viewport.isValid else { return }
        let accepted = storePane(id: id, snapshot: snapshot, viewport: viewport, generation: dirtyGeneration)
        guard accepted, visiblePaneIDs.contains(id) else { return }
        scheduler.invalidate(generation: dirtyGeneration, force: true)
        renderIfNeeded()
    }

    public func removePane(id: UUID) {
        let wasVisible = visiblePaneIDs.remove(id) != nil
        guard panes.removeValue(forKey: id) != nil else { return }
        legacyPaneIDs = legacyPaneIDs.filter { $0.value != id }
        if wasVisible {
            scheduler.invalidate(generation: scheduler.latestGeneration, force: true)
            renderIfNeeded()
        }
    }

    /// Changes only the visible pane set. Cached snapshots, Metal pipeline and stage dimensions remain resident.
    public func setVisiblePaneIDs(_ ids: Set<UUID>) {
        guard ids != visiblePaneIDs else { return }
        visiblePaneIDs = ids
        scheduler.invalidate(generation: scheduler.latestGeneration, force: true)
        renderIfNeeded()
    }

    public func setCursorBlinking(_ enabled: Bool) {
        guard enabled != cursorBlinkingIsEnabled else { return }
        cursorBlinkingIsEnabled = enabled
        cursorBlinkVisible = true
        scheduler.setCursorBlinking(enabled)
        scheduler.invalidate(generation: scheduler.latestGeneration, force: true)
        renderIfNeeded()
    }

    public func cursorBlinkDidTick() {
        guard cursorBlinkingIsEnabled else { return }
        cursorBlinkVisible.toggle()
        scheduler.cursorBlinkDidTick()
        renderIfNeeded()
    }

    public func present(
        _ snapshot: TerminalGridSnapshot,
        in viewport: StageViewportRect,
        dirtyGeneration: DirtyGeneration
    ) async {
        guard viewport.isValid else { return }
        let id = legacyPaneIDs[viewport] ?? UUID()
        legacyPaneIDs[viewport] = id
        let accepted = storePane(id: id, snapshot: snapshot, viewport: viewport, generation: dirtyGeneration)
        let becameVisible = visiblePaneIDs.insert(id).inserted
        guard accepted || becameVisible else { return }
        scheduler.invalidate(generation: dirtyGeneration, force: true)
        renderIfNeeded()
    }

    public func setSleepState(_ state: RenderSleepState) async {
        scheduler.setSleepState(state)
        renderIfNeeded()
    }

    private var cursorBlinkingIsEnabled = false

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

    private func makeStageTexture(size: MetalStagePixelSize) -> MTLTexture? {
        guard size.width > 0, size.height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: size.width,
            height: size.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        return device.makeTexture(descriptor: descriptor)
    }

    private func renderIfNeeded() {
        guard scheduler.shouldSubmit,
              stageSize.width > 0, stageSize.height > 0,
              let textureIndex = sourceTextures.indices.first(where: {
                  !inFlightSourceTextureIDs.contains(ObjectIdentifier(sourceTextures[$0]))
              }) else { return }
        let sourceTexture = sourceTextures[textureIndex]
        let sourceTextureID = ObjectIdentifier(sourceTexture)

        var prepared: [PreparedPane] = []
        var vertices: [QuadVertex] = []
        for id in visiblePaneIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let pane = panes[id],
                  let mapping = MetalViewportMapper.map(pane.viewport, stage: stageSize, backingScale: backingScale) else { continue }
            let start = vertices.count
            vertices.append(contentsOf: quadVertices(for: mapping.viewport))
            prepared.append(PreparedPane(mapping: mapping, vertexStart: start))
        }
        let vertexBuffer = vertices.isEmpty ? nil : makeVertexBuffer(vertices)
        guard vertices.isEmpty || vertexBuffer != nil,
              let drawable = stageLayer.nextDrawable() else { return }

        let pixels = rasterizeVisiblePanes()
        pixels.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                sourceTexture.replace(
                    region: MTLRegionMake2D(0, 0, stageSize.width, stageSize.height),
                    mipmapLevel: 0,
                    withBytes: baseAddress,
                    bytesPerRow: stageSize.width * 4
                )
            }
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        if !vertices.isEmpty, let vertexBuffer {
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            for pane in prepared {
                let viewport = pane.mapping.viewport
                encoder.setViewport(MTLViewport(
                    originX: viewport.x,
                    originY: viewport.y,
                    width: viewport.width,
                    height: viewport.height,
                    znear: 0,
                    zfar: 1
                ))
                let scissor = pane.mapping.scissor
                encoder.setScissorRect(MTLScissorRect(
                    x: scissor.x,
                    y: scissor.y,
                    width: scissor.width,
                    height: scissor.height
                ))
                encoder.drawPrimitives(type: .triangle, vertexStart: pane.vertexStart, vertexCount: 6)
            }
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        inFlightSourceTextureIDs.insert(sourceTextureID)
        commandBuffer.addCompletedHandler { [weak self] completedBuffer in
            let succeeded = completedBuffer.status == .completed
            Task { @MainActor [weak self] in
                self?.finishFrame(usingSourceTexture: sourceTextureID, succeeded: succeeded)
            }
        }
        commandBuffer.commit()
        scheduler.markSubmitted()
    }

    private func finishFrame(usingSourceTexture id: ObjectIdentifier, succeeded: Bool) {
        inFlightSourceTextureIDs.remove(id)
        if succeeded {
            renderIfNeeded()
        } else {
            scheduler.invalidate(generation: scheduler.latestGeneration, force: true)
        }
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

    private func quadVertices(for viewport: MetalPixelViewport) -> [QuadVertex] {
        let stageWidth = Float(stageSize.width)
        let stageHeight = Float(stageSize.height)
        let left = Float(viewport.x) / stageWidth
        let top = Float(viewport.y) / stageHeight
        let right = Float(viewport.x + viewport.width) / stageWidth
        let bottom = Float(viewport.y + viewport.height) / stageHeight
        let topLeft = QuadVertex(position: SIMD2(-1, 1), textureCoordinate: SIMD2(left, top))
        let topRight = QuadVertex(position: SIMD2(1, 1), textureCoordinate: SIMD2(right, top))
        let bottomLeft = QuadVertex(position: SIMD2(-1, -1), textureCoordinate: SIMD2(left, bottom))
        let bottomRight = QuadVertex(position: SIMD2(1, -1), textureCoordinate: SIMD2(right, bottom))
        return [topLeft, bottomLeft, topRight, topRight, bottomLeft, bottomRight]
    }

    private func rasterizeVisiblePanes() -> [UInt8] {
        let width = stageSize.width
        let height = stageSize.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)).rawValue
            ) else { return }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))

            for id in visiblePaneIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let pane = panes[id], pane.snapshot.isValid,
                      let mapping = MetalViewportMapper.map(pane.viewport, stage: stageSize, backingScale: backingScale) else { continue }
                context.saveGState()
                context.clip(to: CGRect(
                    x: mapping.scissor.x,
                    y: mapping.scissor.y,
                    width: mapping.scissor.width,
                    height: mapping.scissor.height
                ))
                draw(pane.snapshot, in: mapping.viewport, context: context)
                context.restoreGState()
            }
        }
        return pixels
    }

    private func draw(_ snapshot: TerminalGridSnapshot, in viewport: MetalPixelViewport, context: CGContext) {
        let cellWidth = viewport.width / Double(snapshot.size.columns)
        let cellHeight = viewport.height / Double(snapshot.size.rows)
        guard cellWidth > 0, cellHeight > 0 else { return }
        var fonts: [FontStyle: CTFont] = [:]

        for row in 0..<snapshot.size.rows {
            for column in 0..<snapshot.size.columns {
                let cell = snapshot.cells[row * snapshot.size.columns + column]
                let cursorHere = snapshot.cursor.isVisible && cursorBlinkVisible
                    && snapshot.cursor.row == row && snapshot.cursor.column == column
                let inverse = cell.attributes.contains(.inverse) != cursorHere
                context.setFillColor(terminalColor(inverse ? cell.foreground : cell.background))
                context.fill(CGRect(
                    x: viewport.x + Double(column) * cellWidth,
                    y: viewport.y + Double(row) * cellHeight,
                    width: cellWidth * (cell.isWide ? 2 : 1),
                    height: cellHeight
                ))
            }
        }

        for row in 0..<snapshot.size.rows {
            for column in 0..<snapshot.size.columns {
                let cell = snapshot.cells[row * snapshot.size.columns + column]
                guard cell.codepoint != 0, cell.codepoint != 32 else { continue }
                let cursorHere = snapshot.cursor.isVisible && cursorBlinkVisible
                    && snapshot.cursor.row == row && snapshot.cursor.column == column
                let inverse = cell.attributes.contains(.inverse) != cursorHere
                let foreground = terminalColor(inverse ? cell.background : cell.foreground)
                let cellRect = CGRect(
                    x: viewport.x + Double(column) * cellWidth,
                    y: viewport.y + Double(row) * cellHeight,
                    width: cellWidth * (cell.isWide ? 2 : 1),
                    height: cellHeight
                )

                let fontSize = max(8, min(Int((cellHeight * 0.82).rounded()), 128))
                let style = FontStyle(
                    bold: cell.attributes.contains(.bold),
                    italic: cell.attributes.contains(.italic),
                    pixelSize: fontSize
                )
                let font = fonts[style] ?? makeFont(style)
                fonts[style] = font
                let scalar = UnicodeScalar(cell.codepoint) ?? UnicodeScalar(0xFFFD)!
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground
                ]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(scalar), attributes: attributes))
                let ascent = CTFontGetAscent(font)
                let descent = CTFontGetDescent(font)
                context.saveGState()
                context.clip(to: cellRect)
                context.textPosition = CGPoint(
                    x: cellRect.minX,
                    y: cellRect.minY + (cellRect.height - ascent - descent) / 2 + ascent
                )
                CTLineDraw(line, context)
                context.restoreGState()
            }
        }
    }

    private func makeFont(_ style: FontStyle) -> CTFont {
        let name: String
        switch (style.bold, style.italic) {
        case (true, true): name = "Menlo-BoldItalic"
        case (true, false): name = "Menlo-Bold"
        case (false, true): name = "Menlo-Italic"
        case (false, false): name = "Menlo-Regular"
        }
        return CTFontCreateWithName(name as CFString, CGFloat(style.pixelSize), nil)
    }

    private func terminalColor(_ color: TerminalColor) -> CGColor {
        let rgb: (UInt8, UInt8, UInt8)
        switch color {
        case .rgba(let value):
            rgb = (value.red, value.green, value.blue)
        case .indexed(let value):
            rgb = indexedColor(value)
        }
        return CGColor(
            colorSpace: colorSpace,
            components: [CGFloat(rgb.0) / 255, CGFloat(rgb.1) / 255, CGFloat(rgb.2) / 255, 1]
        )!
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

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VertexIn {
        float2 position [[attribute(0)]];
        float2 textureCoordinate [[attribute(1)]];
    };
    struct VertexOut {
        float4 position [[position]];
        float2 textureCoordinate;
    };
    vertex VertexOut stage_vertex(VertexIn in [[stage_in]]) {
        VertexOut out;
        out.position = float4(in.position, 0.0, 1.0);
        out.textureCoordinate = in.textureCoordinate;
        return out;
    }
    fragment float4 stage_fragment(VertexOut in [[stage_in]],
                                   texture2d<float> stage [[texture(0)]],
                                   sampler stageSampler [[sampler(0)]]) {
        return stage.sample(stageSampler, in.textureCoordinate);
    }
    """
}
