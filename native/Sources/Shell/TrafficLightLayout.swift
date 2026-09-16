import AppKit

/// Keeps native traffic lights in the titlebar's local coordinate space.
enum TrafficLightLayout {
    static func alignedFrame(buttonFrame: NSRect, in titlebarBounds: NSRect,
                             centerY: CGFloat = 16.0) -> NSRect {
        var frame = buttonFrame
        let desiredOriginY = titlebarBounds.minY + centerY - frame.height / 2.0
        let minimumY = titlebarBounds.minY
        let maximumY = max(minimumY, titlebarBounds.maxY - frame.height)
        frame.origin.y = min(max(desiredOriginY, minimumY), maximumY).rounded()
        return frame
    }
}
