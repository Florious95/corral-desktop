import AppKit
import CorralContracts
import CorralProtocol
import CorralServices
import CorralUI
import Foundation
import XCTest
@testable import CorralApp
@testable import SwiftTerm

/// A phone and the desktop share one PTY. While Core reports a phone, the desktop keeps the phone's
/// grid exactly, hangs it from the pane's bottom-left corner and clips what does not fit, instead of
/// resizing the PTY or reflowing the remote layout into its own pane.
@MainActor
final class MobileSharedGridAnchorTests: XCTestCase {
    func testPhoneOwnedGridStaysBottomLeftAnchoredClippedAndInteractiveUntilThePhoneLeaves() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("corral-anchor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CorralWorkspaceStore(applicationSupportDirectory: root)
        let preferences = try UserPreferencesStore(applicationSupportDirectory: root)
        let deviceID = DeviceID("corral-native-development-endpoint")
        let reference = try SessionReference("anchor-session")
        let sessionID = SessionID("\(deviceID.rawValue.utf8.count):\(deviceID.rawValue)\(reference.rawValue)")
        _ = try await store.smartOpenSession(sessionID, gesture: .doubleClick)
        let link = AnchorRecordingSessionLink()
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: AnchorEmptyDeviceRepository(), credentialVault: AnchorEmptyCredentialVault(),
            sessionLink: link, deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: link),
            workspaceStore: store, userPreferencesStore: preferences,
            initialWorkspaceState: await store.snapshot(), initialUserPreferences: await preferences.snapshot(),
            environment: ["CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
                          "CORRAL_NATIVE_TOKEN": "anchor-test-only", "CORRAL_NATIVE_BACKGROUND": "1"]
        )
        let window = try XCTUnwrap(coordinator.windowController.window)
        defer { window.close() }
        window.setFrame(NSRect(x: 0, y: 0, width: 1_200, height: 800), display: true, animate: false)
        window.orderBack(nil)
        await coordinator.start()
        let phone = GridSize(rows: 44, columns: 46)
        func record(_ grid: GridSize) -> WireSessionRecord {
            WireSessionRecord(reference: reference, name: "pi", workingDirectory: "/fixture/anchor", state: .idle,
                              rows: UInt16(grid.rows), columns: UInt16(grid.columns))
        }
        try await link.emit(.control(.listing(SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(workingDirectory: "/fixture/anchor", sessionCount: 1, aggregateState: .idle, sessions: [record(GridSize(rows: 24, columns: 80))])
        ]))))
        let subscribed = await waitUntil { coordinator.subscribedSessionIDs.contains(reference.rawValue) }
        XCTAssertTrue(subscribed)
        let view = try XCTUnwrap(coordinator.terminalView(for: reference))
        let stage = try XCTUnwrap(view.superview)
        let advertised = GridSize(rows: 24, columns: 80)
        let opened = await link.commands()
        XCTAssertTrue(opened.contains(.subscribe(reference: reference, size: advertised)), "unknown presence keeps the server-advertised grid for the first subscribe")
        let localGridReady = await waitUntil { GridSize(rows: view.terminal.rows, columns: view.terminal.cols) != advertised }
        XCTAssertTrue(localGridReady, "the local terminal must measure its pane before desktop ownership is announced")
        try await link.emit(.control(.presenceUpdate(reference: reference, hasMobile: false, mobileCount: 0, desktopCount: 1)))
        let desktopReady = await waitUntil {
            let current = GridSize(rows: view.terminal.rows, columns: view.terminal.cols)
            let commands = await link.commands()
            return current != advertised && commands.contains {
                if case let .resize(resizedReference, size) = $0 { return resizedReference == reference && size == current }
                return false
            }
        }
        XCTAssertTrue(desktopReady, "desktop takeover requires an explicit presence=false event")
        let desktop = GridSize(rows: view.terminal.rows, columns: view.terminal.cols)
        let resizeCountBeforePhone = await link.commands().filter { if case .resize = $0 { true } else { false } }.count
        try await link.emit(.control(.listDelta(SessionListDelta(sequence: 2, changedSessions: [record(desktop)]))))

        // The phone attaches: Core reports it, then the next catalog scan reports its grid.
        try await link.emit(.control(.presenceUpdate(reference: reference, hasMobile: true, mobileCount: 1, desktopCount: 1)))
        try await link.emit(.control(.listDelta(SessionListDelta(sequence: 3, changedSessions: [record(phone)]))))
        let following = await waitUntil { view.pinnedGrid == phone }
        XCTAssertTrue(following)

        func assertAnchored(_ label: String) throws -> CGRect {
            stage.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.pinnedGrid, phone, label)
            XCTAssertEqual(GridSize(rows: view.terminal.rows, columns: view.terminal.cols), phone, "\(label): the remote grid is kept locally")
            let pane = try XCTUnwrap(coordinator.workspaceView.stageContainer.splitView.projection.panes.first).frame
            let paneInStage = stage.convert(pane, from: coordinator.workspaceView.stageContainer.splitView)
            XCTAssertEqual(view.frame.minX, paneInStage.minX, accuracy: 0.5, "\(label): left edge")
            XCTAssertEqual(view.frame.maxY, paneInStage.maxY, accuracy: 0.5, "\(label): bottom edge (flipped stage)")
            return paneInStage
        }
        let wide = try assertAnchored("wide window")
        XCTAssertTrue(wide.contains(view.frame), "a phone grid smaller than the pane is not clipped")

        window.setFrame(NSRect(x: 0, y: 0, width: 900, height: 420), display: true, animate: false)
        let short = try assertAnchored("short window")
        XCTAssertGreaterThan(view.frame.height, short.height, "the phone grid is taller than the pane")
        let aboveThePane = CGPoint(x: short.minX + 10, y: short.minY - 10)
        XCTAssertTrue(view.frame.contains(aboveThePane))
        XCTAssertFalse(view.hitTest(aboveThePane) === view, "the clipped overflow above the pane is neither shown nor hit")
        XCTAssertTrue(view.hitTest(CGPoint(x: short.minX + 10, y: short.maxY - 10)) === view, "the bottom-left input rows stay hittable")
        XCTAssertNotNil(view.layer?.mask)

        try await link.emit(.control(.listDelta(SessionListDelta(sequence: 4, changedSessions: [record(GridSize(rows: 24, columns: 80))]))))
        let rotated = await waitUntil { view.terminal.cols == 80 && view.terminal.rows == 24 }
        XCTAssertTrue(rotated, "a phone resize reaches the desktop as a catalog grid and is kept locally")

        _ = window.makeFirstResponder(view)
        window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, characters: "x",
                                          charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)!)
        let typed = await waitUntil {
            await link.commands().contains { if case let .input(request) = $0, request.payload == .bytes(Data("x".utf8)) { true } else { false } }
        }
        XCTAssertTrue(typed, "the anchored terminal stays interactive")
        let resizesWhilePhonePresent = await link.commands().filter { if case .resize = $0 { true } else { false } }
        XCTAssertEqual(resizesWhilePhonePresent.count, resizeCountBeforePhone, "window and catalog changes never resize a phone-owned PTY")

        // Mobile ownership is a lease, not a momentary presence flag. A phone
        // can sleep, background, or lose its transport briefly; none of those
        // events may let the desktop reclaim the PTY grid behind its back.
        try await link.emit(.control(.presenceUpdate(reference: reference, hasMobile: false, mobileCount: 0, desktopCount: 1)))
        let leaseStillPinned = await waitUntil {
            view.pinnedGrid == phone
                && GridSize(rows: view.terminal.rows, columns: view.terminal.cols) == phone
        }
        XCTAssertTrue(leaseStillPinned, "has_mobile=false must preserve a previously acquired mobile grid lease")
        guard leaseStillPinned else {
            await coordinator.stop()
            return
        }
        let resizeCountAtLease = await link.commands().filter { if case .resize = $0 { true } else { false } }.count
        window.setFrame(NSRect(x: 0, y: 0, width: 1_400, height: 1_000), display: true, animate: false)
        window.displayIfNeeded()
        coordinator.workspaceView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let resizesAfterPresenceJitter = await link.commands().filter { if case .resize = $0 { true } else { false } }.count
        XCTAssertEqual(resizesAfterPresenceJitter, resizeCountAtLease,
                       "window reflow after a transient mobile presence loss must not resize the leased PTY")

        // Only the explicit terminal context-menu action may end the lease.
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 7,
            clickCount: 1, pressure: 1
        ))
        let menu = try XCTUnwrap(view.menu(for: event) as? CorralTerminalContextMenu)
        let adaptItem = try XCTUnwrap(menu.items.first { $0.title == "适应当前窗口" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(adaptItem.action), to: adaptItem.target, from: adaptItem))
        let explicitTakeover = await waitUntil {
            let current = GridSize(rows: view.terminal.rows, columns: view.terminal.cols)
            let commands = await link.commands()
            return view.pinnedGrid == nil && current != phone
                && commands.contains(.resize(reference: reference, size: current))
        }
        XCTAssertTrue(explicitTakeover, "only explicit Adapt to Current Window may release the mobile grid lease")
        await coordinator.stop()
    }

    /// The catalog trails the PTY by up to one scan. When a phone arrives before the catalog has even
    /// reported this desktop's grid, it still shows an older one; adopting it in between pops the phone's
    /// footer rows below the cursor. The desktop keeps its grid until the catalog reports the phone's.
    func testPhoneArrivalKeepsTheDesktopGridUntilTheCatalogReportsThePhone() async throws {
        try await assertPhoneCatalogOrdering(catalogFirst: false)
    }

    func testPhoneCatalogBeforePresenceDoesNotRequireAnEchoOfTheDesktopRequest() async throws {
        try await assertPhoneCatalogOrdering(catalogFirst: true)
    }

    private func assertPhoneCatalogOrdering(catalogFirst: Bool) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("corral-anchor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CorralWorkspaceStore(applicationSupportDirectory: root)
        let preferences = try UserPreferencesStore(applicationSupportDirectory: root)
        let deviceID = DeviceID("corral-native-development-endpoint")
        let reference = try SessionReference("anchor-catalog-lag")
        _ = try await store.smartOpenSession(SessionID("\(deviceID.rawValue.utf8.count):\(deviceID.rawValue)\(reference.rawValue)"), gesture: .doubleClick)
        let link = AnchorRecordingSessionLink()
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: AnchorEmptyDeviceRepository(), credentialVault: AnchorEmptyCredentialVault(),
            sessionLink: link, deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: link),
            workspaceStore: store, userPreferencesStore: preferences,
            initialWorkspaceState: await store.snapshot(), initialUserPreferences: await preferences.snapshot(),
            environment: ["CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
                          "CORRAL_NATIVE_TOKEN": "anchor-test-only", "CORRAL_NATIVE_BACKGROUND": "1"]
        )
        let window = try XCTUnwrap(coordinator.windowController.window)
        defer { window.close() }
        window.setFrame(NSRect(x: 0, y: 0, width: 1_400, height: 1_000), display: true, animate: false)
        window.orderBack(nil)
        await coordinator.start()
        let stale = GridSize(rows: 32, columns: 110), phone = GridSize(rows: 44, columns: 46)
        func record(_ grid: GridSize) -> WireSessionRecord {
            WireSessionRecord(reference: reference, name: "pi", workingDirectory: "/fixture/anchor", state: .idle,
                              rows: UInt16(grid.rows), columns: UInt16(grid.columns))
        }
        try await link.emit(.control(.listing(SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(workingDirectory: "/fixture/anchor", sessionCount: 1, aggregateState: .idle, sessions: [record(stale)])
        ]))))
        _ = await waitUntil { coordinator.subscribedSessionIDs.contains(reference.rawValue) }
        let view = try XCTUnwrap(coordinator.terminalView(for: reference))
        let advertised = stale
        let opened = await link.commands()
        XCTAssertTrue(opened.contains(.subscribe(reference: reference, size: advertised)), "unknown presence keeps the server-advertised grid for the first subscribe")
        let localGridReady = await waitUntil { GridSize(rows: view.terminal.rows, columns: view.terminal.cols) != advertised }
        XCTAssertTrue(localGridReady, "the local terminal must measure its pane before desktop ownership is announced")
        try await link.emit(.control(.presenceUpdate(reference: reference, hasMobile: false, mobileCount: 0, desktopCount: 1)))
        let desktopReady = await waitUntil {
            let current = GridSize(rows: view.terminal.rows, columns: view.terminal.cols)
            let commands = await link.commands()
            return current != advertised && commands.contains {
                if case let .resize(resizedReference, size) = $0 { return resizedReference == reference && size == current }
                return false
            }
        }
        XCTAssertTrue(desktopReady, "desktop takeover requires an explicit presence=false event")
        let desktop = GridSize(rows: view.terminal.rows, columns: view.terminal.cols)
        XCTAssertGreaterThanOrEqual(desktop.rows, phone.rows)
        let resizeCountBeforePhone = await link.commands().filter { if case .resize = $0 { true } else { false } }.count

        // The phone attaches: its 46x44 redraw reaches the desktop before presence, and the catalog still lags.
        let redraw = (1...44).map { "\u{1b}[\($0);1H\u{1b}[2K\($0 > 41 ? "FOOTER-\($0)" : "ROW-\($0)")" }.joined() + "\u{1b}[41;1H"
        try await link.emit(.frame(.delta(reference: reference, ansi: Data(redraw.utf8))))
        if catalogFirst {
            try await link.emit(.control(.listDelta(SessionListDelta(sequence: 2, changedSessions: [record(phone)]))))
        }
        try await link.emit(.control(.presenceUpdate(reference: reference, hasMobile: true, mobileCount: 1, desktopCount: 1)))
        _ = await waitUntil { view.pinnedGrid != nil }
        view.superview?.layoutSubtreeIfNeeded()
        if !catalogFirst {
            XCTAssertEqual(GridSize(rows: view.terminal.rows, columns: view.terminal.cols), desktop,
                           "a lagging catalog grid must not be adopted as the phone's")
            try await link.emit(.control(.listDelta(SessionListDelta(sequence: 2, changedSessions: [record(phone)]))))
        }
        let adopted = await waitUntil { view.terminal.rows == phone.rows && view.terminal.cols == phone.columns }
        XCTAssertTrue(adopted)
        let bottom = (41..<44).map { view.getTerminal().getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
        XCTAssertEqual(bottom, ["FOOTER-42", "FOOTER-43", "FOOTER-44"], "the phone's footer stays on the desktop's bottom rows")
        let resizes = await link.commands().filter { if case .resize = $0 { true } else { false } }
        XCTAssertEqual(resizes.count, resizeCountBeforePhone, "a phone-owned PTY is never resized by the desktop")

        // Negative control: the same screen taken through the stale grid first loses the footer.
        let control = CorralNativeTerminalView(frame: .zero, pasteboard: NSPasteboard(name: NSPasteboard.Name(UUID().uuidString)))
        control.getTerminal().resize(cols: desktop.columns, rows: desktop.rows)
        control.feed(text: redraw)
        control.getTerminal().resize(cols: stale.columns, rows: stale.rows)
        control.getTerminal().resize(cols: phone.columns, rows: phone.rows)
        XCTAssertNotEqual((41..<44).map { control.getTerminal().getLine(row: $0)?.translateToString(trimRight: true) ?? "" }, bottom)
        await coordinator.stop()
    }

    private func waitUntil(timeout: Duration = .seconds(8), _ predicate: @MainActor () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await predicate()
    }
}

