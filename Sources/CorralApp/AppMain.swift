import AppKit
import CorralMetalTerminal
import CorralProtocol

public enum CorralAppIdentity {
    public static let bundleIdentifier = "com.corral.native.dev"
}

@MainActor
final class CorralAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: CorralMVPCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        let background = environment["CORRAL_NATIVE_BACKGROUND"] == "1"
        NSApp.setActivationPolicy(background ? .accessory : .regular)
        NSApp.mainMenu = makeMainMenu()

        do {
            let sessionLink = URLSessionSessionLink(codec: ProtocolV1Codec())
            let atlas = GlyphAtlasPool.shared
            let renderer = try SharedMetalTerminalRenderer(glyphAtlas: atlas)
            let coordinator = CorralMVPCoordinator(
                sessionLink: sessionLink,
                renderer: renderer,
                environment: environment
            )
            self.coordinator = coordinator
            if background {
                coordinator.window.orderBack(nil)
            } else {
                coordinator.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            Task { @MainActor in await coordinator.start() }
        } catch {
            presentStartupFailure(error)
        }
    }

    func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Corral Native")
        appMenu.addItem(withTitle: "Quit Corral Native", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        appItem.submenu = appMenu
        menu.addItem(appItem)
        return menu
    }

    private func presentStartupFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Corral Native could not start"
        alert.informativeText = String(describing: error)
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let coordinator else { return }
        Task { await coordinator.stop() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
@main
private enum CorralAppMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = CorralAppDelegate()
        application.delegate = delegate
        application.run()
    }
}
