import AppKit
import XCTest
@testable import Shell

final class TrafficLightLayoutTests: XCTestCase {
    func testButtonsShareTitlebarCenterAt16Points() {
        let bounds = NSRect(x: 0, y: 0, width: 180, height: 38)
        let frame = NSRect(x: 8, y: 0, width: 14, height: 14)

        let aligned = TrafficLightLayout.alignedFrame(buttonFrame: frame, in: bounds)

        XCTAssertEqual(aligned.midY, 16.0)
        XCTAssertEqual(aligned.origin.x, frame.origin.x)
    }

    func testAlignmentClampsToVisibleTitlebarBounds() {
        let bounds = NSRect(x: 0, y: 0, width: 180, height: 20)
        let frame = NSRect(x: 8, y: 0, width: 14, height: 18)

        let aligned = TrafficLightLayout.alignedFrame(buttonFrame: frame, in: bounds)

        XCTAssertGreaterThanOrEqual(aligned.minY, bounds.minY)
        XCTAssertLessThanOrEqual(aligned.maxY, bounds.maxY)
    }
}
