import AppKit
import CorralContracts
import CorralServices
import XCTest
@testable import CorralUI

/// Design-review captures of the host dialogs, dark and light, written as PNGs only when
/// `CORRAL_UI_SNAPSHOT_DIR` is set. Offscreen windows; no network, no production app.
@MainActor
final class HostDialogSnapshotTests: XCTestCase {
    static let hosts = [
        NearbyHost(hostID: "studio-host-0001", name: "Mac Studio", port: 9900, addresses: ["192.168.31.20", "100.101.2.3"], channels: [.bonjour, .tailscale]),
        NearbyHost(hostID: "air-host-000002", name: "MacBook Air", port: 9900, addresses: ["100.77.226.21"], channels: [.tailscale]),
        NearbyHost(hostID: "lab-host-000003", name: "build-server.lab", port: 9900, addresses: ["10.0.4.18"], channels: [.bonjour])
    ]

    func testCaptureHostDialogs() throws {
        guard let directory = ProcessInfo.processInfo.environment["CORRAL_UI_SNAPSHOT_DIR"] else { throw XCTSkip("Set CORRAL_UI_SNAPSHOT_DIR to capture") }
        let previous = CorralAestheticTokens.themeMode
        defer { CorralAestheticTokens.themeMode = previous }
        for theme in [CorralThemeMode.dark, .light] {
            CorralAestheticTokens.themeMode = theme
            for (name, make) in Self.scenarios {
                let dialog = make()
                try capture(dialog, to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(theme.rawValue).png"))
            }
        }
    }

    static var scenarios: [(String, () -> CorralDialogViewController)] {
        [
            ("nearby-scanning-empty", {
                let dialog = NearbyHostsDialogViewController(); dialog.loadViewIfNeeded(); dialog.isScanning = true; return dialog
            }),
            ("nearby-none-found", {
                let dialog = NearbyHostsDialogViewController(); dialog.loadViewIfNeeded(); dialog.isScanning = false; return dialog
            }),
            ("nearby-found-token", {
                let dialog = NearbyHostsDialogViewController(pairedHostIDs: ["air-host-000002"]); dialog.loadViewIfNeeded()
                dialog.update(hosts: hosts); dialog.isScanning = true; dialog.select(hostID: "studio-host-0001")
                dialog.tokenField.stringValue = "secret-token"; dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
                return dialog
            }),
            ("adddevice-empty", {
                let dialog = AddDeviceDialogViewController(); dialog.onDiscoverNearby = {}; return dialog
            }),
            ("adddevice-error", {
                let dialog = AddDeviceDialogViewController(); dialog.onDiscoverNearby = {}; dialog.loadViewIfNeeded()
                dialog.nameField.stringValue = "Mac Studio"; dialog.addressField.stringValue = "http://192.168.31.20"; dialog.submit(); return dialog
            }),
            ("pairing-remote", {
                PairingDialogViewController(payload: CorralPairingPayload(url: "ws://100.75.207.88:9900/ws", token: "secret-token", name: "MacBook-Pro.local",
                    candidates: ["ws://100.75.207.88:9900/ws", "ws://192.168.31.116:9900/ws", "ws://10.202.81.20:9900/ws"], hostID: "RBXDBVMA5BQXZ7N4SSE5U55XG4", port: 9900))
            }),
            ("pairing-local-needs-input", {
                PairingDialogViewController(payload: CorralPairingPayload(url: "ws://127.0.0.1:9900/ws"))
            }),
            ("settings", { SettingsDialogViewController() }),
            ("newagent", {
                NewAgentDialogViewController(spaceName: "corral-native", launchers: [
                    CorralAgentLauncher(provider: "claude_code", displayName: "Claude Code", supportsBypass: true),
                    CorralAgentLauncher(provider: "codex", displayName: "Codex CLI", supportsBypass: true),
                    CorralAgentLauncher(provider: "cursor", displayName: "Cursor Agent", supportsBypass: false),
                    CorralAgentLauncher(provider: "grok", displayName: "Grok", supportsBypass: false)])
            }),
            ("closeagent", { CloseAgentDialogViewController(agentName: "ACCEPT-A-3F8976A4") }),
            ("nearby-failed", {
                let dialog = NearbyHostsDialogViewController(); dialog.loadViewIfNeeded()
                dialog.update(hosts: hosts); dialog.select(hostID: "lab-host-000003"); dialog.tokenField.stringValue = "wrong"
                dialog.phase = .failed("配对 Token 不正确，或该地址不是这台主机。"); return dialog
            })
        ]
    }

    func testCaptureDevicesCard() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CORRAL_UI_SNAPSHOT_DIR"] else { throw XCTSkip("Set CORRAL_UI_SNAPSHOT_DIR to capture") }
        let previous = CorralAestheticTokens.themeMode
        defer { CorralAestheticTokens.themeMode = previous }
        let hostID = "studio-host-0001"
        let local = DeviceRecord(id: DeviceID("local"), name: "本机", endpoint: try ApprovedEndpoint(host: "127.0.0.1", port: 9900), credential: CredentialHandle("l"))
        let studio = DeviceRecord(id: DeviceID("studio"), name: "Mac Studio", endpoint: try ApprovedEndpoint(host: "192.168.31.20", port: 9900, pairingHostID: hostID),
                                  credential: CredentialHandle("s"), alternateEndpoints: [try ApprovedEndpoint(host: "100.101.2.3", port: 9900, pairingHostID: hostID)])
        for theme in [CorralThemeMode.dark, .light] {
            CorralAestheticTokens.themeMode = theme
            let controller = DevicesPopoverViewController(repository: SnapshotRepository(records: [local, studio]))
            controller.loadViewIfNeeded()
            try await controller.reloadDevices()
            controller.setReadyDevices([studio.id], activeRoute: studio.endpoints.first)
            let size = controller.preferredContentSize
            let window = NSWindow(contentRect: NSRect(x: -12_000, y: -12_000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
            window.contentViewController = controller
            window.setContentSize(size)
            window.orderBack(nil)
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            window.displayIfNeeded(); controller.view.display()
            if ProcessInfo.processInfo.environment["CORRAL_UI_SNAPSHOT_DEBUG"] != nil {
                func dump(_ view: NSView, _ depth: Int) {
                    print("DBG " + String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.frame) \((view as? NSTextField)?.stringValue ?? "")")
                    view.subviews.forEach { dump($0, depth + 1) }
                }
                dump(controller.view, 0)
            }
            try render(controller.view, size: size, to: URL(fileURLWithPath: directory).appendingPathComponent("devices-card-\(theme.rawValue).png"))
            window.orderOut(nil); window.close()
        }
    }

    private func render(_ view: NSView, size: NSSize, to url: URL) throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        try XCTUnwrap(view.layer).render(in: context.cgContext)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    private func capture(_ dialog: CorralDialogViewController, to url: URL) throws {
        _ = NSApplication.shared
        let size = NSSize(width: 760, height: 640)
        let window = NSWindow(contentRect: NSRect(x: -12_000, y: -12_000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: CorralAestheticTokens.isDark ? .darkAqua : .aqua)
        let content = NSView(frame: NSRect(origin: .zero, size: size)); content.wantsLayer = true
        content.layer?.backgroundColor = CorralAestheticTokens.background.cgColor
        window.contentView = content
        window.orderBack(nil)
        dialog.present(over: window)
        content.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        content.displayIfNeeded()
        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        try XCTUnwrap(content.layer).render(in: context.cgContext)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        dialog.dismiss()
        window.orderOut(nil); window.close()
    }
}

private actor SnapshotRepository: DeviceRepositoryProtocol {
    let records: [DeviceRecord]
    init(records: [DeviceRecord]) { self.records = records }
    func listDevices() async throws -> [DeviceRecord] { records }
    func save(_ device: DeviceRecord) async throws {}
    func delete(id: DeviceID) async throws {}
}
