import AppKit
import CorralContracts
import CorralProtocol
import CorralServices
import CorralUI
import Foundation
import XCTest
@testable import CorralApp

@MainActor
final class Issue335TrueTabDragFromScratchTests: XCTestCase {
    func testRealWindowAppKitTabDragStaysStationaryAndPersistsDropOrder() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-issue335-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceDirectory = root.appendingPathComponent("workspace", isDirectory: true)
        let workspaceStore = try CorralWorkspaceStore(applicationSupportDirectory: workspaceDirectory)
        let preferencesStore = try UserPreferencesStore(applicationSupportDirectory: root.appendingPathComponent("preferences"))
        let initial = await workspaceStore.snapshot()
        let tabAID = initial.activeTabID
        let tabBID = try await workspaceStore.createTab()
        let tabCID = try await workspaceStore.createTab()
        _ = try await workspaceStore.renameTab(tabAID, to: "Tab A")
        _ = try await workspaceStore.renameTab(tabBID, to: "Tab B")
        _ = try await workspaceStore.renameTab(tabCID, to: "Tab C")

        let link = Issue335NoopSessionLink()
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: Issue335EmptyDeviceRepository(),
            credentialVault: Issue335EmptyCredentialVault(),
            sessionLink: link,
            deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: link),
            workspaceStore: workspaceStore,
            userPreferencesStore: preferencesStore,
            initialWorkspaceState: await workspaceStore.snapshot(),
            initialUserPreferences: await preferencesStore.snapshot(),
            environment: ["CORRAL_NATIVE_BACKGROUND": "1"]
        )
        let window = try XCTUnwrap(coordinator.windowController.window)
        defer { window.close() }
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        coordinator.workspaceView.layoutSubtreeIfNeeded()
        let bar = coordinator.workspaceView.tabBar
        bar.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let initialFrame = window.frame
        XCTAssertTrue(window.isVisible, "The fixture must use a real ordered NSWindow positioned offscreen")
        XCTAssertFalse(window.isKeyWindow, "The test must not activate or take keyboard focus")
        let source = try tabItem("Tab A", in: bar)
        let middle = try tabItem("Tab B", in: bar)
        let destination = try tabItem("Tab C", in: bar)
        XCTAssertTrue(source.window === window)
        XCTAssertNotNil(source.layer, "The window-backed TabItem must participate in AppKit rendering")

        XCTAssertFalse(source.mouseDownCanMoveWindow,
                       "A TabItem press must not be interpreted as a window-background drag")
        XCTAssertFalse(bar.mouseDownCanMoveWindow,
                       "A TabBar press must not be interpreted as a window-background drag")

        let sourcePoint = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
        let hit = try XCTUnwrap(window.contentView?.hitTest(sourcePoint))
        XCTAssertTrue(hit === source || hit.isDescendant(of: source),
                      "The real window hit-test must route the press into Tab A")
        let initialOrder = [tabAID, tabBID, tabCID]
        var reorderCallbacks = 0
        let coordinatorReorder = bar.onReorderTabs
        bar.onReorderTabs = { id, index in
            reorderCallbacks += 1
            coordinatorReorder?(id, index)
        }

        let started = ProcessInfo.processInfo.systemUptime
        window.sendEvent(try mouseEvent(.leftMouseDown, point: sourcePoint, timestamp: started, in: window))
        let draggedPoint = source.convert(NSPoint(x: source.bounds.midX + 10, y: source.bounds.midY), to: nil)
        // Keep this physical-source surrogate below the 180ms native drag threshold: starting an
        // NSDraggingSession requires OS pointer tracking, which a background test must not synthesize.
        window.sendEvent(try mouseEvent(.leftMouseDragged, point: draggedPoint, timestamp: started + 0.10, in: window))
        window.sendEvent(try mouseEvent(.leftMouseUp, point: draggedPoint, timestamp: started + 0.11, in: window))
        XCTAssertEqual(window.frame, initialFrame, "A real-window AppKit pointer sequence must not move the NSWindow")
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertEqual(bar.tabs.map(\.id), initialOrder,
                       "The model must remain unchanged during the transient drag preview")

        let dropPoint = middle.convert(NSPoint(x: middle.bounds.maxX - 1, y: middle.bounds.midY), to: nil)
        let dragInfo = Issue335WindowDraggingInfo(window: window, point: dropPoint, tabID: tabAID)
        XCTAssertEqual(bar.draggingUpdated(dragInfo), .move,
                       "The attached TabBar must accept the in-window drop across Tab B")
        XCTAssertLessThan(source.alphaValue, 0.75,
                          "The real window-backed AppKit preview must render the grabbed TabItem as translucent")
        let previewCenters = [middle, source, destination].map {
            $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: bar).x
        }
        XCTAssertTrue(previewCenters[0] < previewCenters[1] && previewCenters[1] < previewCenters[2],
                      "The destination preview must make room between Tab B and Tab C")
        XCTAssertEqual(bar.tabs.map(\.id), initialOrder,
                       "The coordinator/store order must not change until drop completion")

        XCTAssertTrue(bar.performDragOperation(dragInfo), "The TabBar drop callback must accept the insertion")
        let didPersistOrder = await waitForStoreOrder(workspaceStore, expected: [tabBID, tabAID, tabCID])
        XCTAssertTrue(didPersistOrder, "The coordinator must persist the dropped order to WorkspaceStore")
        XCTAssertEqual(reorderCallbacks, 1, "The coordinator-facing reorder callback runs once at drop")
        XCTAssertEqual(coordinator.workspaceState.tabs.map(\.id), [tabBID, tabAID, tabCID])
        XCTAssertEqual(bar.tabs.map(\.id), [tabBID, tabAID, tabCID])
        let reopenedStore = try CorralWorkspaceStore(applicationSupportDirectory: workspaceDirectory)
        let reopenedOrder = await reopenedStore.snapshot().tabs.map(\.id)
        XCTAssertEqual(reopenedOrder, [tabBID, tabAID, tabCID],
                       "A new store instance must read the persisted drop order")

        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertEqual(window.frame, initialFrame, "AppKit rendering and the completed drop must leave the window stationary")
        XCTAssertFalse(window.isKeyWindow)
    }

    private func tabItem(_ title: String, in bar: NSView, file: StaticString = #filePath, line: UInt = #line) throws -> NSView {
        try XCTUnwrap(descendants(of: bar).first {
            $0.accessibilityIdentifier() == "corral.tab" && $0.accessibilityLabel() == title
        }, "Missing TabItem \(title)", file: file, line: line)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func mouseEvent(_ type: NSEvent.EventType, point: NSPoint, timestamp: TimeInterval, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: timestamp,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                         clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    private func waitForStoreOrder(_ store: CorralWorkspaceStore, expected: [UUID]) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if await store.snapshot().tabs.map(\.id) == expected { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await store.snapshot().tabs.map(\.id) == expected
    }
}

@MainActor
private final class Issue335WindowDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("corral-335-window-drag-\(UUID().uuidString)"))
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint

    init(window: NSWindow, point: NSPoint, tabID: UUID) {
        draggingDestinationWindow = window
        draggingLocation = point
        super.init()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(tabID.uuidString, forType: .string)
    }

    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

