import AppKit
import XCTest
@testable import Shell

final class WindowZoomStateTests: XCTestCase {
    func testToggleExpandsToVisibleFrameThenRestoresOriginalFrame() {
        var state = WindowZoomState()
        let original = NSRect(x: 120, y: 180, width: 900, height: 640)
        let visible = NSRect(x: 0, y: 25, width: 1440, height: 875)

        XCTAssertEqual(state.toggle(currentFrame: original, visibleFrame: visible), visible)
        XCTAssertEqual(state.restoredFrame, original)
        XCTAssertEqual(state.toggle(currentFrame: visible, visibleFrame: visible), original)
        XCTAssertNil(state.restoredFrame)
    }

    func testToggleDoesNothingWhenAlreadyAtVisibleFrame() {
        var state = WindowZoomState()
        let visible = NSRect(x: 0, y: 25, width: 1440, height: 875)

        XCTAssertNil(state.toggle(currentFrame: visible, visibleFrame: visible))
        XCTAssertNil(state.restoredFrame)
    }
}
