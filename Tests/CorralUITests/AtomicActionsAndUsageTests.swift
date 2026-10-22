import AppKit
import XCTest
@testable import CorralUI

@MainActor
final class AtomicActionsAndUsageTests: XCTestCase {
    private var context: CorralActionContext {
        .init(ready: true, mode: .gui, running: true, switching: false, implemented: [.metricsPanel, .modeSwitch])
    }

    func testCapabilityGatesAndExecutionAreProviderIndependent() {
        let action = CorralUsageAction(scopes: [.session])
        XCTAssertEqual(action.availability(in: context), .enabled) // A read query does not stop active work.
        XCTAssertEqual(CorralUsageAction(scopes: []).availability(in: context), .hidden)
        var current = context
        current.implemented = []
        XCTAssertEqual(action.availability(in: current), .hidden)
        current = context; current.mode = .tui
        guard case .disabled = action.availability(in: current) else { return XCTFail("Usage in TUI enabled") }
        XCTAssertEqual(CorralModeSwitchAction().availability(in: current), .enabled)
        current = context; current.switching = true
        var invoked = false
        XCTAssertFalse(action.perform(in: current) { _ in invoked = true })
        XCTAssertFalse(invoked)
        XCTAssertTrue(action.perform(in: context) { XCTAssertEqual($0, .metricsPanel); invoked = true })
        XCTAssertTrue(invoked)
    }

    func testMenuOmitsUnsupportedActionsAndDisablesWithReasons() {
        _ = NSApplication.shared
        let entries: [CorralActionMenuEntry] = [
            .init(spec: .spec(.usage), availability: .disabled("会话尚未就绪")),
            .init(spec: .spec(.history), availability: .hidden),
            .init(spec: .spec(.terminal), availability: .enabled)
        ]
        var invoked: [CorralActionID] = []
        let menu = CorralActionMenu(entries: entries) { invoked.append($0) }
        XCTAssertEqual(menu.entries.count, 2)
        XCTAssertFalse(menu.performAction(.history))
        XCTAssertFalse(menu.performAction(.usage))
        XCTAssertTrue(menu.performAction(.terminal))
        XCTAssertEqual(invoked, [.terminal])
        XCTAssertEqual(menu.items.first(where: { $0.representedObject as? String == "usage" })?.toolTip, "会话尚未就绪")
    }

