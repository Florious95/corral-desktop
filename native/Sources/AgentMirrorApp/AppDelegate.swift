import AppKit
import Foundation
import Services
import Shell

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let makeWindow: () throws -> Shell.MainWindowController
    private var windowController: Shell.MainWindowController?

    override init() {
        makeWindow = {
            guard let webRoot = Self.resolveWebRoot() else { throw ShellError.unavailable }
            return try Shell.MainWindowController(
                distURL: webRoot,
                services: AppServices.shared
            )
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Keep the legacy Tauri path and tighten it to a private file;
                // no credential service or system authorization is used here.
                try await DeviceStore.shared.prepare()
                windowController = try makeWindow()
                windowController?.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                showLaunchFailure()
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.dispose()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private static func resolveWebRoot() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let candidates = [
            resourceURL.appendingPathComponent("dist", isDirectory: true),
            resourceURL.appendingPathComponent("web", isDirectory: true),
        ]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path)
        }
    }

    private func showLaunchFailure() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "AgentMirror 无法启动"
        alert.informativeText = "前端资源或设备配置初始化失败。请检查应用安装后重试。"
        alert.addButton(withTitle: "退出")
        alert.runModal()
    }
}
