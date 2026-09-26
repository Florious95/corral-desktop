import AppKit
import CorralContracts
@testable import CorralUI
import XCTest

@MainActor
final class NativeWorkspaceTests: XCTestCase {
    func testIssue296SurfaceAndSettingsControlsUseHighContrastNativeStyles() throws {
        let color = try XCTUnwrap(CorralAestheticTokens.surface0.usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 0x17 / 255.0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 0x1B / 255.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 0x22 / 255.0, accuracy: 0.001)
        XCTAssertEqual(DesignTokens.Color.surface0, 0x171B22)

        let workspace = CorralWorkspaceView()
        for button in [workspace.titleBar.settingsButton, workspace.sidebar.settingsButton] {
            XCTAssertTrue(button.contentTintColor?.isEqual(CorralAestheticTokens.text) == true)
            XCTAssertEqual(button.layer?.borderWidth, 1)
            XCTAssertEqual(button.layer?.borderColor, CorralAestheticTokens.border.cgColor)
            XCTAssertEqual(button.layer?.backgroundColor, CorralAestheticTokens.surface2.cgColor)
        }
        XCTAssertEqual(workspace.titleBar.layer?.backgroundColor, CorralAestheticTokens.surface0.cgColor)
        XCTAssertEqual(workspace.sidebar.layer?.backgroundColor, CorralAestheticTokens.surface0.cgColor)
    }

    func testSessionContextMenuContainsOnlyLegalActions() {
        let sessionID = UUID()
        var renamed: UUID?
        var closed: UUID?
        let controller = SessionContextMenuBuilder.makeMenu(
            for: sessionID,
            onRename: { renamed = $0 },
            onClose: { closed = $0 }
        )

        XCTAssertEqual(controller.menu.items.map(\.title), ["Rename Session…", "Close Session"])
        XCTAssertFalse(controller.menu.items.contains { $0.title.localizedCaseInsensitiveContains("split") })
        XCTAssertTrue(controller.menu.items.allSatisfy { $0.target === controller })
        XCTAssertNil(renamed)
        XCTAssertNil(closed)
    }

    func testDeviceBadgeHidesForSingleDeviceAndCapsLongMultiDeviceLabel() throws {
        let badge = CorralDeviceBadgeView(frame: .zero)
        badge.update(deviceName: "One device", deviceCount: 1)
        XCTAssertTrue(badge.isHidden)
        XCTAssertNil(badge.toolTip)

        let longName = String(repeating: "Long device name ", count: 8)
        badge.update(deviceName: longName, deviceCount: 2)
        badge.frame = NSRect(x: 0, y: 0, width: 64, height: 18)
        badge.layoutSubtreeIfNeeded()
        XCTAssertFalse(badge.isHidden)
        XCTAssertLessThanOrEqual(badge.maximumWidth, 64)
        XCTAssertEqual(badge.toolTip, longName)
        XCTAssertEqual(badge.displayedText, longName)
        let label = try XCTUnwrap(badge.subviews.first as? NSTextField)
        XCTAssertEqual(label.cell?.lineBreakMode, .byTruncatingTail)
        XCTAssertTrue(label.cell?.truncatesLastVisibleLine == true)
    }

