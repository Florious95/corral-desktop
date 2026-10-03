import AppKit
import CorralContracts
@testable import CorralProtocol
import CorralServices
import CorralUI
import XCTest
@testable import CorralApp

@MainActor
final class Issue11ContextMenuActionsTests: XCTestCase {
    func testMenuWithoutLivePaneContextDoesNotExposeNoOpWorkspaceActions() throws {
        let view = CorralNativeTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 320, y: 200), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        let menu = try XCTUnwrap(view.menu(for: event) as? CorralTerminalContextMenu)
        XCTAssertFalse(menu.items.contains { ["收藏", "取消收藏", "关闭此分屏", "适应当前窗口"].contains($0.title) })
    }

    func testWindowCoordinateAtLeftPaneEdgeKeepsWorkspaceActions() async throws {
        let fixture = try await makeSplitFixture()
        defer {
            fixture.coordinator.windowController.window?.close()
            Task { await fixture.coordinator.stop() }
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        let terminal = try XCTUnwrap(fixture.coordinator.terminalView(for: fixture.references[0]))
        let splitView = fixture.coordinator.workspaceView.stageContainer.splitView
        let contentView = try XCTUnwrap(fixture.window.contentView)
        let leftPane = try XCTUnwrap(splitView.projection.panes.first { $0.sessionID == fixture.sessionIDs[0] })
        let pointInSplit = NSPoint(x: leftPane.frame.minX + 0.5, y: leftPane.frame.midY)
        let locationInWindow = contentView.convert(pointInSplit, from: splitView)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: locationInWindow, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 1
        ))
        XCTAssertEqual(event.locationInWindow, locationInWindow)
        XCTAssertEqual(event.windowNumber, fixture.window.windowNumber)
        let menu = try XCTUnwrap(terminal.menu(for: event) as? CorralTerminalContextMenu)
        XCTAssertFalse(menu.items.contains { ["收藏", "取消收藏"].contains($0.title) })
        XCTAssertTrue(menu.items.contains { $0.title == "关闭此分屏" })
        XCTAssertTrue(menu.items.contains { $0.title == "适应当前窗口" })
        await fixture.coordinator.stop()
    }

    func testBothSplitPaneMenusExposeActionsAndClosingLeftPaneRemovesIt() async throws {
        let fixture = try await makeSplitFixture()
        defer {
            fixture.coordinator.windowController.window?.close()
            Task { await fixture.coordinator.stop() }
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        let splitView = fixture.coordinator.workspaceView.stageContainer.splitView
        let leftView = try XCTUnwrap(fixture.coordinator.terminalView(for: fixture.references[0]))
        let rightView = try XCTUnwrap(fixture.coordinator.terminalView(for: fixture.references[1]))
        let leftMenu = try contextMenu(for: leftView, in: fixture.window)
        let rightMenu = try contextMenu(for: rightView, in: fixture.window)

        for menu in [leftMenu, rightMenu] {
            XCTAssertFalse(menu.items.contains { ["收藏", "取消收藏"].contains($0.title) })
            XCTAssertTrue(menu.items.contains { $0.title == "关闭此分屏" })
            XCTAssertTrue(menu.items.contains { $0.title == "适应当前窗口" })
        }
        for (terminal, positions) in [
            (leftView, [NSPoint(x: leftView.bounds.minX + 0.5, y: leftView.bounds.midY),
                        NSPoint(x: leftView.bounds.maxX - 0.5, y: leftView.bounds.midY),
                        NSPoint(x: leftView.bounds.midX, y: leftView.bounds.minY + 0.5)]),
            (rightView, [NSPoint(x: rightView.bounds.minX + 0.5, y: rightView.bounds.midY),
                         NSPoint(x: rightView.bounds.maxX - 0.5, y: rightView.bounds.midY),
                         NSPoint(x: rightView.bounds.midX, y: rightView.bounds.minY + 0.5)])
        ] {
            for position in positions {
                let edgeMenu = try contextMenu(for: terminal, in: fixture.window, at: position)
                XCTAssertTrue(edgeMenu.items.contains { $0.title == "关闭此分屏" }, "Workspace close must remain available at Pane edges")
                XCTAssertTrue(edgeMenu.items.contains { $0.title == "适应当前窗口" }, "Workspace fit must remain available at Pane edges")
            }
        }
        let leftID = fixture.sessionIDs[0]
        let rightID = fixture.sessionIDs[1]
        let rightFrame = try XCTUnwrap(splitView.projection.panes.first { $0.sessionID == rightID }).frame
        XCTAssertEqual(splitView.projection.panes.count, 2)

        let closeItem = try XCTUnwrap(leftMenu.items.first { $0.title == "关闭此分屏" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(closeItem.action), to: closeItem.target, from: closeItem))
        let paneRemoved = await waitUntil {
            fixture.coordinator.workspaceState.visibleRoot?.leafIDs == [rightID]
                && splitView.projection.panes.count == 1
        }
        XCTAssertTrue(paneRemoved, "The left Pane action must remove its session from the persisted split tree")
        let remainingFrame = splitView.projection.panes.first?.frame
        XCTAssertNotNil(remainingFrame)
        XCTAssertGreaterThan(remainingFrame?.width ?? 0, rightFrame.width + 20, "The remaining Pane must expand into the closed Pane's space")
        XCTAssertFalse(fixture.coordinator.workspaceState.visibleRoot?.leafIDs.contains(leftID) ?? true)
        await fixture.coordinator.stop()
    }

    func testIssue339AdaptCurrentWindowEmitsSameGridResizeControlFrame() async throws {
        let fixture = try await makeWireSplitFixture(viewportWidthAdjustment: -13)
        defer {
            fixture.window.orderOut(nil)
            fixture.window.close()
            Task { await fixture.coordinator.stop() }
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        let reference = fixture.references[1]
        let terminal = try XCTUnwrap(fixture.coordinator.terminalView(for: reference))
        let menu = try contextMenu(for: terminal, in: fixture.window)
        let adaptItem = try XCTUnwrap(menu.items.first { $0.title == "适应当前窗口" })
        let frameBefore = terminal.frame
        let gridBefore = GridSize(rows: terminal.terminal.rows, columns: terminal.terminal.cols)
        assertViewportIsBetweenColumnBoundaries(terminal, grid: gridBefore)
        let subscribeFrames = await fixture.socket.controlFrames(type: "subscribe", reference: reference.rawValue)
        let subscribedEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try XCTUnwrap(subscribeFrames.last).utf8)
        ) as? [String: Any])
        let subscribedPayload = try XCTUnwrap(subscribedEnvelope["payload"] as? [String: Any])
        XCTAssertEqual(subscribedPayload["rows"] as? Int, gridBefore.rows)
        XCTAssertEqual(subscribedPayload["cols"] as? Int, gridBefore.columns,
                       "The PTY subscription must already match the live viewport")
        try await Task.sleep(for: .milliseconds(150))
        let frameCountBefore = await fixture.socket.controlFrames(type: "resize", reference: reference.rawValue).count

        let layer = try resetRenderDirtyState(for: terminal)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(adaptItem.action), to: adaptItem.target, from: adaptItem))
        assertTerminalNeedsRedraw(terminal, layer: layer, file: #filePath, line: #line)
        let frameArrived = await waitUntil {
            await fixture.socket.controlFrames(type: "resize", reference: reference.rawValue).count > frameCountBefore
        }
        XCTAssertTrue(frameArrived, "Same-grid adaptation must reach the real SessionLink WebSocket sender")
        XCTAssertEqual(terminal.frame, frameBefore, "Fitting an already-sized terminal must not perturb its frame")
        XCTAssertEqual(GridSize(rows: terminal.terminal.rows, columns: terminal.terminal.cols), gridBefore)

        let frames = await fixture.socket.controlFrames(type: "resize", reference: reference.rawValue)
        let wireText = try XCTUnwrap(frames.last)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(wireText.utf8)) as? [String: Any])
        XCTAssertEqual(envelope["type"] as? String, "resize")
        let payload = try XCTUnwrap(envelope["payload"] as? [String: Any])
        XCTAssertEqual(payload["ref"] as? String, reference.rawValue)
        XCTAssertEqual(payload["rows"] as? Int, gridBefore.rows)
        XCTAssertEqual(payload["cols"] as? Int, gridBefore.columns)
        await fixture.coordinator.stop()
    }

    func testIssue339AdaptCurrentWindowCorrectsTerminalGridDriftToStableBounds() async throws {
        let fixture = try await makeWireSplitFixture()
        defer {
            fixture.window.orderOut(nil)
            fixture.window.close()
            Task { await fixture.coordinator.stop() }
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        let reference = fixture.references[1]
        let terminal = try XCTUnwrap(fixture.coordinator.terminalView(for: reference))
        let expectedGrid = GridSize(rows: terminal.terminal.rows, columns: terminal.terminal.cols)
        let frameBefore = terminal.frame
        XCTAssertGreaterThan(expectedGrid.rows, 3)
        XCTAssertGreaterThan(expectedGrid.columns, 7)
        let driftedGrid = GridSize(rows: expectedGrid.rows - 3, columns: expectedGrid.columns - 7)
        terminal.terminal.resize(cols: driftedGrid.columns, rows: driftedGrid.rows)
        XCTAssertEqual(GridSize(rows: terminal.terminal.rows, columns: terminal.terminal.cols), driftedGrid)
        let layer = try resetRenderDirtyState(for: terminal)

        let resizeCountBefore = await fixture.socket.controlFrames(type: "resize", reference: reference.rawValue).count
        let menu = try contextMenu(for: terminal, in: fixture.window)
        let adaptItem = try XCTUnwrap(menu.items.first { $0.title == "适应当前窗口" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(adaptItem.action), to: adaptItem.target, from: adaptItem))
        assertTerminalNeedsRedraw(terminal, layer: layer, file: #filePath, line: #line)
        let corrected = await waitUntil {
            guard GridSize(rows: terminal.terminal.rows, columns: terminal.terminal.cols) == expectedGrid else { return false }
            return await fixture.socket.controlFrames(type: "resize", reference: reference.rawValue).count > resizeCountBefore
        }
        XCTAssertTrue(corrected, "Adaptation must restore the terminal grid measured for its stable physical bounds")
        XCTAssertEqual(GridSize(rows: terminal.terminal.rows, columns: terminal.terminal.cols), expectedGrid)
        XCTAssertEqual(terminal.frame, frameBefore, "Grid correction must not perturb stable viewport bounds")

        let frames = await fixture.socket.controlFrames(type: "resize", reference: reference.rawValue)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(frames.last).utf8)) as? [String: Any])
        let payload = try XCTUnwrap(envelope["payload"] as? [String: Any])
        XCTAssertEqual(envelope["type"] as? String, "resize")
        XCTAssertEqual(payload["ref"] as? String, reference.rawValue)
        XCTAssertEqual(payload["rows"] as? Int, expectedGrid.rows)
        XCTAssertEqual(payload["cols"] as? Int, expectedGrid.columns)
        await fixture.coordinator.stop()
    }

    private func makeSplitFixture() async throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("corral-issue11-\(UUID().uuidString)", isDirectory: true)
        let workspaceStore = try CorralWorkspaceStore(applicationSupportDirectory: root)
        let preferencesStore = try UserPreferencesStore(applicationSupportDirectory: root)
        let deviceID = DeviceID("corral-native-development-endpoint")
        let references = [try SessionReference("issue11-left"), try SessionReference("issue11-right")]
        let sessionIDs = references.map { SessionID("\(deviceID.rawValue.utf8.count):\(deviceID.rawValue)\($0.rawValue)") }
        _ = try await workspaceStore.smartOpenSession(sessionIDs[0], gesture: .doubleClick)
        _ = try await workspaceStore.splitSession(sessionIDs[1], target: sessionIDs[0], edge: .right)
        let link = Issue11RecordingSessionLink()
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: Issue11EmptyDeviceRepository(),
            credentialVault: Issue11EmptyCredentialVault(),
            sessionLink: link,
            deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: link),
            workspaceStore: workspaceStore,
            userPreferencesStore: preferencesStore,
            initialWorkspaceState: await workspaceStore.snapshot(),
            initialUserPreferences: await preferencesStore.snapshot(),
            environment: [
                "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
                "CORRAL_NATIVE_TOKEN": "issue11-fixture-token",
                "CORRAL_NATIVE_BACKGROUND": "1",
                "CORRAL_NATIVE_TEST_MODE": "1"
            ]
        )
        let window = try XCTUnwrap(coordinator.windowController.window)
        placeWindowOffscreen(window)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        coordinator.workspaceView.stageContainer.layoutSubtreeIfNeeded()
        await coordinator.start()
        try await link.emit(.control(.listing(SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(workingDirectory: "/fixture/issue11", sessionCount: 2, aggregateState: .idle,
                            sessions: references.map { WireSessionRecord(reference: $0, name: $0.rawValue,
                                workingDirectory: "/fixture/issue11", state: .idle, rows: 24, columns: 80) })
        ]))))
        let panesReady = await waitUntil(timeout: .seconds(3)) {
            guard let split = coordinator.workspaceState.visibleRoot?.leafIDs,
                  let left = coordinator.terminalView(for: references[0]),
                  let right = coordinator.terminalView(for: references[1]) else { return false }
            coordinator.workspaceView.stageContainer.layoutSubtreeIfNeeded()
            return split.count == 2 && coordinator.subscribedSessionIDs.count == 2
                && !left.isHidden && !right.isHidden
                && coordinator.workspaceView.stageContainer.splitView.projection.panes.count == 2
        }
        guard panesReady else {
            await coordinator.stop()
            window.close()
            try? FileManager.default.removeItem(at: root)
            throw FixtureError.splitPanesDidNotLoad
        }
        return Fixture(coordinator: coordinator, link: link, references: references,
                       sessionIDs: sessionIDs, window: window, temporaryDirectory: root)
    }

    private func makeWireSplitFixture(viewportWidthAdjustment: CGFloat = 0) async throws -> WireFixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("corral-issue339-\(UUID().uuidString)", isDirectory: true)
        let workspaceStore = try CorralWorkspaceStore(applicationSupportDirectory: root)
        let preferencesStore = try UserPreferencesStore(applicationSupportDirectory: root)
        let deviceID = DeviceID("corral-native-development-endpoint")
        let references = [try SessionReference("issue339-left"), try SessionReference("issue339-right")]
        let sessionIDs = references.map { SessionID("\(deviceID.rawValue.utf8.count):\(deviceID.rawValue)\($0.rawValue)") }
        _ = try await workspaceStore.smartOpenSession(sessionIDs[0], gesture: .doubleClick)
        _ = try await workspaceStore.splitSession(sessionIDs[1], target: sessionIDs[0], edge: .right)

        let sessions: [[String: Any]] = references.map { reference in
            ["ref": reference.rawValue, "name": reference.rawValue, "cwd": "/fixture/issue339",
             "state": "idle", "rows": 24, "cols": 80]
        }
        let listing: [String: Any] = ["v": 1, "type": "listing", "payload": [
            "req_id": 1, "seq": 1,
            "workspaces": [["cwd": "/fixture/issue339", "session_count": 2,
                            "aggregate_state": "idle", "sessions": sessions]]
        ]]
        let listingMessage = String(decoding: try JSONSerialization.data(withJSONObject: listing), as: UTF8.self)
        let socket = Issue339WireSocket(listingMessage: listingMessage)
        var linkConfiguration = URLSessionSessionLink.Configuration()
        linkConfiguration.heartbeatIntervalNanoseconds = 60_000_000_000
        let link = URLSessionSessionLink(codec: ProtocolV1Codec(), configuration: linkConfiguration) { _ in socket }
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: Issue11EmptyDeviceRepository(),
            credentialVault: Issue11EmptyCredentialVault(),
            sessionLink: link,
            deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: link),
            workspaceStore: workspaceStore,
            userPreferencesStore: preferencesStore,
            initialWorkspaceState: await workspaceStore.snapshot(),
            initialUserPreferences: await preferencesStore.snapshot(),
            environment: [
                "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
                "CORRAL_NATIVE_TOKEN": "issue339-fixture-token",
                "CORRAL_NATIVE_BACKGROUND": "1",
                "CORRAL_NATIVE_TEST_MODE": "1"
            ]
        )
        let window = try XCTUnwrap(coordinator.windowController.window)
        if viewportWidthAdjustment != 0 {
            let contentSize = try XCTUnwrap(window.contentView).bounds.size
            window.setContentSize(NSSize(width: contentSize.width + viewportWidthAdjustment, height: contentSize.height))
        }
        placeWindowOffscreen(window)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        coordinator.workspaceView.stageContainer.layoutSubtreeIfNeeded()
        await coordinator.start()
        let panesReady = await waitUntil(timeout: .seconds(3)) {
            guard let split = coordinator.workspaceState.visibleRoot?.leafIDs,
                  let left = coordinator.terminalView(for: references[0]),
                  let right = coordinator.terminalView(for: references[1]) else { return false }
            coordinator.workspaceView.stageContainer.layoutSubtreeIfNeeded()
            return split.count == 2 && coordinator.subscribedSessionIDs.count == 2
                && !left.isHidden && !right.isHidden
                && coordinator.workspaceView.stageContainer.splitView.projection.panes.count == 2
        }
        guard panesReady else {
            await coordinator.stop()
            window.orderOut(nil)
            window.close()
            try? FileManager.default.removeItem(at: root)
            throw FixtureError.splitPanesDidNotLoad
        }
        return WireFixture(coordinator: coordinator, socket: socket, references: references,
                           window: window, temporaryDirectory: root)
    }

    private func resetRenderDirtyState(for terminal: CorralNativeTerminalView) throws -> CALayer {
        let layer = try XCTUnwrap(terminal.layer)
        layer.display()
        terminal.terminal.clearUpdateRange()
        XCTAssertNil(terminal.terminal.getUpdateRange())
        XCTAssertFalse(layer.needsDisplay())
        return layer
    }

    private func assertViewportIsBetweenColumnBoundaries(_ terminal: CorralNativeTerminalView, grid: GridSize) {
        let optimalSize = terminal.getOptimalFrameSize()
        let scrollerWidth = terminal.subviews.compactMap { $0 as? NSScroller }.first.map {
            $0.isHidden ? 0 : NSScroller.scrollerWidth(for: .regular, scrollerStyle: terminal.scrollerStyle)
        } ?? 0
        let cellWidth = (optimalSize.width - scrollerWidth) / CGFloat(grid.columns)
        XCTAssertGreaterThan(cellWidth, 0)
        guard cellWidth > 0 else { return }
        let remainder = terminal.frame.width.truncatingRemainder(dividingBy: cellWidth)
        let distanceToColumnBoundary = min(remainder, cellWidth - remainder)
        XCTAssertGreaterThan(distanceToColumnBoundary, 0.5,
                             "A non-integral pane width avoids incidental engine resizing during reflow")
    }

    private func assertTerminalNeedsRedraw(
        _ terminal: CorralNativeTerminalView,
        layer: CALayer,
        file: StaticString,
        line: UInt
    ) {
        let updateRange = terminal.terminal.getUpdateRange()
        XCTAssertNotNil(updateRange, "The terminal engine must report dirty rows", file: file, line: line)
        if let updateRange {
            XCTAssertGreaterThan(updateRange.endY, updateRange.startY, "The dirty range must be non-empty", file: file, line: line)
        }
        XCTAssertTrue(layer.needsDisplay(), "The layer-backed terminal must schedule a real redraw", file: file, line: line)
    }

    private func placeWindowOffscreen(_ window: NSWindow) {
        let origin = NSPoint(x: -10_000, y: -10_000)
        window.setFrameOrigin(origin)
        window.orderBack(nil)
        XCTAssertEqual(window.frame.origin, origin)
        XCTAssertFalse(NSScreen.screens.contains { !NSIntersectionRect($0.frame, window.frame).isEmpty })
    }

    private func contextMenu(for terminal: CorralNativeTerminalView, in window: NSWindow, at point: NSPoint? = nil) throws -> CorralTerminalContextMenu {
        let contentView = try XCTUnwrap(window.contentView)
        let terminalPoint = point ?? NSPoint(x: terminal.bounds.midX, y: terminal.bounds.midY)
        let locationInWindow = contentView.convert(terminalPoint, from: terminal)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: locationInWindow, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        XCTAssertEqual(event.locationInWindow, locationInWindow)
        XCTAssertEqual(event.windowNumber, window.windowNumber)
        let hit = contentView.hitTest(event.locationInWindow)
        XCTAssertTrue(hit === terminal || hit?.isDescendant(of: terminal) == true,
                      "The window-coordinate right click must hit its Pane terminal; location=\(event.locationInWindow), hit=\(String(describing: hit))")
        return try XCTUnwrap(terminal.menu(for: event) as? CorralTerminalContextMenu)
    }

    private func waitUntil(timeout: Duration = .seconds(2), condition: @escaping @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    private struct WireFixture {
        let coordinator: CorralApplicationCoordinator
        let socket: Issue339WireSocket
        let references: [SessionReference]
        let window: NSWindow
        let temporaryDirectory: URL
    }

    private struct Fixture {
        let coordinator: CorralApplicationCoordinator
        let link: Issue11RecordingSessionLink
        let references: [SessionReference]
        let sessionIDs: [SessionID]
        let window: NSWindow
        let temporaryDirectory: URL
    }

    private enum FixtureError: Error { case splitPanesDidNotLoad }
}

