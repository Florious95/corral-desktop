import AppKit
import XCTest
@testable import Shell

final class SurfaceGeometryTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    private func rectangle(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> [String: Double] {
        ["x": x, "y": y, "width": width, "height": height]
    }

    private func arm(_ generation: Int, _ revision: Int) -> [String: Any] {
        [
            "phase": "arm",
            "geometryGeneration": generation,
            "revision": revision,
            "viewportCSS": ["width": 800, "height": 600],
            "devicePixelRatio": 2,
            "dragRects": [rectangle(0, 0, 800, 40)],
            "exclusionRects": [rectangle(40, 0, 120, 40)],
            "chromeRect": rectangle(0, 0, 800, 40),
        ]
    }

    func testCoordinatesUseCSSSpaceAndExclusionsWin() throws {
        var geometry = SurfaceGeometry()
        try geometry.update(["phase": "disarm", "geometryGeneration": 0, "revision": 1],
                            bounds: bounds, backingScale: 2)
        try geometry.update(arm(0, 2), bounds: bounds, backingScale: 2)

        XCTAssertTrue(geometry.isDraggable(CGPoint(x: 20, y: 20), bounds: bounds,
                                           backingScale: 2, flipped: true))
        XCTAssertFalse(geometry.isDraggable(CGPoint(x: 80, y: 20), bounds: bounds,
                                            backingScale: 2, flipped: true))
        XCTAssertFalse(geometry.isDraggable(CGPoint(x: 20, y: 100), bounds: bounds,
                                            backingScale: 2, flipped: true))
        XCTAssertTrue(geometry.isDraggable(CGPoint(x: 20, y: 580), bounds: bounds,
                                           backingScale: 2, flipped: false))
        XCTAssertFalse(geometry.isDraggable(CGPoint(x: 20, y: 20), bounds: bounds,
                                            backingScale: 1, flipped: true))
    }

    func testGenerationInvalidatesSameSizeSnapshotAndRejectsStaleReport() throws {
        var geometry = SurfaceGeometry()
        try geometry.update(arm(0, 1), bounds: bounds, backingScale: 2)
        XCTAssertTrue(geometry.isDraggable(CGPoint(x: 20, y: 20), bounds: bounds,
                                           backingScale: 2, flipped: true))

        geometry.invalidate()
        XCTAssertEqual(geometry.geometryGeneration, 1)
        XCTAssertFalse(geometry.isDraggable(CGPoint(x: 20, y: 20), bounds: bounds,
                                            backingScale: 2, flipped: true))
        XCTAssertThrowsError(try geometry.update(arm(0, 2), bounds: bounds, backingScale: 2)) { error in
            XCTAssertEqual(error as? ShellError, .staleGeometry)
        }
        try geometry.update(["phase": "disarm", "geometryGeneration": 1, "revision": 2],
                            bounds: bounds, backingScale: 2)
        try geometry.update(arm(1, 3), bounds: bounds, backingScale: 2)
        XCTAssertTrue(geometry.isDraggable(CGPoint(x: 20, y: 20), bounds: bounds,
                                           backingScale: 2, flipped: true))
    }

    func testStateDeduperSuppressesIdenticalWindowState() {
        var deduper = WindowStateDeduper()
        let initial = WindowStateSnapshot(fullscreen: false, minimized: false, geometryGeneration: 4)
        XCTAssertTrue(deduper.shouldEmit(initial))
        XCTAssertFalse(deduper.shouldEmit(initial))
        XCTAssertTrue(deduper.shouldEmit(WindowStateSnapshot(fullscreen: true, minimized: false, geometryGeneration: 4)))
        XCTAssertTrue(deduper.shouldEmit(WindowStateSnapshot(fullscreen: true, minimized: false, geometryGeneration: 5)))
        XCTAssertFalse(deduper.shouldEmit(WindowStateSnapshot(fullscreen: true, minimized: false, geometryGeneration: 5)))
        deduper.reset()
        XCTAssertTrue(deduper.shouldEmit(initial))
    }

    func testRejectedReportDisarmsWithoutAdvancingNativeGeneration() throws {
        var geometry = SurfaceGeometry()
        try geometry.update(arm(0, 1), bounds: bounds, backingScale: 2)
        geometry.disarm()
        XCTAssertEqual(geometry.geometryGeneration, 0)
        XCTAssertFalse(geometry.isDraggable(CGPoint(x: 20, y: 20), bounds: bounds,
                                            backingScale: 2, flipped: true))
        try geometry.update(arm(0, 2), bounds: bounds, backingScale: 2)
        XCTAssertTrue(geometry.isDraggable(CGPoint(x: 20, y: 20), bounds: bounds,
                                           backingScale: 2, flipped: true))
    }

    func testResetAdvancesGenerationWhenRevisionRestarts() throws {
        var geometry = SurfaceGeometry()
        try geometry.update(arm(0, 7), bounds: bounds, backingScale: 2)
        geometry.reset()
        XCTAssertEqual(geometry.revision, -1)
        XCTAssertEqual(geometry.geometryGeneration, 1)
        XCTAssertThrowsError(try geometry.update(arm(0, 1), bounds: bounds, backingScale: 2))
        try geometry.update(arm(1, 1), bounds: bounds, backingScale: 2)
        XCTAssertTrue(geometry.isDraggable(CGPoint(x: 20, y: 20), bounds: bounds,
                                           backingScale: 2, flipped: true))
    }
}