/// Answers a subscribe with its snapshot only; presence is the test's to send.
private actor AnchorRecordingSessionLink: SessionLinkProtocol {
    private let stream = AnchorEventStream()
    private var authenticated: AuthenticatedConnection?
    private var ordinal: UInt64 = 0
    private var sent: [ClientCommand] = []
    private var latestSnapshots: [String: Data] = [:]

    func connect(to endpoint: ApprovedEndpoint, deviceID: DeviceID, credential: CredentialHandle) async throws -> AuthenticatedConnection {
        let connection = try AuthenticatedConnection(linkInstanceID: LinkInstanceID(), deviceID: deviceID, connectionEpoch: ConnectionEpoch(1))
        authenticated = connection
        return connection
    }

    func eventStream() async throws -> any SessionEventStream { stream }

    func send(_ command: ClientCommand) async throws -> CommandSendReceipt {
        sent.append(command)
        if case let .subscribe(reference, size) = command {
            let ansi = latestSnapshots[reference.rawValue] ?? anchorSnapshot(for: size)
            try await emit(.frame(.snapshot(reference: reference, ansi: ansi)))
        }
        let requestID: UInt32? = switch command {
        case let .list(id): id
        case let .input(request): request.sequence
        default: nil
        }
        return CommandSendReceipt(requestID: requestID, socketWritten: true)
    }

    func disconnect() async {
        authenticated = nil
        await stream.finish()
    }

    func emit(_ event: SessionEvent) async throws {
        guard let authenticated else { throw SessionLinkFailure.disconnected }
        if case let .frame(frame) = event {
            switch frame {
            case let .snapshot(reference, ansi), let .delta(reference, ansi):
                latestSnapshots[reference.rawValue] = ansi
            case .scrollback:
                break
            }
        }
        ordinal += 1
        let origin = SessionEventOrigin(linkInstanceID: authenticated.linkInstanceID, deviceID: authenticated.deviceID,
                                        connectionEpoch: authenticated.connectionEpoch, receiveOrdinal: ReceiveOrdinal(ordinal))
        try await stream.yield(SessionEventEnvelope(origin: origin, wireByteCount: 0, event: event))
    }

    func commands() -> [ClientCommand] { sent }
}

private func anchorSnapshot(for size: GridSize) -> Data {
    let rows = max(1, size.rows)
    let columns = max(1, size.columns)
    let footerStart = max(1, rows - 2)
    let body = (1...rows).map { row in
        let label = row >= footerStart ? "FOOTER-\(row)" : "ROW-\(row)"
        return "\u{1b}[\(row);1H\u{1b}[2K\(String(label.prefix(columns)))"
    }.joined()
    return Data((body + "\u{1b}[\(footerStart);1H").utf8)
}

private actor AnchorEventStream: SessionEventStream {
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

private actor AnchorEmptyDeviceRepository: DeviceRepositoryProtocol {
    func listDevices() async throws -> [DeviceRecord] { [] }
    func save(_ device: DeviceRecord) async throws {}
    func delete(id: DeviceID) async throws {}
}

private actor AnchorEmptyCredentialVault: DeviceCredentialVault {
    func store(_ secret: String, for handle: CredentialHandle) async throws {}
    func resolve(_ handle: CredentialHandle) async throws -> String? { nil }
    func delete(_ handle: CredentialHandle) async throws {}
}