private actor Issue339WireSocket: WebSocketConnection {
    private let listingMessage: String
    private var incoming: [WebSocketMessage] = [.text(#"{"v":1,"type":"auth_ack","payload":{"ok":true}}"#)]
    private var receiver: CheckedContinuation<WebSocketMessage, Error>?
    private var sentTexts: [String] = []
    private var isClosed = false

    init(listingMessage: String) { self.listingMessage = listingMessage }

    func start() async throws {}

    func send(_ message: WebSocketMessage) async throws {
        guard case let .text(text) = message else { return }
        sentTexts.append(text)
        guard let envelope = Self.envelope(text),
              let type = envelope["type"] as? String else { return }
        let payload = envelope["payload"] as? [String: Any] ?? [:]
        if type == "list" {
            enqueue(.text(listingMessage))
        } else if type == "subscribe", let raw = payload["ref"] as? String,
                  let reference = try? SessionReference(raw),
                  let snapshot = try? ProtocolV1Codec().encodeBinaryFrame(.snapshot(reference: reference, ansi: Data())) {
            enqueue(.binary(snapshot))
        }
    }

    func receive() async throws -> WebSocketMessage {
        if !incoming.isEmpty { return incoming.removeFirst() }
        if isClosed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func ping() async throws {}

    func close() async {
        isClosed = true
        receiver?.resume(throwing: CancellationError())
        receiver = nil
    }

    func controlFrames(type: String, reference: String) -> [String] {
        sentTexts.filter { text in
            guard let envelope = Self.envelope(text),
                  envelope["type"] as? String == type,
                  let payload = envelope["payload"] as? [String: Any] else { return false }
            return payload["ref"] as? String == reference
        }
    }

    private func enqueue(_ message: WebSocketMessage) {
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: message)
        } else {
            incoming.append(message)
        }
    }

    private static func envelope(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private actor Issue11EmptyDeviceRepository: DeviceRepositoryProtocol {
    func listDevices() async throws -> [DeviceRecord] { [] }
    func save(_ device: DeviceRecord) async throws {}
    func delete(id: DeviceID) async throws {}
}

private actor Issue11EmptyCredentialVault: DeviceCredentialVault {
    func store(_ secret: String, for handle: CredentialHandle) async throws {}
    func resolve(_ handle: CredentialHandle) async throws -> String? { nil }
    func delete(_ handle: CredentialHandle) async throws {}
}

private actor Issue11RecordingSessionLink: SessionLinkProtocol {
    private let stream = Issue11EventStream()
    private var authenticated: AuthenticatedConnection?
    private var ordinal: UInt64 = 0
    private var sentCommands: [ClientCommand] = []

    func connect(to endpoint: ApprovedEndpoint, deviceID: DeviceID, credential: CredentialHandle) async throws -> AuthenticatedConnection {
        let connection = try AuthenticatedConnection(linkInstanceID: LinkInstanceID(), deviceID: deviceID,
                                                     connectionEpoch: ConnectionEpoch(1))
        authenticated = connection
        return connection
    }

    func eventStream() async throws -> any SessionEventStream { stream }

    func send(_ command: ClientCommand) async throws -> CommandSendReceipt {
        sentCommands.append(command)
        let requestID: UInt32? = switch command {
        case let .list(id): id
        case let .input(request): request.sequence
        case let .createAgent(request): request.requestID
        case let .closeSession(request): request.requestID
        default: nil
        }
        if case let .subscribe(reference, _) = command {
            try await emit(.frame(.snapshot(reference: reference, ansi: Data())))
        }
        return CommandSendReceipt(requestID: requestID, socketWritten: true)
    }

    func disconnect() async {
        authenticated = nil
        await stream.finish()
    }

    func emit(_ event: SessionEvent) async throws {
        guard let authenticated else { throw SessionLinkFailure.disconnected }
        ordinal += 1
        let origin = SessionEventOrigin(linkInstanceID: authenticated.linkInstanceID,
                                        deviceID: authenticated.deviceID,
                                        connectionEpoch: authenticated.connectionEpoch,
                                        receiveOrdinal: ReceiveOrdinal(ordinal))
        try await stream.yield(SessionEventEnvelope(origin: origin, wireByteCount: 0, event: event))
    }

    func resizeCommands(for reference: SessionReference) -> [GridSize] {
        sentCommands.compactMap {
            guard case let .resize(commandReference, size) = $0, commandReference == reference else { return nil }
            return size
        }
    }

    func subscribedGrid(for reference: SessionReference) -> GridSize? {
        var result: GridSize?
        for command in sentCommands {
            if case let .subscribe(commandReference, size) = command, commandReference == reference { result = size }
        }
        return result
    }
}

private actor Issue11EventStream: SessionEventStream {
    private var queued: [SessionEventEnvelope] = []
    private var waiter: CheckedContinuation<SessionEventEnvelope?, Never>?
    private var finished = false

    var budget: SessionEventStreamBudget {
        SessionEventStreamBudget(maximumBufferedBytes: 1_000_000, maximumBufferedEvents: 128, maximumBufferedControls: 32)
    }

    func next() async throws -> SessionEventEnvelope? {
        if !queued.isEmpty { return queued.removeFirst() }
        if finished { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }

    func yield(_ envelope: SessionEventEnvelope) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: envelope)
        } else {
            queued.append(envelope)
        }
    }

    func finish() {
        finished = true
        waiter?.resume(returning: nil)
        waiter = nil
    }
}