    func testHeaderActionsKeepSplitCloseAreaClear() {
        let header = CorralViewportHeaderView(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
        header.trailingInset = 34
        header.apply(.init(title: "A long session title", phase: .ready, canSwitch: true, hasActions: true))
        header.layoutSubtreeIfNeeded()
        XCTAssertFalse(header.moreButton.isHidden)
        XCTAssertLessThanOrEqual(header.moreButton.frame.maxX, 286)
        XCTAssertLessThan(header.modeControl.frame.maxX, header.moreButton.frame.minX)
        XCTAssertTrue(header.hitTest(header.moreButton.frame.center) === header.moreButton)
        header.apply(.init(title: "Unsupported", hasActions: false))
        XCTAssertTrue(header.moreButton.isHidden)
    }

    private func decode(_ context: String = #"{"tokens":2500,"contextWindow":10000,"percent":25}"#, cost: String = "0.1234") throws -> CorralSessionUsage {
        try JSONDecoder().decode(CorralSessionUsage.self, from: Data("""
        {"tokens":{"input":1200,"output":300,"cacheRead":4000,"cacheWrite":500,"total":6000},"cost":\(cost),"contextUsage":\(context)}
        """.utf8))
    }

    private func descendants(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + descendants($0) } }
    private func label(_ id: String, in dashboard: CorralUsageDashboardController) -> NSTextField? {
        descendants(dashboard.view).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "corral.usage.\(id)" }
    }

    func testDashboardShowsAuthoritativeMetricsAndUnknownContextWithoutFabrication() throws {
        _ = NSApplication.shared
        let dashboard = CorralUsageDashboardController(sessionTitle: "Session A")
        dashboard.loadViewIfNeeded()
        dashboard.apply(.ready(try decode(), Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(label("total", in: dashboard)?.stringValue, "6,000")
        XCTAssertEqual(label("cost", in: dashboard)?.stringValue, "$0.1234")
        XCTAssertEqual(label("context.percent", in: dashboard)?.stringValue, "25.0%")
        XCTAssertTrue(label("quota", in: dashboard)?.stringValue.contains("未提供") == true)
        dashboard.apply(.ready(try decode(#"{"tokens":null,"contextWindow":10000,"percent":null}"#), Date()))
        XCTAssertEqual(label("context.percent", in: dashboard)?.stringValue, "未知")
        XCTAssertTrue(label("context.detail", in: dashboard)?.stringValue.contains("未知 / 10,000") == true)
        let meter = try XCTUnwrap(descendants(dashboard.view).first { $0 is NSProgressIndicator })
        XCTAssertTrue(meter.isHidden)
        dashboard.apply(.failed("无法读取"))
        XCTAssertEqual(label("total", in: dashboard)?.stringValue, "—")
        XCTAssertEqual(label("cost", in: dashboard)?.stringValue, "—")
    }

    func testZeroIsNotUnknownAndOverCapacityIsNotClampedInLabel() throws {
        let dashboard = CorralUsageDashboardController(sessionTitle: "Empty")
        dashboard.loadViewIfNeeded()
        dashboard.apply(.ready(try decode(#"{"tokens":0,"contextWindow":10000,"percent":0}"#, cost: "0"), Date()))
        XCTAssertEqual(label("cost", in: dashboard)?.stringValue, "$0.0000")
        XCTAssertEqual(label("context.percent", in: dashboard)?.stringValue, "0.0%")
        dashboard.apply(.ready(try decode(#"{"tokens":12500,"contextWindow":10000,"percent":125}"#), Date()))
        XCTAssertEqual(label("context.percent", in: dashboard)?.stringValue, "125.0%")
        XCTAssertEqual((descendants(dashboard.view).first { $0 is NSProgressIndicator } as? NSProgressIndicator)?.doubleValue, 100)
        XCTAssertFalse(try decode(cost: "-1").isValid)
        XCTAssertThrowsError(try decode(#"{"tokens":-1,"contextWindow":10000,"percent":-1}"#))
    }

    func testSmallWindowScrollsMetricsWhileCloseRemainsVisible() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        let dashboard = CorralUsageDashboardController(sessionTitle: "Small window")
        dashboard.present(over: window)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(dashboard.view.frame.size, NSSize(width: 448, height: 328))
        let scroll = try XCTUnwrap(descendants(dashboard.view).first { $0 is NSScrollView } as? NSScrollView)
        XCTAssertGreaterThan(scroll.documentView!.bounds.height, scroll.contentView.bounds.height)
        let close = try XCTUnwrap(descendants(dashboard.view).first { $0.accessibilityIdentifier() == "corral.usage.close" })
        XCTAssertTrue(dashboard.view.bounds.contains(close.convert(close.bounds, to: dashboard.view)))
        dashboard.handleEscape()
    }

    func testDashboardLayoutAndCloseRestoreTheExistingDialogSurface() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let dashboard = CorralUsageDashboardController(sessionTitle: String(repeating: "长会话名", count: 100))
        var closed = false
        dashboard.onClose = { closed = true }
        dashboard.present(over: window)
        dashboard.apply(.ready(try decode(), Date()))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(dashboard.presentedWindow === window)
        for field in descendants(dashboard.view).filter({ $0 is NSTextField || $0 is NSButton }) {
            let bounds = field.convert(field.bounds, to: dashboard.view)
            XCTAssertTrue(dashboard.view.bounds.insetBy(dx: -1, dy: -1).contains(bounds), "Clipped control: \(field) \(bounds)")
        }
        dashboard.handleEscape()
        XCTAssertTrue(closed)
        XCTAssertNil(dashboard.presentedWindow)
        XCTAssertNil(dashboard.view.window)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
