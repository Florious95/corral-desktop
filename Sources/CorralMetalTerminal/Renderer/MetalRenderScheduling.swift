import CorralContracts
import Foundation

public struct MetalStagePixelSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct MetalPixelViewport: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    /// Maps top-left-origin physical stage pixels to Metal's NDC y-up coordinate system.
    public func normalizedDevicePosition(x stageX: Double, y stageY: Double) -> SIMD2<Float> {
        SIMD2(
            Float((stageX - x) / width * 2 - 1),
            Float(1 - (stageY - y) / height * 2)
        )
    }
}

public struct MetalPixelScissor: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
}

public struct MetalPaneViewport: Equatable, Sendable {
    public let viewport: MetalPixelViewport
    public let scissor: MetalPixelScissor
}

public enum MetalViewportMapper {
    /// Converts top-left point coordinates to pixel-aligned Metal viewport/scissor bounds.
    public static func map(
        _ rect: StageViewportRect,
        stage: MetalStagePixelSize,
        backingScale: Double
    ) -> MetalPaneViewport? {
        guard rect.isValid, rect.width > 0, rect.height > 0,
              stage.width > 0, stage.height > 0,
              stage.width < Int.max / 4, stage.height < Int.max / 4,
              backingScale.isFinite, backingScale > 0 else { return nil }

        let left = (rect.x * backingScale).rounded()
        let top = (rect.y * backingScale).rounded()
        let right = ((rect.x + rect.width) * backingScale).rounded()
        let bottom = ((rect.y + rect.height) * backingScale).rounded()
        let limits = [left, top, right, bottom]
        guard limits.allSatisfy({ $0.isFinite && abs($0) < Double(Int.max / 4) }),
              right > left, bottom > top else { return nil }

        let clippedLeft = max(0, left)
        let clippedTop = max(0, top)
        let clippedRight = min(Double(stage.width), right)
        let clippedBottom = min(Double(stage.height), bottom)
        guard clippedRight > clippedLeft, clippedBottom > clippedTop else { return nil }

        return MetalPaneViewport(
            viewport: MetalPixelViewport(x: left, y: top, width: right - left, height: bottom - top),
            scissor: MetalPixelScissor(
                x: Int(clippedLeft),
                y: Int(clippedTop),
                width: Int(clippedRight - clippedLeft),
                height: Int(clippedBottom - clippedTop)
            )
        )
    }
}

/// Tracks dirty work separately from render eligibility so changes received while hidden coalesce.
public struct MetalRenderFrameScheduler: Sendable {
    public private(set) var isPaused: Bool
    public private(set) var latestGeneration = DirtyGeneration.initial
    public private(set) var submittedGeneration = DirtyGeneration.initial
    private var hasPendingInvalidation = false
    private var cursorBlinkingEnabled = false
    private var cursorBlinkFramePending = false

    public init(paused: Bool = true) {
        isPaused = paused
    }

    public var shouldSubmit: Bool {
        !isPaused && (hasPendingInvalidation || cursorBlinkFramePending)
    }

    public mutating func pause() {
        isPaused = true
    }

    public mutating func resume() {
        guard isPaused else { return }
        isPaused = false
        hasPendingInvalidation = true
    }

    public mutating func setSleepState(_ state: RenderSleepState) {
        if state.allowsDrawing { resume() } else { pause() }
    }

    public mutating func invalidate(generation: DirtyGeneration, force: Bool = false) {
        if generation > latestGeneration {
            latestGeneration = generation
            hasPendingInvalidation = true
        } else if force {
            hasPendingInvalidation = true
        }
    }

    public mutating func setCursorBlinking(_ enabled: Bool) {
        cursorBlinkingEnabled = enabled
        if !enabled { cursorBlinkFramePending = false }
    }

    public mutating func cursorBlinkDidTick() {
        if cursorBlinkingEnabled { cursorBlinkFramePending = true }
    }

    public mutating func markSubmitted() {
        guard shouldSubmit else { return }
        submittedGeneration = max(submittedGeneration, latestGeneration)
        hasPendingInvalidation = false
        cursorBlinkFramePending = false
    }
}
