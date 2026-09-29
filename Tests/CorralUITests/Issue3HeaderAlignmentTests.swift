import AppKit
import CorralContracts
@testable import CorralUI
import XCTest

@MainActor
final class Issue3HeaderAlignmentTests: XCTestCase {
    func testCollapsedSidebarToggleAndTabAlignWithTrafficLightsToOnePoint() throws {
        let tab = CorralTab(title: "agent-cli", contentView: NSView())
        let workspace = CorralWorkspaceView(tabs: [tab])
        let controller = CorralWindowController(workspaceView: workspace)
        let window = try XCTUnwrap(controller.window as? CorralWindow)
        defer { window.close() }

        workspace.setSidebarCollapsed(true)
        window.contentView?.layoutSubtreeIfNeeded()
        workspace.layoutSubtreeIfNeeded()
        workspace.tabBar.layoutSubtreeIfNeeded()

        let trafficLight = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let toggle = try XCTUnwrap(issue3Descendants(of: workspace.tabBar).first {
            $0.accessibilityIdentifier() == "corral.sidebar.expand"
        })
        let tabItem = try XCTUnwrap(issue3Descendants(of: workspace.tabBar).first {
            $0.accessibilityIdentifier() == "corral.tab"
        })
        XCTAssertFalse(toggle.isHidden)
        XCTAssertFalse(tabItem.isHidden)

        let trafficLightCenterY = trafficLight.convert(
            NSPoint(x: trafficLight.bounds.midX, y: trafficLight.bounds.midY), to: nil
        ).y
        let toggleCenterY = toggle.convert(
            NSPoint(x: toggle.bounds.midX, y: toggle.bounds.midY), to: nil
        ).y
        let tabCenterY = tabItem.convert(
            NSPoint(x: tabItem.bounds.midX, y: tabItem.bounds.midY), to: nil
        ).y

        XCTAssertEqual(toggleCenterY, trafficLightCenterY, accuracy: 1,
                       "Sidebar toggle centerY \(toggleCenterY) must align with traffic-light centerY \(trafficLightCenterY)")
        XCTAssertEqual(tabCenterY, trafficLightCenterY, accuracy: 1,
                       "Tab item centerY \(tabCenterY) must align with traffic-light centerY \(trafficLightCenterY)")
    }
}

@MainActor
private func issue3Descendants(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(issue3Descendants)
}

