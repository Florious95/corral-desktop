import AppKit
import Shell

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: Shell.MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let webRoot = WebViewHost.resolveWebRoot() else {
            showMissingWebRoot()
            NSApp.terminate(nil)
            return
        }

        do {
            windowController = try Shell.MainWindowController(distURL: webRoot)
            windowController?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            showMissingWebRoot()
            NSApp.terminate(nil)
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

    private func showMissingWebRoot() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "AgentMirror 无法加载前端资源"
        alert.informativeText = "未找到构建后的 dist/index.html。请先运行 npm run build。"
        alert.addButton(withTitle: "退出")
        alert.runModal()
    }
}
