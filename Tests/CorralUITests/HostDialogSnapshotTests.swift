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
            ("nearby-failed", {
                let dialog = NearbyHostsDialogViewController(); dialog.loadViewIfNeeded()
                dialog.update(hosts: hosts); dialog.select(hostID: "lab-host-000003"); dialog.tokenField.stringValue = "wrong"
                dialog.phase = .failed("配对 Token 不正确，或该地址不是这台主机。"); return dialog
            })
        ]
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