    func testSidebarSessionRowsHideSingleDeviceBadgeAndShowCompactMultiDeviceBadge() throws {
        let longName = String(repeating: "Remote device ", count: 8)
        let session = CorralSidebarSession(name: "shell")
        let single = CorralSidebarView(devices: [CorralSidebarDevice(name: longName, sessions: [session])])
        let singleBadge = try XCTUnwrap(sessionBadge(in: single, deviceIndex: 0))
        XCTAssertTrue(singleBadge.isHidden)

        let multiple = CorralSidebarView(devices: [
            CorralSidebarDevice(name: longName, sessions: [session]),
            CorralSidebarDevice(name: "Second", sessions: [])
        ])
        let multiBadge = try XCTUnwrap(sessionBadge(in: multiple, deviceIndex: 0))
        XCTAssertFalse(multiBadge.isHidden)
        XCTAssertEqual(multiBadge.toolTip, longName)
        XCTAssertLessThanOrEqual(multiBadge.maximumWidth, 64)
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

    func testTabSwitchRetainsTerminalSnapshotAndRecordsNoSessionOrGeometryWork() throws {
        let snapshot = makeSnapshot(rows: 45, columns: 12)
        XCTAssertTrue(snapshot.isValid)
        let first = CorralTab(title: "History", contentView: NSView(), terminalSnapshot: snapshot)
        let second = CorralTab(title: "Other", contentView: NSView())
        let workspace = CorralWorkspaceView(tabs: [first, second])
        let originalParent = first.contentView.superview

        for _ in 0..<3 {
            workspace.selectTab(id: second.id)
            workspace.selectTab(id: first.id)
            XCTAssertTrue(workspace.tabSwitchTelemetry.allCountsAreZero)
            XCTAssertFalse(workspace.tabSwitchTelemetry.isRecordingSwitch)
        }
        XCTAssertEqual(first.terminalSnapshot, snapshot)
        XCTAssertEqual(first.terminalSnapshot?.size.rows, 45)
        XCTAssertEqual(first.terminalSnapshot?.cells.count, 45 * 12)
        XCTAssertTrue(first.contentView.superview === originalParent)
        XCTAssertEqual(workspace.stageContainer.subviews.count, 2)
    }

    func testWindowDoubleClickZoomUsesVisibleFrameAndRestoresExactFrame() throws {
        let initial = NSRect(x: 41.25, y: 72.5, width: 780.5, height: 510.25)
        let controller = CorralWindowController(workspaceView: CorralWorkspaceView(), contentRect: initial)
        let window = try XCTUnwrap(controller.window as? CorralWindow)
        let original = window.frame
        let visibleFrame = NSRect(x: 70, y: 40, width: 1220, height: 820)

        controller.toggleZoom(to: visibleFrame)
        XCTAssertEqual(window.frame, visibleFrame)
        XCTAssertGreaterThanOrEqual(window.frame.minX, visibleFrame.minX)
        XCTAssertGreaterThanOrEqual(window.frame.minY, visibleFrame.minY)
        XCTAssertLessThanOrEqual(window.frame.maxX, visibleFrame.maxX)
        XCTAssertLessThanOrEqual(window.frame.maxY, visibleFrame.maxY)
        XCTAssertEqual(controller.savedFrameBeforeZoom, original)

        controller.toggleZoom(to: visibleFrame)
        XCTAssertEqual(window.frame, original)
        XCTAssertNil(controller.savedFrameBeforeZoom)
    }

    func testDevicePopoverRenameHonorsIMEEscapeAndPersistsThroughRepository() async throws {
        let record = try makeDeviceRecord()
        let repository = TestDeviceRepository(records: [record])
        let controller = DevicesPopoverViewController(repository: repository)
        controller.loadViewIfNeeded()
        try await controller.reloadDevices()

        controller.beginRenaming(record.id)
        XCTAssertEqual(controller.editingDeviceID, record.id)
        XCTAssertFalse(DevicesPopoverViewController.shouldCommitReturn(hasMarkedText: true))
        let imeCommit = try await controller.commitRenaming(record.id, to: "名称", hasMarkedText: true)
        XCTAssertFalse(imeCommit)
        let savedDuringComposition = await repository.savedDevices()
        XCTAssertEqual(savedDuringComposition.count, 0)
        controller.cancelRenaming(record.id)
        XCTAssertNil(controller.editingDeviceID)
        XCTAssertEqual(controller.devices.first?.name, record.name)

        controller.beginRenaming(record.id)
        let committed = try await controller.commitRenaming(record.id, to: "Renamed Device")
        XCTAssertTrue(committed)
        XCTAssertEqual(controller.devices.first?.name, "Renamed Device")
        let savedAfterRename = await repository.savedDevices()
        XCTAssertEqual(savedAfterRename.first?.name, "Renamed Device")
    }

    func testDevicePopoverRequiresVisibleSecondConfirmationBeforeCascadeDelete() async throws {
        let record = try makeDeviceRecord()
        let repository = TestDeviceRepository(records: [record])
        let controller = DevicesPopoverViewController(repository: repository)
        controller.loadViewIfNeeded()
        try await controller.reloadDevices()

        let prematureDelete = try await controller.confirmDeletion(of: record.id)
        XCTAssertFalse(prematureDelete)
        let deletionsBeforeConfirmation = await repository.deletedIDs()
        XCTAssertTrue(deletionsBeforeConfirmation.isEmpty)

        controller.requestDeletion(of: record.id)
        XCTAssertEqual(controller.deletionConfirmationDeviceID, record.id)
        let confirmationRow = try XCTUnwrap(controller.tableView(controller.tableView, viewFor: nil, row: 0))
        XCTAssertTrue(buttonTitles(in: confirmationRow).contains("Confirm Delete"))

        let confirmed = try await controller.confirmDeletion(of: record.id)
        XCTAssertTrue(confirmed)
        let deletionsAfterConfirmation = await repository.deletedIDs()
        XCTAssertEqual(deletionsAfterConfirmation, [record.id])
        XCTAssertTrue(controller.devices.isEmpty)
    }

    func testWindowUsesTransparentFullSizeNativeTitlebar() {
        let window = CorralWindow(title: "Test")
        XCTAssertTrue(window.backgroundColor.isEqual(CorralAestheticTokens.surface0))
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
    }

    func testSidebarBuildsDeviceAndSessionHierarchy() throws {
        let session = CorralSidebarSession(name: "shell")
        let sidebar = CorralSidebarView(devices: [CorralSidebarDevice(name: "Laptop", sessions: [session])])
        XCTAssertEqual(sidebar.outlineView(sidebar.outlineView, numberOfChildrenOfItem: nil), 1)
        let device = sidebar.outlineView(sidebar.outlineView, child: 0, ofItem: nil)
        XCTAssertEqual(sidebar.outlineView(sidebar.outlineView, numberOfChildrenOfItem: device), 1)
        XCTAssertTrue(sidebar.deviceBadgeView.isHidden)
        let sessionRow = try XCTUnwrap(sessionRow(in: sidebar, deviceIndex: 0))
        XCTAssertEqual(sessionRow.menu?.items.map(\.title), ["Rename Session…", "Close Session"])
    }

    func testDeviceRenameCommitsWhenInlineEditorLosesFocus() async throws {
        let record = try makeDeviceRecord()
        let repository = TestDeviceRepository(records: [record])
        let controller = DevicesPopoverViewController(repository: repository)
        controller.loadViewIfNeeded()
        try await controller.reloadDevices()
        controller.beginRenaming(record.id)

        let row = try XCTUnwrap(controller.tableView(controller.tableView, viewFor: nil, row: 0))
        let field = try XCTUnwrap(descendants(of: row).compactMap { $0 as? NSTextField }.first)
        field.stringValue = "Blur Saved"
        controller.controlTextDidEndEditing(Notification(name: Notification.Name("DeviceNameEndedEditing"), object: field))
        XCTAssertNil(controller.editingDeviceID)

        for _ in 0..<20 { await Task.yield() }
        let saved = await repository.savedDevices()
        XCTAssertEqual(saved.first?.name, "Blur Saved")
    }

    private func sessionRow(in sidebar: CorralSidebarView, deviceIndex: Int) -> NSView? {
        let device = sidebar.outlineView(sidebar.outlineView, child: deviceIndex, ofItem: nil)
        guard sidebar.outlineView(sidebar.outlineView, numberOfChildrenOfItem: device) > 0 else { return nil }
        let session = sidebar.outlineView(sidebar.outlineView, child: 0, ofItem: device)
        return sidebar.outlineView(sidebar.outlineView, viewFor: nil, item: session)
    }

    private func sessionBadge(in sidebar: CorralSidebarView, deviceIndex: Int) -> CorralDeviceBadgeView? {
        guard let row = sessionRow(in: sidebar, deviceIndex: deviceIndex) else { return nil }
        return descendants(of: row).compactMap { $0 as? CorralDeviceBadgeView }.first
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func buttonTitles(in view: NSView) -> [String] {
        var titles = (view as? NSButton).map { [$0.title] } ?? []
        for subview in view.subviews { titles += buttonTitles(in: subview) }
        return titles
    }

    private func makeSnapshot(rows: Int, columns: Int) -> TerminalGridSnapshot {
        let foreground = TerminalColor.rgba(RGBAColor(red: 230, green: 231, blue: 235))
        let background = TerminalColor.rgba(RGBAColor(red: 23, green: 27, blue: 34))
        let cells = (0..<(rows * columns)).map { index in
            let scalar = UnicodeScalar(33 + index % 80)!
            return TerminalCell(content: .cluster(String(scalar), columns: .one), foreground: foreground, background: background)
        }
        return TerminalGridSnapshot(
            size: GridSize(rows: rows, columns: columns),
            cells: cells,
            cursor: CursorDescriptor(row: rows - 1, column: columns - 1),
            generation: .initial
        )
    }

    private func makeDeviceRecord(id: String = "device-1", name: String = "Laptop") throws -> DeviceRecord {
        DeviceRecord(
            id: DeviceID(id),
            name: name,
            endpoint: try ApprovedEndpoint(host: "127.0.0.1", port: ApprovedEndpoint.developmentPort),
            credential: CredentialHandle("credential-\(id)")
        )
    }
}

private actor TestDeviceRepository: DeviceRepositoryProtocol {
    private var records: [DeviceRecord]
    private var saved: [DeviceRecord] = []
    private var deleted: [DeviceID] = []

    init(records: [DeviceRecord]) { self.records = records }

    func listDevices() async throws -> [DeviceRecord] { records }

    func save(_ device: DeviceRecord) async throws {
        saved.append(device)
        if let index = records.firstIndex(where: { $0.id == device.id }) { records[index] = device }
    }

    func delete(id: DeviceID) async throws {
        deleted.append(id)
        records.removeAll { $0.id == id }
    }

    func savedDevices() -> [DeviceRecord] { saved }
    func deletedIDs() -> [DeviceID] { deleted }
}
