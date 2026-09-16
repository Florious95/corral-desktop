import AppKit

/// Executable entry point and concrete service construction belong to I1.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let makeWindow: () throws -> MainWindowController
    private var controller: MainWindowController?
    public private(set) var launchFailed = false
    public init(makeWindow: @escaping () throws -> MainWindowController) { self.makeWindow = makeWindow }
    public func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            controller = try makeWindow()
            controller?.showWindow(nil)
        } catch {
            launchFailed = true
            // A fixed error contains no filesystem paths, URLs, or service secrets.
            let alert = NSAlert()
            alert.messageText = "AgentMirror could not load its bundled interface."
            alert.informativeText = "Reinstall a complete application bundle."
            alert.runModal()
            NSApp.terminate(nil)
        }
    }
    public func applicationWillTerminate(_ notification: Notification) { controller?.dispose() }
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
