import AppKit
import CorralContracts
@testable import CorralUI
import XCTest

@MainActor
final class MotionEffectsTests: XCTestCase {
    func testTabBarSwitchPerformsAnimatedTransition() throws {
        _ = NSApplication.shared
        let first = CorralTab(title: "First")
        let second = CorralTab(title: "Second")
        let workspace = CorralWorkspaceView(tabs: [first, second])
        let controller = CorralWindowController(workspaceView: workspace)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        window.orderBack(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        workspace.tabBar.layoutSubtreeIfNeeded()

        let tabBar = workspace.tabBar
        let before = try XCTUnwrap(tabBar.activeCapsuleFrame)
        let capsule = try XCTUnwrap(descendants(of: tabBar).first {
            guard let layer = $0.layer else { return false }
            return layer.cornerRadius == 6 && layer.borderWidth == 1
        })
        tabBar.setTabs([first, second], selectedTabID: second.id)
        window.contentView?.layoutSubtreeIfNeeded()
        tabBar.layoutSubtreeIfNeeded()
        let after = try XCTUnwrap(tabBar.activeCapsuleFrame)
        XCTAssertNotEqual(before.origin, after.origin, "The active capsule must move to the newly selected Tab")

        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertTrue(hasInFlightMotion(in: capsule), "Tab selection must animate the capsule instead of changing its frame instantaneously")
    }

    func testFavoriteSessionTriggersAnimatedPinToTop() throws {
        _ = NSApplication.shared
        let workspace = CorralWorkspaceView(tabs: [CorralTab(title: "Workspace", contentView: NSView())])
        let controller = CorralWindowController(workspaceView: workspace)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        window.orderBack(nil)

        let sidebar = workspace.sidebar
        let space = CorralSidebarSpace(name: "Project")
        sidebar.setSpaces([space])
        let first = CorralSidebarAgent(name: "First", spaceID: space.id, sessionID: SessionID("first"))
        var target = CorralSidebarAgent(name: "Favorite", spaceID: space.id, sessionID: SessionID("favorite"))
        sidebar.setAgents([first, target])
        window.contentView?.layoutSubtreeIfNeeded()
        workspace.layoutSubtreeIfNeeded()
        sidebar.layoutSubtreeIfNeeded()

        let table = sidebar.agentsTable
        XCTAssertEqual(sidebar.agents.first?.sessionID, first.sessionID)
        XCTAssertEqual(sidebar.agents.firstIndex { $0.sessionID == target.sessionID }, 1)
        _ = table.rowView(atRow: 1, makeIfNecessary: true)
        CATransaction.flush()

        target.isFavorite = true
        sidebar.setAgents([first, target])
        window.contentView?.layoutSubtreeIfNeeded()
        workspace.layoutSubtreeIfNeeded()
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertEqual(sidebar.agents.first?.sessionID, target.sessionID, "Favoriting must still reorder the session to the top")
        let pinnedRow = try XCTUnwrap(table.rowView(atRow: 0, makeIfNecessary: true))
        XCTAssertTrue(pinnedRow.frame.intersects(table.rect(ofRow: 0)))

        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertTrue(hasInFlightMotion(in: table), "Pinning a favorite to the top must animate the row movement")
    }

    private func hasInFlightMotion(in root: NSView) -> Bool {
        ([root] + descendants(of: root)).compactMap(\.layer).contains { layer in
            if !(layer.animationKeys() ?? []).isEmpty { return true }
            guard let presentation = layer.presentation() else { return false }
            return hypot(presentation.position.x - layer.position.x, presentation.position.y - layer.position.y) > 0.5
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
