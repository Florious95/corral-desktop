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
        installMainMenu()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Keep the Pi probe in place before the WebView and daemon
                // become visible. The installer owns only its exact files.
                try PiProbeInstaller.install(resourceDirectory: Bundle.main.resourceURL)
                // Migrate before constructing the WebView so a first page boot
                // can only observe the completed private-file device list.
                try await migrationDevices()
                let controller = try makeWindow()
                windowController = controller
                guard let window = controller.window else { throw ShellError.unavailable }
                window.center()
                controller.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
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

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "AgentMirror")
        let aboutItem = NSMenuItem(title: "About AgentMirror",
                                   action: Selector(("orderFrontStandardAboutPanel:")),
                                   keyEquivalent: "")
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit AgentMirror",
                                  action: Selector(("terminate:")),
                                  keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        func addEditItem(_ title: String, selector: String, keyEquivalent: String,
                         modifiers: NSEvent.ModifierFlags = [.command]) {
            let item = NSMenuItem(title: title, action: Selector((selector)), keyEquivalent: keyEquivalent)
            item.keyEquivalentModifierMask = modifiers
            editMenu.addItem(item)
        }
        addEditItem("Undo", selector: "undo:", keyEquivalent: "z")
        addEditItem("Redo", selector: "redo:", keyEquivalent: "z", modifiers: [.command, .shift])
        addEditItem("Cut", selector: "cut:", keyEquivalent: "x")
        addEditItem("Copy", selector: "copy:", keyEquivalent: "c")
        addEditItem("Paste", selector: "paste:", keyEquivalent: "v")
        addEditItem("Select All", selector: "selectAll:", keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
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
