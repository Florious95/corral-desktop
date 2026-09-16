import AppKit
import Services
import Shell

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let makeWindow: () throws -> Shell.MainWindowController
    private let migration: DeviceMigration
    private var windowController: Shell.MainWindowController?

    override init() {
        migration = DeviceMigration(namespace: AppServices.shared.namespace)
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
                // Migrate before constructing the WebView so a first page boot
                // can only observe the completed Keychain-backed device list.
                try await migrationDevices()
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

    private func migrationDevices() async throws {
        _ = try await migration.migrate(from: Self.legacyDevicesURL())
    }

    private static func legacyDevicesURL() throws -> URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ShellError.unavailable
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.agentmirror.desktop"
        return appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("devices.json", isDirectory: false)
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
        alert.informativeText = "前端资源或安全存储初始化失败。请检查应用安装后重试。"
        alert.addButton(withTitle: "退出")
        alert.runModal()
    }
}
