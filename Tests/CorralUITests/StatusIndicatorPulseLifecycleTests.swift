import AppKit
import CorralUI
import QuartzCore
import XCTest

@MainActor
final class StatusIndicatorPulseLifecycleTests: XCTestCase {
    func testWorkingPulsePersistsAcrossTransactionsAndStopsOnStatusChanges() async throws {
        let indicator = CorralStatusIndicatorView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        let layer = try XCTUnwrap(indicator.layer)
        XCTAssertNil(indicator.window)

        for nextStatus in [CorralStatusIndicatorView.Status.blocked, .idle] {
            indicator.status = .working
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(50))
            let pulse = try XCTUnwrap(layer.animation(forKey: "workingPulse") as? CABasicAnimation)
            XCTAssertEqual(pulse.keyPath, "opacity")
            XCTAssertEqual(pulse.duration, 1)
            XCTAssertTrue(pulse.autoreverses)
            XCTAssertEqual(pulse.repeatCount, .infinity)
            XCTAssertFalse(pulse.isRemovedOnCompletion, "Status changes, not transaction completion, own the pulse lifetime")

            indicator.refreshTheme()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertNotNil(layer.animation(forKey: "workingPulse"))

            indicator.status = nextStatus
            CATransaction.flush()
            XCTAssertNil(layer.animation(forKey: "workingPulse"))
            XCTAssertEqual(layer.opacity, 1)
            XCTAssertEqual(layer.shadowOpacity, nextStatus == .blocked ? 0.45 : 0)
            if nextStatus == .blocked {
                XCTAssertEqual(layer.shadowColor, CorralAestheticTokens.warning.cgColor)
            }
        }
    }
}
