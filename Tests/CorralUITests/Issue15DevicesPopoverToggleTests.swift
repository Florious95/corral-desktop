import AppKit
import CorralContracts
import CorralProtocol
import CorralServices
import CorralUI
import Foundation
import XCTest
@testable import CorralApp

@MainActor
final class Issue15DevicesPopoverToggleTests: XCTestCase {
    func testDevicesButtonSecondActivationClosesPopover() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-issue15-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let link = Issue15UnusedSessionLink()
        let workspaceStore = try CorralWorkspaceStore(applicationSupportDirectory: root.appendingPathComponent("workspace"))
        let preferencesStore = try UserPreferencesStore(applicationSupportDirectory: root.appendingPathComponent("preferences"))
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: Issue15EmptyDeviceRepository(),
            credentialVault: Issue15EmptyCredentialVault(),
            sessionLink: link,
            deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: link),
            workspaceStore: workspaceStore,
            userPreferencesStore: preferencesStore,
            initialWorkspaceState: await workspaceStore.snapshot(),
            initialUserPreferences: await preferencesStore.snapshot(),
            environment: [
                "CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
                "CORRAL_NATIVE_TOKEN": "issue15-test-only",
                "CORRAL_NATIVE_BACKGROUND": "1"
            ]
        )
        let window = try XCTUnwrap(coordinator.windowController.window)
        defer {
            coordinator.devicesCardPanel?.orderOut(nil)
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        let button = coordinator.workspaceView.sidebar.devicesButton
        var activationCount = 0
        let onDevices = coordinator.workspaceView.onDevices
        coordinator.workspaceView.onDevices = {
            activationCount += 1
            onDevices?()
        }
        XCTAssertFalse(button.isHidden)
        XCTAssertGreaterThan(button.bounds.width, 0)

        try click(button)
        let opened = await waitUntil { coordinator.devicesCardPanel?.isVisible == true }
        XCTAssertTrue(opened, "The first activation must show the devices popover")
        XCTAssertEqual(activationCount, 1, "The first button click must reach the coordinator")
        let firstPanel = try XCTUnwrap(coordinator.devicesCardPanel)

        // Reproduce AppKit dismissing an anchored panel when its owner regains focus.
        // The subsequent button click must not interpret the hidden panel as a fresh open.
        firstPanel.resignKey()
        XCTAssertFalse(firstPanel.isVisible, "The focus transition should dismiss the existing panel before the second activation")
        try click(button)
        XCTAssertEqual(activationCount, 2, "The second button click must reach the same coordinator action")
        let closed = await waitUntil {
            coordinator.devicesCardPanel == nil || coordinator.devicesCardPanel?.isVisible == false
        }
        XCTAssertTrue(closed, "The second activation must close the existing popover, not create another one")
        XCTAssertFalse(coordinator.devicesCardPanel === firstPanel && firstPanel.isVisible,
                       "The first popover must not be replaced by a newly visible popover")
        await coordinator.stop()
    }

    private func click(_ view: NSView) throws {
        let window = try XCTUnwrap(view.window)
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ))
            window.sendEvent(event)
        }
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}

private actor Issue15EmptyDeviceRepository: DeviceRepositoryProtocol {
    func listDevices() async throws -> [DeviceRecord] { [] }
    func save(_ device: DeviceRecord) async throws {}
    func delete(id: DeviceID) async throws {}
}

private actor Issue15EmptyCredentialVault: DeviceCredentialVault {
    func store(_ secret: String, for handle: CredentialHandle) async throws {}
    func resolve(_ handle: CredentialHandle) async throws -> String? { nil }
    func delete(_ handle: CredentialHandle) async throws {}
}

private struct Issue15UnusedSessionLink: SessionLinkProtocol {
    func connect(to endpoint: ApprovedEndpoint, deviceID: DeviceID, credential: CredentialHandle) async throws -> AuthenticatedConnection {
        throw SessionLinkFailure.disconnected
    }

    func eventStream() async throws -> any SessionEventStream { Issue15NeverEventStream() }
    func send(_ command: ClientCommand) async throws -> CommandSendReceipt { throw SessionLinkFailure.disconnected }
    func disconnect() async {}
}

private struct Issue15NeverEventStream: SessionEventStream {
    var budget: SessionEventStreamBudget {
        SessionEventStreamBudget(maximumBufferedBytes: 1_024, maximumBufferedEvents: 1, maximumBufferedControls: 1)
    }

    func next() async throws -> SessionEventEnvelope? { nil }
}