import AppKit
@testable import CorralUI
import XCTest

@MainActor
final class MVPWorkspaceViewTests: XCTestCase {
    func testMVPChromeMatchesMeasuredSidebarControlsAndDispatchesActions() throws {
        let workspace = CorralMVPWorkspaceView(frame: NSRect(x: 0, y: 0, width: 1400, height: 980))
        workspace.layoutSubtreeIfNeeded()
        var collapseCount = 0
        var hostsCount = 0
        workspace.onToggleSidebar = { collapseCount += 1 }
        workspace.onShowAllHosts = { hostsCount += 1 }

        let titleBar = try XCTUnwrap(workspace.collapseButton.superview)
        XCTAssertEqual(workspace.sidebar.frame.width, 280, accuracy: 0.1)
        XCTAssertEqual(workspace.collapseButton.frame.minX, 243, accuracy: 0.1)
        XCTAssertEqual(workspace.collapseButton.frame.size, NSSize(width: 28, height: 27))
        XCTAssertEqual(titleBar.bounds.maxY - workspace.collapseButton.frame.maxY, 5, accuracy: 0.1)
        workspace.collapseButton.performClick(nil)
        XCTAssertEqual(collapseCount, 1)

        let footer = try XCTUnwrap(workspace.devicesButton.superview)
        XCTAssertEqual(footer.frame.height, 44, accuracy: 0.1)
        XCTAssertEqual(workspace.devicesButton.title, "查看所有主机")
        XCTAssertEqual(workspace.devicesButton.frame.minX, 12, accuracy: 0.1)
        XCTAssertEqual(workspace.devicesButton.frame.size, NSSize(width: 222, height: 35))
        workspace.devicesButton.performClick(nil)
        XCTAssertEqual(hostsCount, 1)
    }

    func testSessionRowsRouteEachCompletedClickDirectlyAndKeepOneStageAttached() throws {
        let firstID = UUID(), secondID = UUID()
        let workspace = CorralMVPWorkspaceView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        workspace.layoutSubtreeIfNeeded()
        var selected: [UUID] = []
        workspace.onSelectAgent = { selected.append($0) }
        workspace.setSessions([
            CorralMVPSessionRow(id: firstID, name: "first", status: "working", provider: "pi"),
            CorralMVPSessionRow(id: secondID, name: "second", status: "idle", provider: "codex", isSelected: true)
        ])

        let table = try XCTUnwrap(descendants(of: workspace.sidebar).compactMap { $0 as? CorralAgentTableView }.first)
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertEqual(workspace.sidebar.frame.width, 280)
        let firstCell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? CorralSidebarCellView)
        XCTAssertEqual(try XCTUnwrap(descendants(of: firstCell).compactMap { $0 as? CorralStatusIndicatorView }.first).status, .working)
        XCTAssertEqual(try XCTUnwrap(descendants(of: firstCell).compactMap { $0 as? CorralProviderIconView }.first).provider, "pi")

        let stage = NSView()
        let permanentStageContainer = workspace.stageContainer
        workspace.attachStageView(stage)
        workspace.attachStageView(stage)
        XCTAssertIdentical(workspace.stageContainer, permanentStageContainer)
        XCTAssertIdentical(stage.superview, permanentStageContainer)
        XCTAssertEqual(permanentStageContainer.subviews.filter { $0 === stage }.count, 1)

        table.dispatchClickIfCompleted(from: 0, to: 0, wasDragged: false)
        table.dispatchClickIfCompleted(from: 1, to: 1, wasDragged: false)
        table.dispatchClickIfCompleted(from: 0, to: 0, wasDragged: true)
        XCTAssertEqual(selected, [firstID, secondID], "each completed row click dispatches its UUID; drags never open")

        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? CorralSidebarCellView)
        XCTAssertTrue(cell.accessibilityPerformPress())
        XCTAssertEqual(selected, [firstID, secondID, firstID])
        workspace.setSessions([CorralMVPSessionRow(id: firstID, name: "first", isSelected: true)])
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(table.selectedRow, 0)
        XCTAssertIdentical(stage.superview, permanentStageContainer)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
