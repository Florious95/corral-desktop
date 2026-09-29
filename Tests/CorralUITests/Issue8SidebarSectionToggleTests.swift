import AppKit
import CorralContracts
@testable import CorralUI
import XCTest

@MainActor
final class Issue8SidebarSectionToggleTests: XCTestCase {
    func testAgentsThenSpacesHeaderTogglesKeepSidebarAndWindowGeometryStable() throws {
        _ = NSApplication.shared
        let workspace = CorralWorkspaceView(tabs: [CorralTab(title: "Workspace", contentView: NSView())])
        let controller = CorralWindowController(workspaceView: workspace, contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860))
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        window.orderBack(nil)

        let sidebar = workspace.sidebar
        let spaces = (0..<12).map { CorralSidebarSpace(name: "Project \($0)") }
        sidebar.setSpaces(spaces)
        sidebar.setAgents((0..<24).map { index in
            CorralSidebarAgent(name: "Session \(index)", spaceID: spaces[index % spaces.count].id,
                               sessionID: SessionID("session-\(index)"))
        })
        window.contentView?.layoutSubtreeIfNeeded()
        workspace.layoutSubtreeIfNeeded()
        sidebar.layoutSubtreeIfNeeded()

        let headers = descendants(of: sidebar).compactMap { $0 as? CorralSidebarSectionHeader }
        let agentsHeader = try XCTUnwrap(headers.first { $0.title == "Agents" })
        let spacesHeader = try XCTUnwrap(headers.first { $0.title == "Spaces" })
        let originalWindowWidth = window.frame.width
        let originalSidebarWidth = sidebar.bounds.width
        let originalAgentsFrame = sidebar.convert(agentsHeader.bounds, from: agentsHeader)
        XCTAssertGreaterThanOrEqual(originalSidebarWidth, 260)
        XCTAssertEqual(originalAgentsFrame.height, CorralSidebarSectionHeader.height, accuracy: 1)
        XCTAssertGreaterThan(originalAgentsFrame.minY, 150, "Agents header must begin below the Spaces section, not at the sidebar footer")

        try click(agentsHeader, in: window)
        window.contentView?.layoutSubtreeIfNeeded()
        workspace.layoutSubtreeIfNeeded()
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertFalse(sidebar.agentsExpanded)
        let collapsedAgentsFrame = sidebar.convert(agentsHeader.bounds, from: agentsHeader)
        XCTAssertEqual(collapsedAgentsFrame.height, CorralSidebarSectionHeader.height, accuracy: 1)
        XCTAssertGreaterThan(collapsedAgentsFrame.minY, 150, "Collapsing Agents must not drop its header to the bottom of the sidebar")
        XCTAssertFalse(workspace.isSidebarCollapsed, "A section click must not toggle the whole sidebar")
        XCTAssertEqual(sidebar.bounds.width, originalSidebarWidth, accuracy: 1)
        XCTAssertEqual(window.frame.width, originalWindowWidth, accuracy: 1)

        try click(agentsHeader, in: window)
        try click(spacesHeader, in: window)
        window.contentView?.layoutSubtreeIfNeeded()
        workspace.layoutSubtreeIfNeeded()
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertFalse(sidebar.spacesExpanded)
        XCTAssertGreaterThan(sidebar.bounds.width, 260, "Collapsing Spaces must preserve the sidebar's 260–280pt width")
        XCTAssertEqual(window.frame.width, originalWindowWidth, accuracy: 1, "Section toggles must not resize the window")
        XCTAssertFalse(workspace.isSidebarCollapsed, "A section click must not trigger the sidebar-collapse control")

        try click(spacesHeader, in: window)
        window.contentView?.layoutSubtreeIfNeeded()
        workspace.layoutSubtreeIfNeeded()
        sidebar.layoutSubtreeIfNeeded()
        let restoredAgentsFrame = sidebar.convert(agentsHeader.bounds, from: agentsHeader)
        XCTAssertTrue(sidebar.spacesExpanded)
        XCTAssertGreaterThan(restoredAgentsFrame.minY, 150)
        XCTAssertEqual(sidebar.bounds.width, originalSidebarWidth, accuracy: 1)
        XCTAssertEqual(window.frame.width, originalWindowWidth, accuracy: 1)
    }

    private func click(_ header: CorralSidebarSectionHeader, in window: NSWindow) throws {
        let point = header.convert(NSPoint(x: header.bounds.maxX - 4, y: header.bounds.midY), to: nil)
        let content = try XCTUnwrap(window.contentView)
        let hit = content.hitTest(content.convert(point, from: nil))
        XCTAssertTrue(hit === header || hit?.isDescendant(of: header) == true, "Synthetic click must hit the requested section header")
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
        header.mouseDown(with: down)
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
        header.mouseUp(with: up)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
