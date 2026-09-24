import AppKit

/// Executable entry point and concrete service construction belong to I1. The
/// injectable initializer keeps this target usable by deterministic tests.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let makeWindow: () throws -> MainWindowController
    private var controller: MainWindowController?
    public private(set) var launchFailed = false

    public override init() {
        makeWindow = {
            guard let resourceURL = Bundle.main.resourceURL else { throw ShellError.unavailable }
            let candidates = [
                resourceURL.appendingPathComponent("dist", isDirectory: true),
                resourceURL.appendingPathComponent("web", isDirectory: true),
            ]
            guard let distURL = candidates.first(where: {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path)
            }) else { throw ShellError.unavailable }
            return try MainWindowController(distURL: distURL)
        }
        super.init()
    }

    public init(makeWindow: @escaping () throws -> MainWindowController) {
        self.makeWindow = makeWindow
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            controller = try makeWindow()
            controller?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            launchFailed = true
            let alert = NSAlert()
            alert.messageText = "Corral could not load its bundled interface."
            alert.informativeText = "Reinstall a complete application bundle."
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        controller?.dispose()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
