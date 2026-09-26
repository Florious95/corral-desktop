import AppKit
import CorralContracts
import CorralUI
import XCTest

@MainActor
final class NativeWorkspaceTests: XCTestCase {
    func testIssue296SurfaceTokenMapsToNativeColor() throws {
        let color = try XCTUnwrap(CorralAestheticTokens.surface0.usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 0x17 / 255.0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 0x1B / 255.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 0x22 / 255.0, accuracy: 0.001)
        XCTAssertEqual(DesignTokens.Color.surface0, 0x171B22)
    }

    func testDeviceBadgeHidesForSingleDeviceAndCapsMultiDeviceWidth() throws {
        let badge = CorralDeviceBadgeView(frame: .zero)
        badge.update(deviceNames: ["One device"])
        XCTAssertTrue(badge.isHidden)

        let names = [String](repeating: "A very long device name", count: 8)
        badge.update(deviceNames: names)
        badge.layoutSubtreeIfNeeded()
        XCTAssertFalse(badge.isHidden)
        XCTAssertLessThanOrEqual(badge.frame.width, 64)
        XCTAssertLessThanOrEqual(badge.maximumWidth, 64)
        XCTAssertEqual(badge.toolTip, names.joined(separator: ", "))
        XCTAssertEqual(badge.displayedText, names.joined(separator: " · "))
        let label = try XCTUnwrap(badge.subviews.first as? NSTextField)
        XCTAssertEqual(label.cell?.lineBreakMode, .byTruncatingTail)
        XCTAssertTrue(label.cell?.truncatesLastVisibleLine == true)
    }

    func testNestedSplitLayoutRetainsStageViewsAndCreatesEachSplitter() throws {
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let first = NSView()
        let second = NSView()
        let third = NSView()
        let layout = CorralSplitLayout.split(.columns, [
            .leaf(firstID),
            .split(.rows, [.leaf(secondID), .leaf(thirdID)])
        ])

        let workspace = SplitWorkspaceView(layout: layout, stages: [
            firstID: first,
            secondID: second,
            thirdID: third
        ])

        XCTAssertEqual(workspace.splitterCount, 2)
        XCTAssertEqual(workspace.stageViews.count, 3)
        let rootSplit = try XCTUnwrap(workspace.subviews.first as? NSSplitView)
        XCTAssertTrue(rootSplit.isVertical)
        let nestedSplit = rootSplit.subviews.compactMap { $0 as? NSSplitView }.first
        XCTAssertTrue(nestedSplit?.isVertical == false)
        XCTAssertNotNil(first.superview)
        XCTAssertNotNil(second.superview)
        XCTAssertNotNil(third.superview)
    }

    func testTabSwitchOnlyChangesVisibilityAndKeepsStageViewsAttached() {
        let firstView = NSView()
        let secondView = NSView()
        let first = CorralTab(title: "One", contentView: firstView)
        let second = CorralTab(title: "Two", contentView: secondView)
        let workspace = CorralWorkspaceView(tabs: [first, second])
        let originalParent = firstView.superview

        XCTAssertFalse(firstView.isHidden)
        XCTAssertTrue(secondView.isHidden)
        workspace.selectTab(id: second.id)

        XCTAssertTrue(firstView.isHidden)
        XCTAssertFalse(secondView.isHidden)
        XCTAssertTrue(firstView.superview === originalParent)
        XCTAssertTrue(secondView.superview === workspace.stageContainer)
        XCTAssertEqual(workspace.stageContainer.subviews.count, 2)
        XCTAssertEqual(workspace.activeTabID, second.id)
    }

    func testWindowUsesTransparentFullSizeNativeTitlebar() {
        let window = CorralWindow(title: "Test")
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
    }

    func testSidebarBuildsDeviceAndSessionHierarchy() {
        let session = CorralSidebarSession(name: "shell")
        let sidebar = CorralSidebarView(devices: [CorralSidebarDevice(name: "Laptop", sessions: [session])])

        XCTAssertEqual(sidebar.outlineView(sidebar.outlineView, numberOfChildrenOfItem: nil), 1)
        let device = sidebar.outlineView(sidebar.outlineView, child: 0, ofItem: nil)
        XCTAssertEqual(sidebar.outlineView(sidebar.outlineView, numberOfChildrenOfItem: device), 1)
        XCTAssertTrue(sidebar.deviceBadgeView.isHidden)
    }
}
