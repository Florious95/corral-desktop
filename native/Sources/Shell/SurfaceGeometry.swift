import AppKit

/// CSS viewport coordinates, never physical pixels. Exclusions always win.
public struct SurfaceGeometry {
    public private(set) var revision = -1
    public private(set) var geometryGeneration: Int = 0
    private var viewport = CGSize.zero
    private var nativeBounds = CGRect.zero
    private var scale: CGFloat = 0
    private var dragRects: [CGRect] = []
    private var exclusions: [CGRect] = []
    private var armed = false
    public private(set) var chromeRect = CGRect.zero

    public init() {}

    /// Invalidates the current hit-test snapshot and advances the native generation.
    /// A same-sized layout update therefore cannot reuse an old rectangle set.
    public mutating func invalidate() {
        geometryGeneration += 1
        armed = false
        dragRects = []
        exclusions = []
        chromeRect = .zero
    }

    /// Starts a new page epoch while retaining a generation that cannot collide with
    /// the previous page, even when the frontend resets its revision counter.
    public mutating func reset() {
        geometryGeneration += 1
        revision = -1
        viewport = .zero
        nativeBounds = .zero
        scale = 0
        armed = false
        dragRects = []
        exclusions = []
        chromeRect = .zero
    }

    public mutating func update(_ params: [String: Any], bounds: CGRect, backingScale: CGFloat) throws {
        guard let phase = params["phase"] as? String else {
            throw ShellError.invalidRequest
        }
        let incomingGeneration = try integer(params["geometryGeneration"])
        guard incomingGeneration == geometryGeneration else {
            throw ShellError.staleGeometry
        }
        guard let incomingRevision = try? integer(params["revision"]),
              incomingRevision >= 0, incomingRevision <= 9_007_199_254_740_991,
              incomingRevision > revision else {
            throw ShellError.invalidRequest
        }

        switch phase {
        case "disarm":
            guard Set(params.keys) == ["phase", "geometryGeneration", "revision"] else {
                throw ShellError.invalidRequest
            }
            revision = incomingRevision
            armed = false
            dragRects = []
            exclusions = []
            chromeRect = .zero
            return
        case "arm":
            guard Set(params.keys) == [
                "phase", "geometryGeneration", "revision", "viewportCSS",
                "devicePixelRatio", "dragRects", "exclusionRects", "chromeRect"
            ], bounds.width > 0, bounds.height > 0, backingScale > 0,
                  let size = params["viewportCSS"] as? [String: Any],
                  Set(size.keys) == ["width", "height"] else {
                throw ShellError.invalidRequest
            }
            let viewportSize = try CGSize(width: number(size["width"]), height: number(size["height"]))
            let dpr = try number(params["devicePixelRatio"])
            guard viewportSize.width > 0, viewportSize.height > 0,
                  abs(viewportSize.width - bounds.width) < 1,
                  abs(viewportSize.height - bounds.height) < 1,
                  abs(dpr - backingScale) < 0.001,
                  let drags = params["dragRects"] as? [Any], drags.count <= 256,
                  let excluded = params["exclusionRects"] as? [Any], excluded.count <= 256 else {
                throw ShellError.invalidRequest
            }

            func rect(_ value: Any?) throws -> CGRect {
                guard let r = value as? [String: Any],
                      Set(r.keys) == ["x", "y", "width", "height"] else {
                    throw ShellError.invalidRequest
                }
                let result = try CGRect(
                    x: number(r["x"]), y: number(r["y"]),
                    width: number(r["width"]), height: number(r["height"])
                )
                guard result.minX >= 0, result.minY >= 0,
                      result.width >= 0, result.height >= 0,
                      result.maxX <= viewportSize.width,
                      result.maxY <= viewportSize.height else {
                    throw ShellError.invalidRequest
                }
                return result
            }

            let chrome = try rect(params["chromeRect"])
            let validDrags = try drags.map(rect)
            let validExclusions = try excluded.map(rect)
            guard validDrags.allSatisfy({ chrome.contains($0) }) else {
                throw ShellError.invalidRequest
            }

            revision = incomingRevision
            viewport = viewportSize
            nativeBounds = bounds
            scale = backingScale
            dragRects = validDrags
            exclusions = validExclusions
            chromeRect = chrome
            armed = true
        default:
            throw ShellError.invalidRequest
        }
    }

    public func isDraggable(_ point: CGPoint, bounds: CGRect, backingScale: CGFloat, flipped: Bool) -> Bool {
        guard armed, bounds == nativeBounds, backingScale == scale,
              bounds.width > 0, bounds.height > 0, bounds.contains(point) else {
            return false
        }
        let x = (point.x - bounds.minX) * viewport.width / bounds.width
        let y = (flipped ? point.y - bounds.minY : bounds.maxY - point.y) * viewport.height / bounds.height
        let css = CGPoint(x: x, y: y)
        return dragRects.contains { $0.contains(css) } && !exclusions.contains { $0.contains(css) }
    }

    private func number(_ value: Any?) throws -> CGFloat {
        guard let n = value as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite else {
            throw ShellError.invalidRequest
        }
        return CGFloat(n.doubleValue)
    }

    private func integer(_ value: Any?) throws -> Int {
        let number = try self.number(value)
        guard number >= 0, number.rounded() == number,
              number <= CGFloat(Int.max) else {
            throw ShellError.invalidRequest
        }
        return Int(number)
    }
}
