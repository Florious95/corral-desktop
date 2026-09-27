import CorralContracts
import CorralServices
import Foundation
import XCTest

final class CorralWorkspaceStoreTests: XCTestCase {
    func testSmartOpenLocatesExistingPaneAcrossTabsAndReusesOnePreviewSlot() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try CorralWorkspaceStore(applicationSupportDirectory: support)
        let first = SessionID("device::one")
        let second = SessionID("device::two")
        let third = SessionID("device::three")

        let initial = try await store.smartOpenSession(first)
        let firstTabID = initial.activeTabID
        XCTAssertFalse(initial.tabs[0].pinned)
        let blankTabID = try await store.createTab()
        _ = try await store.smartOpenSession(first, gesture: .doubleClick)
        var state = await store.snapshot()
        XCTAssertEqual(state.activeTabID, firstTabID)
        XCTAssertEqual(state.tabs.count, 2)
        XCTAssertTrue(state.tabs.first(where: { $0.id == blankTabID })?.isBlank == true)
        XCTAssertNil(state.previewUID)

        _ = try await store.smartOpenSession(second)
        state = await store.snapshot()
        XCTAssertEqual(state.tabs.count, 2)
        XCTAssertEqual(state.previewUID, second)
        XCTAssertEqual(state.activeTab?.root, .session(first))
        XCTAssertEqual(state.visibleRoot, .session(second))
        _ = try await store.focusPane(second)
        state = await store.snapshot()
        XCTAssertEqual(state.activeTab?.root, .session(first), "preview focus must not pollute the durable Tab")
        XCTAssertEqual(state.previewUID, second)

        _ = try await store.smartOpenSession(third)
        state = await store.snapshot()
        XCTAssertEqual(state.tabs.count, 2, "single clicks replace the sole preview instead of adding Tabs")
        XCTAssertEqual(state.previewUID, third)
        XCTAssertEqual(state.activeTab?.root, .session(first))

