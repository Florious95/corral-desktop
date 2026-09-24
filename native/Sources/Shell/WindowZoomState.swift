import AppKit

struct WindowZoomState {
    private(set) var restoredFrame: NSRect?

    mutating func toggle(currentFrame: NSRect, visibleFrame: NSRect) -> NSRect? {
        if let restoredFrame {
            self.restoredFrame = nil
            return restoredFrame
        }
        guard currentFrame != visibleFrame else { return nil }
        restoredFrame = currentFrame
        return visibleFrame
    }

    mutating func reset() { restoredFrame = nil }
}
