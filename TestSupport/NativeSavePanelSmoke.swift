// Run with the actual DEBUG acceptance helper, not a duplicate implementation:
// swiftc -DDEBUG Sources/CorralApp/CorralAcceptanceSavePanel.swift TestSupport/NativeSavePanelSmoke.swift -o .build/native-save-panel-smoke
// .build/native-save-panel-smoke
// Real offscreen WindowServer/NSSavePanel/AX; no activation, HID, provider call, or user file.
import AppKit
import UniformTypeIdentifiers

@MainActor
private final class SavePanelFixture: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var panel: NSSavePanel!
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("corral-native-save-panel-" + UUID().uuidString)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { finish(1, "private directory failed") }
        window = NSWindow(contentRect: NSRect(x: -8000, y: -8000, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.orderBack(nil)
        panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.directoryURL = directory
        panel.nameFieldStringValue = "exported-session.html"
        panel.prompt = "保存 HTML"
        panel.beginSheetModal(for: window) { response in
            let correct = response == .OK && self.panel.url?.resolvingSymlinksInPath() == self.directory.appendingPathComponent("exported-session.html").resolvingSymlinksInPath()
            self.finish(correct ? 0 : 1, "native_callback=\(response.rawValue) private_destination=\(correct)")
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            do {
                try await Task.detached { try CorralAcceptanceSavePanel.press(prompt: "not the save button") }.value
                finish(1, "wrong button unexpectedly accepted")
            } catch { print("negative_unknown_button=PASS") }
            do { try await Task.detached { try CorralAcceptanceSavePanel.press(prompt: "保存 HTML") }.value }
            catch { finish(1, "native press failed: \(error)") }
            try? await Task.sleep(for: .seconds(5))
            finish(1, "native callback timed out")
        }
    }

    private func finish(_ code: Int32, _ message: String) -> Never {
        print(message)
        try? FileManager.default.removeItem(at: directory)
        exit(code)
    }
}

@main
private enum NativeSavePanelSmoke {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        let fixture = MainActor.assumeIsolated { SavePanelFixture() }
        app.delegate = fixture
        app.run()
        withExtendedLifetime(fixture) {}
    }
}
