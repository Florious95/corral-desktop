import AppKit

/// CSS viewport coordinates, never physical pixels. Exclusions always win.
public struct SurfaceGeometry {
    public private(set) var revision = -1
    private var viewport = CGSize.zero
    private var nativeBounds = CGRect.zero
    private var scale: CGFloat = 0
    private var dragRects: [CGRect] = []
    private var exclusions: [CGRect] = []
    public private(set) var chromeRect = CGRect.zero

    public init() {}

    public mutating func invalidate() {
        dragRects = []
        exclusions = []
        chromeRect = .zero
    }

    public mutating func reset() { self = SurfaceGeometry() }

    public mutating func update(_ params: [String: Any], bounds: CGRect, backingScale: CGFloat) throws {
        func number(_ value: Any?) throws -> CGFloat {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
                throw ShellError.invalidRequest
            }
            return CGFloat(n.doubleValue)
        }
        guard Set(params.keys) == ["revision", "viewportCSS", "devicePixelRatio", "dragRects", "exclusionRects", "chromeRect"],
              let size = params["viewportCSS"] as? [String: Any], Set(size.keys) == ["width", "height"] else { throw ShellError.invalidRequest }
        let nextRevision = try number(params["revision"])
        let viewportSize = try CGSize(width: number(size["width"]), height: number(size["height"]))
        let dpr = try number(params["devicePixelRatio"])
        guard nextRevision >= 0, nextRevision <= 9_007_199_254_740_991, nextRevision.rounded() == nextRevision,
              nextRevision > CGFloat(revision), viewportSize.width > 0, viewportSize.height > 0,
              bounds.width > 0, bounds.height > 0, backingScale > 0,
              abs(viewportSize.width - bounds.width) < 1, abs(viewportSize.height - bounds.height) < 1,
              abs(dpr - backingScale) < 0.001,
              let drags = params["dragRects"] as? [Any], drags.count <= 256,
              let excluded = params["exclusionRects"] as? [Any], excluded.count <= 256 else { throw ShellError.invalidRequest }
        func rect(_ value: Any?) throws -> CGRect {
            guard let r = value as? [String: Any], Set(r.keys) == ["x", "y", "width", "height"] else { throw ShellError.invalidRequest }
            let result = try CGRect(x: number(r["x"]), y: number(r["y"]), width: number(r["width"]), height: number(r["height"]))
            guard result.minX >= 0, result.minY >= 0, result.width >= 0, result.height >= 0,
                  result.maxX <= viewportSize.width, result.maxY <= viewportSize.height else { throw ShellError.invalidRequest }
            return result
        }
        let chrome = try rect(params["chromeRect"])
        let validDrags = try drags.map(rect)
        let validExclusions = try excluded.map(rect)
        guard validDrags.allSatisfy({ chrome.contains($0) }) else { throw ShellError.invalidRequest }
        revision = Int(nextRevision)
        viewport = viewportSize
        nativeBounds = bounds
        scale = backingScale
        dragRects = validDrags
        exclusions = validExclusions
        chromeRect = chrome
    }

    public func isDraggable(_ point: CGPoint, bounds: CGRect, backingScale: CGFloat, flipped: Bool) -> Bool {
        guard bounds == nativeBounds, backingScale == scale, bounds.width > 0, bounds.height > 0 else { return false }
        let x = (point.x - bounds.minX) * viewport.width / bounds.width
        let y = (flipped ? point.y - bounds.minY : bounds.maxY - point.y) * viewport.height / bounds.height
        let css = CGPoint(x: x, y: y)
        return dragRects.contains { $0.contains(css) } && !exclusions.contains { $0.contains(css) }
    }
}
