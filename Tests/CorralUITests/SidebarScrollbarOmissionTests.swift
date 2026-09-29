import AppKit
import CorralContracts
@testable import CorralUI
import XCTest

@MainActor
final class SidebarScrollbarOmissionTests: XCTestCase {
    func testSpacesAndAgentsHideScrollbarsAndRetainScrollableContent() throws {
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

        let spacesScroll = try scrollView(containing: sidebar.spacesTable, in: sidebar)
        let agentsScroll = try scrollView(containing: sidebar.agentsTable, in: sidebar)
        XCTAssertFalse(spacesScroll.hasVerticalScroller, "Spaces must not display a vertical scrollbar")
        XCTAssertFalse(spacesScroll.hasHorizontalScroller, "Spaces must not display a horizontal scrollbar")
        XCTAssertFalse(agentsScroll.hasVerticalScroller, "Agents must not display a vertical scrollbar")
        XCTAssertFalse(agentsScroll.hasHorizontalScroller, "Agents must not display a horizontal scrollbar")

        assertScrollableContent(spacesScroll)
        assertScrollableContent(agentsScroll)
    }

    private func scrollView(containing table: NSTableView, in sidebar: CorralSidebarView) throws -> NSScrollView {
        try XCTUnwrap(descendants(of: sidebar).compactMap { $0 as? NSScrollView }.first { $0.documentView === table })
    }

    private func assertScrollableContent(_ scrollView: NSScrollView, file: StaticString = #filePath, line: UInt = #line) {
        guard let document = scrollView.documentView else {
            XCTFail("Scroll view must retain its document view", file: file, line: line)
            return
        }
        let clipView = scrollView.contentView
        XCTAssertGreaterThan(document.frame.height, clipView.bounds.height, "The fixture must contain vertically scrollable content", file: file, line: line)
        let initialY = clipView.bounds.origin.y
        let maximumY = max(0, document.frame.maxY - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: maximumY))
        scrollView.reflectScrolledClipView(clipView)
        XCTAssertGreaterThan(clipView.bounds.origin.y, initialY, "The scroll view must retain a scrollable range", file: file, line: line)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: initialY))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