        _ = try await store.smartOpenSession(third, gesture: .doubleClick)
        state = await store.snapshot()
        XCTAssertNil(state.previewUID)
        XCTAssertEqual(state.tabs.count, 3)
        XCTAssertEqual(state.activeTab?.root, .session(third))
        XCTAssertFalse(state.activeTab?.pinned == true)
        XCTAssertEqual(state.tabs.map(\.pinned), [false, false, false])
    }

    func testDiscardedPreviewBindingsAreRemovedWhenSwitchingOrClosingPreview() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try CorralWorkspaceStore(applicationSupportDirectory: support)
        let first = try makeSession(id: "first", ref: "first")
        let preview = try makeSession(id: "preview", ref: "preview")
        _ = try await store.smartOpenSession(first)
        let firstTab = await store.snapshot().activeTabID
        _ = try await store.createTab()
        _ = try await store.smartOpenSession(SessionID("second"))
        let secondTab = await store.snapshot().activeTabID
        _ = try await store.switchTab(firstTab)

        _ = try await store.smartOpenSession(preview)
        _ = try await store.closePane(preview.id)
        var state = await store.snapshot()
        XCTAssertNil(state.previewUID)
        XCTAssertFalse(state.sessionBindings.contains { $0.sessionID == preview.id })

        _ = try await store.smartOpenSession(preview)
        _ = try await store.smartOpenSession(first.id)
        state = await store.snapshot()
        XCTAssertEqual(state.activeTabID, firstTab)
        XCTAssertNil(state.previewUID)
        XCTAssertFalse(state.sessionBindings.contains { $0.sessionID == preview.id })

        _ = try await store.smartOpenSession(preview)
        _ = try await store.switchTab(secondTab)
        state = await store.snapshot()
        XCTAssertEqual(state.activeTabID, secondTab)
        XCTAssertNil(state.previewUID)
        XCTAssertFalse(state.sessionBindings.contains { $0.sessionID == preview.id })
    }

    func testTopologyMutationsPreserveExplicitPin() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try CorralWorkspaceStore(applicationSupportDirectory: support)
        let first = SessionID("first")
        let second = SessionID("second")
        _ = try await store.smartOpenSession(first)
        let tabID = await store.snapshot().activeTabID
        _ = try await store.pinTab(tabID)

        _ = try await store.splitSession(second, target: first, edge: .right)
        var state = await store.snapshot()
        XCTAssertTrue(state.activeTab?.pinned == true)
        _ = try await store.updateSplitRatio(path: "root", ratio: 0.4)
        state = await store.snapshot()
        XCTAssertTrue(state.activeTab?.pinned == true)
        _ = try await store.closePane(second)
        state = await store.snapshot()
        XCTAssertTrue(state.activeTab?.pinned == true)
    }

    func testBlankSlotFillStaysRegularUnlessBlankWasExplicitlyPinned() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try CorralWorkspaceStore(applicationSupportDirectory: support)
        let firstID = SessionID("device::first")
        let initial = await store.snapshot()
        XCTAssertTrue(initial.activeTab?.isImplicitBlank == true)

        _ = try await store.smartOpenSession(firstID)
        var state = await store.snapshot()
        XCTAssertEqual(state.activeTab?.root, .session(firstID))
        XCTAssertFalse(state.activeTab?.pinned == true)
        XCTAssertFalse(state.activeTab?.isImplicitBlank == true)
        XCTAssertNil(state.previewUID)

        let blankID = try await store.createTab()
        _ = try await store.pinTab(blankID)
        let secondID = SessionID("device::second")
        _ = try await store.smartOpenSession(secondID)
        state = await store.snapshot()
        XCTAssertEqual(state.activeTabID, blankID)
        XCTAssertEqual(state.activeTab?.root, .session(secondID))
        XCTAssertTrue(state.activeTab?.pinned == true)
    }

    func testFiveZoneDropsPersistTopologyWithoutPinningTheTab() async throws {
        for edge in [WorkspaceDropZone.left, .right, .top, .bottom, .center] {
            let support = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: support) }
            let store = try CorralWorkspaceStore(applicationSupportDirectory: support)
            let target = SessionID("target")
            let incoming = SessionID("incoming")
            _ = try await store.smartOpenSession(target)
            _ = try await store.splitSession(incoming, target: target, edge: edge)
            let tab = await store.snapshot().activeTab
            XCTAssertFalse(tab?.pinned == true, "\(edge) must preserve regular Tab state")
            switch edge {
            case .left, .right, .top, .bottom:
                guard case let .split(direction, _, first, second) = tab?.root else {
                    return XCTFail("\(edge) must create a split")
                }
                XCTAssertEqual(direction, edge == .left || edge == .right ? .horizontal : .vertical)
                XCTAssertEqual(first, edge == .left || edge == .top ? .session(incoming) : .session(target))
                XCTAssertEqual(second, edge == .left || edge == .top ? .session(target) : .session(incoming))
            case .center:
                XCTAssertEqual(tab?.root, .session(incoming))
            }
        }
    }

    func testDraggingExistingPaneAcrossTabsMovesItWithoutCreatingADuplicate() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try CorralWorkspaceStore(applicationSupportDirectory: support)
        let source = SessionID("source")
        let target = SessionID("target")
        _ = try await store.smartOpenSession(source)
        let sourceTabID = await store.snapshot().activeTabID
        _ = try await store.createTab()
        _ = try await store.smartOpenSession(target)
        let targetTabID = await store.snapshot().activeTabID

        _ = try await store.splitSession(source, target: target, edge: .left)
        var state = await store.snapshot()
        XCTAssertNil(state.tabs.first(where: { $0.id == sourceTabID })?.root)
        XCTAssertFalse(state.tabs.first(where: { $0.id == sourceTabID })?.pinned == true)
        XCTAssertFalse(state.tabs.first(where: { $0.id == targetTabID })?.pinned == true)
        XCTAssertEqual(state.tabs.first(where: { $0.id == targetTabID })?.sessionIDs, [source, target])
        XCTAssertEqual(state.tabs.flatMap(\.sessionIDs).filter { $0 == source }.count, 1)

        _ = try await store.smartOpenSession(source)
        state = await store.snapshot()
        XCTAssertEqual(state.activeTabID, targetTabID)
        XCTAssertEqual(state.tabs.count, 2)
    }

    func testPaneCloseCollapsesOnlyClientLayoutAndClosingLastTabRestoresBlank() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try CorralWorkspaceStore(applicationSupportDirectory: support)
        let first = SessionID("first")
        let second = SessionID("second")
        _ = try await store.smartOpenSession(first)
        _ = try await store.splitSession(second, target: first, edge: .right)
        let tabID = await store.snapshot().activeTabID

        _ = try await store.closePane(second)
        var state = await store.snapshot()
        XCTAssertEqual(state.activeTab?.root, .session(first))
        XCTAssertFalse(state.activeTab?.pinned == true)

        _ = try await store.closeTab(tabID)
        state = await store.snapshot()
        XCTAssertEqual(state.tabs.count, 1)
        XCTAssertTrue(state.activeTab?.isBlank == true)
        XCTAssertTrue(state.activeTab?.isImplicitBlank == true)
    }

    func testTabRenameAndReorderDoNotRenameAgentsOrCrossPinGroups() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try CorralWorkspaceStore(applicationSupportDirectory: support)
        let firstSession = SessionID("agent-A")
        _ = try await store.smartOpenSession(firstSession)
        let firstTab = await store.snapshot().activeTabID
        let secondTab = try await store.createTab()
        _ = try await store.smartOpenSession(SessionID("agent-B"))
        _ = try await store.pinTab(secondTab)
        let thirdTab = try await store.createTab()
        let fourthTab = try await store.createTab()

        _ = try await store.renameTab(firstTab, to: "Work notes")
        var state = await store.snapshot()
        XCTAssertEqual(state.tabs.first(where: { $0.id == firstTab })?.title, "Work notes")
        XCTAssertTrue(state.tabs.first(where: { $0.id == firstTab })?.isCustomTitle == true)
        XCTAssertEqual(state.tabs.first(where: { $0.id == firstTab })?.sessionIDs, [firstSession])

        _ = try await store.reorderTabs(from: 2, to: 3)
        state = await store.snapshot()
        XCTAssertEqual(state.tabs[2].id, fourthTab)
        XCTAssertEqual(state.tabs[3].id, thirdTab)
        let beforeCrossGroupMove = state.tabs
        _ = try await store.reorderTabs(from: 0, to: 2)
        let afterCrossGroupMove = await store.snapshot().tabs
        XCTAssertEqual(afterCrossGroupMove, beforeCrossGroupMove)
        XCTAssertEqual(state.tabs.first(where: { $0.id == secondTab })?.pinned, true)
    }

    func testFavoritesPreviewAndTabsRestoreAcrossLaunchAndUsePrivateAtomicFiles() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let workspace = try CorralWorkspaceStore(applicationSupportDirectory: support)
        let firstID = SessionID("first")
        let secondID = SessionID("second")
        let previewID = SessionID("preview")
        _ = try await workspace.smartOpenSession(firstID)
        let secondTabID = try await workspace.createTab()
        _ = try await workspace.smartOpenSession(secondID)
        _ = try await workspace.smartOpenSession(previewID)
        _ = try await workspace.toggleFavorite("device::cwd::preview")
        let expectedState = await workspace.snapshot()

        let preferences = try UserPreferencesStore(applicationSupportDirectory: support)
        _ = try await preferences.setTheme(.light)
        _ = try await preferences.setFontFamily("Menlo, monospace")
        _ = try await preferences.setFontSize(22)
        _ = try await preferences.setFollowDirectory(true)
        _ = try await preferences.setSidebarCollapsed(true)
        let expectedPreferences = await preferences.snapshot()
        XCTAssertEqual(expectedPreferences.theme, .light)
        XCTAssertEqual(expectedPreferences.fontSize, 22)

        let restoredWorkspace = try CorralWorkspaceStore(applicationSupportDirectory: support)
        let restoredState = await restoredWorkspace.snapshot()
        XCTAssertEqual(restoredState, expectedState)
        XCTAssertEqual(restoredState.activeTabID, secondTabID)
        XCTAssertEqual(restoredState.previewUID, previewID)
        XCTAssertEqual(restoredState.activeTab?.root, .session(secondID))
        let workspaceJSON = String(decoding: try Data(contentsOf: support.appendingPathComponent("com.corral.native.dev", isDirectory: true).appendingPathComponent(CorralWorkspaceStore.storageFilename)), as: UTF8.self)
        XCTAssertTrue(workspaceJSON.contains("activeTabId"))
        XCTAssertTrue(workspaceJSON.contains("previewUid"))
        let favoriteFirst = await restoredWorkspace.favoriteFirst(["other", "device::cwd::preview"])
        XCTAssertEqual(favoriteFirst, ["device::cwd::preview", "other"])

        let restoredPreferences = try UserPreferencesStore(applicationSupportDirectory: support)
        let actualPreferences = await restoredPreferences.snapshot()
        XCTAssertEqual(actualPreferences, expectedPreferences)

        let namespace = support.appendingPathComponent("com.corral.native.dev", isDirectory: true)
        for filename in [CorralWorkspaceStore.storageFilename, UserPreferencesStore.storageFilename] {
            let file = namespace.appendingPathComponent(filename)
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
        }
        let directoryMode = try FileManager.default.attributesOfItem(atPath: namespace.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700)
    }

    func testCloseRightTabsFallsBackWhenActiveTabWasClosed() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try CorralWorkspaceStore(applicationSupportDirectory: support)
        let firstTabID = await store.snapshot().activeTabID
        _ = try await store.createTab()
        _ = try await store.createTab()

        _ = try await store.closeRightTabs(of: firstTabID)
        let state = await store.snapshot()
        XCTAssertEqual(state.tabs.map(\.id), [firstTabID])
        XCTAssertEqual(state.activeTabID, firstTabID)
    }

    func testFontSizeRangeAndInvalidPreferenceFallback() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let namespace = support.appendingPathComponent("com.corral.native.dev", isDirectory: true)
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
        let invalidPreferences = "{\"theme\":\"sepia\",\"fontFamily\":\" \",\"fontSize\":1,\"followDirectory\":true,\"sidebarCollapsed\":true}"
        try Data(invalidPreferences.utf8).write(to: namespace.appendingPathComponent(UserPreferencesStore.storageFilename))
        let store = try UserPreferencesStore(applicationSupportDirectory: support)
        var preferences = await store.snapshot()
        XCTAssertEqual(preferences.theme, .system)
        XCTAssertEqual(preferences.fontFamily, UserPreferences.defaultFontFamily)
        XCTAssertEqual(preferences.fontSize, UserPreferences.minimumFontSize)
        XCTAssertTrue(preferences.followDirectory)
        XCTAssertTrue(preferences.sidebarCollapsed)

        _ = try await store.setFontSize(1)
        preferences = await store.snapshot()
        XCTAssertEqual(preferences.fontSize, UserPreferences.minimumFontSize)
        _ = try await store.setFontSize(100)
        preferences = await store.snapshot()
        XCTAssertEqual(preferences.fontSize, UserPreferences.maximumFontSize)
        _ = try await store.setTheme(.dark)
        preferences = await store.snapshot()
        XCTAssertEqual(preferences.theme, .dark)
    }

    func testPersistedStaleBlankFlagCannotOverwriteARealPane() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try CorralWorkspaceStore(applicationSupportDirectory: support)
        let sessionID = SessionID("device::alive")
        _ = try await store.smartOpenSession(sessionID)
        let file = support.appendingPathComponent("com.corral.native.dev", isDirectory: true)
            .appendingPathComponent(CorralWorkspaceStore.storageFilename)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var tabs = try XCTUnwrap(object["tabs"] as? [[String: Any]])
        tabs[0]["isBlank"] = true
        object["tabs"] = tabs
        try JSONSerialization.data(withJSONObject: object).write(to: file)

        let restored = try CorralWorkspaceStore(applicationSupportDirectory: support)
        let state = await restored.snapshot()
        XCTAssertEqual(state.activeTab?.root, .session(sessionID))
        XCTAssertFalse(state.activeTab?.isBlank == true)
    }

    func testListingUIDDriftRebindsTheSavedPaneAndMissingListingNeverBlanksIt() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try CorralWorkspaceStore(applicationSupportDirectory: support)
        let old = try makeSession(id: "device::old-ref", ref: "old-ref")
        let new = try makeSession(id: "device::new-ref", ref: "new-ref")
        let companionID = SessionID("device::companion")
        _ = try await store.smartOpenSession(old)
        _ = try await store.splitSession(companionID, target: old.id, edge: .bottom)
        _ = try await store.focusPane(old.id)
        _ = try await store.updateSplitRatio(path: "root", ratio: 0.37)

        _ = try await store.reconcileListing([new])
        let state = await store.snapshot()
        XCTAssertEqual(state.activeTab?.sessionIDs, [new.id, companionID])
        XCTAssertEqual(state.activeTab?.activeSessionID, new.id)
        XCTAssertFalse(state.tabs[0].pinned)
        guard case let .split(_, ratio, _, _) = state.activeTab?.root else {
            return XCTFail("Drift must retain the pane tree")
        }
        XCTAssertEqual(ratio, 0.37)

        _ = try await store.reconcileListing([])
        let afterEmptyListing = await store.snapshot()
        XCTAssertEqual(afterEmptyListing.activeTab?.sessionIDs, [new.id, companionID])
        XCTAssertFalse(afterEmptyListing.activeTab?.isBlank == true)
        _ = try await store.removeClosedSession(new.id)
        let afterExplicitClose = await store.snapshot()
        XCTAssertEqual(afterExplicitClose.activeTab?.sessionIDs, [companionID])
    }

    private func makeSession(id: String, ref: String) throws -> SessionDescriptor {
        let deviceID = DeviceID("device")
        return SessionDescriptor(
            id: SessionID(id),
            key: SessionKey(deviceID: deviceID, reference: try SessionReference(ref)),
            name: "worker",
            workingDirectory: "/workspace/project",
            state: .running,
            size: GridSize(rows: 24, columns: 80)
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