private actor Issue335EmptyDeviceRepository: DeviceRepositoryProtocol {
    func listDevices() async throws -> [DeviceRecord] { [] }
    func save(_ device: DeviceRecord) async throws {}
    func delete(id: DeviceID) async throws {}
}

private actor Issue335EmptyCredentialVault: DeviceCredentialVault {
    func store(_ secret: String, for handle: CredentialHandle) async throws {}
    func resolve(_ handle: CredentialHandle) async throws -> String? { nil }
    func delete(_ handle: CredentialHandle) async throws {}
}

private actor Issue335NoopSessionLink: SessionLinkProtocol {
    private let stream = Issue335EmptyEventStream()

    func connect(to endpoint: ApprovedEndpoint, deviceID: DeviceID, credential: CredentialHandle) async throws -> AuthenticatedConnection {
        try AuthenticatedConnection(linkInstanceID: LinkInstanceID(), deviceID: deviceID, connectionEpoch: ConnectionEpoch(1))
    }

    func eventStream() async throws -> any SessionEventStream { stream }
    func send(_ command: ClientCommand) async throws -> CommandSendReceipt { CommandSendReceipt(requestID: nil, socketWritten: true) }
    func disconnect() async {}
}

private actor Issue335EmptyEventStream: SessionEventStream {
    var budget: SessionEventStreamBudget {
        SessionEventStreamBudget(maximumBufferedBytes: 1_000_000, maximumBufferedEvents: 128, maximumBufferedControls: 32)
    }
    func next() async throws -> SessionEventEnvelope? { nil }
}
