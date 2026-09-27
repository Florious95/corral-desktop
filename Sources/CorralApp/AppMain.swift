import AppKit
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

        let sessionLink = URLSessionSessionLink(codec: ProtocolV1Codec())
        let coordinator = CorralMVPCoordinator(
            sessionLink: sessionLink,
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
