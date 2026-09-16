import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let resolvedWebRoot = WebViewHost.resolveWebRoot()
        NSLog("AgentMirror web root: %@", resolvedWebRoot?.path ?? "<missing>")
        guard let webRoot = resolvedWebRoot else {
            showMissingWebRoot()
            NSApp.terminate(nil)
            return
        }

        windowController = MainWindowController(webRoot: webRoot)
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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
