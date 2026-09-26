import AppKit
import CorralContracts
import CorralMetalTerminal
import CorralProtocol
import CorralServices
import Security

public enum CorralAppIdentity {
    public static let bundleIdentifier = "com.corral.native.dev"
}

@MainActor
final class CorralAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: CorralApplicationCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let environment = ProcessInfo.processInfo.environment
        do {
            let sessionLink = URLSessionSessionLink(codec: ProtocolV1Codec())
            let lifecycle = CoordinatorDeviceSessionLifecycle(sessionLink: sessionLink)
            let repository = try DeviceRepository(
                deletionConfirmer: AppKitDeviceDeletionConfirmer(),
                sessionLifecycle: lifecycle
            )
            let workspaceStore = try CorralWorkspaceStore()
            let userPreferencesStore = try UserPreferencesStore()
            let credentialVault = KeychainDeviceCredentialVault()
            Task { @MainActor in
                do {
                    let initialWorkspaceState = await workspaceStore.snapshot()
                    let initialUserPreferences = await userPreferencesStore.snapshot()
                    let atlas = GlyphAtlasPool.shared
                    let renderer = try SharedMetalTerminalRenderer(glyphAtlas: atlas)
                    let coordinator = CorralApplicationCoordinator(
                        deviceRepository: repository,
                        credentialVault: credentialVault,
                        sessionLink: sessionLink,
                        deviceSessionLifecycle: lifecycle,
                        renderer: renderer,
                        workspaceStore: workspaceStore,
                        userPreferencesStore: userPreferencesStore,
                        initialWorkspaceState: initialWorkspaceState,
                        initialUserPreferences: initialUserPreferences,
                        glyphAtlas: atlas,
                        environment: environment
                    )
                    self.coordinator = coordinator
                    if coordinator.backgroundMode {
                        coordinator.windowController.window?.orderBack(nil)
                    } else {
                        coordinator.windowController.showWindow(self)
                    }
                    await coordinator.start()
                } catch {
                    self.presentStartupFailure(error)
                }
            }
        } catch {
            presentStartupFailure(error)
        }
    }

    func installMainMenu() { NSApp.mainMenu = makeMainMenu() }

    func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Corral Native")
        appMenu.addItem(withTitle: "Quit Corral Native", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let newAgentItem = fileMenu.addItem(withTitle: "New Agent…", action: #selector(createNewAgent(_:)), keyEquivalent: "n")
        newAgentItem.identifier = NSUserInterfaceItemIdentifier("corral.newagent.menu")
        newAgentItem.keyEquivalentModifierMask = [.command]
        newAgentItem.target = self
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)
        return mainMenu
    }

    @objc private func createNewAgent(_ sender: Any?) {
        coordinator?.showNewAgentDialog()
    }

    private func presentStartupFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Corral Native could not start"
        alert.informativeText = String(describing: error)
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        coordinator?.setApplicationActive(true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        coordinator?.setApplicationActive(false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let coordinator else { return }
        Task { await coordinator.stop() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private enum KeychainCredentialError: Error {
    case emptySecret
    case status(Int32)
}

private actor KeychainDeviceCredentialVault: DeviceCredentialVault {
    private let service = CorralAppIdentity.bundleIdentifier

    func store(_ secret: String, for handle: CredentialHandle) throws {
        guard !secret.isEmpty else { throw KeychainCredentialError.emptySecret }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: handle.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainCredentialError.status(updateStatus) }
        } else if status != errSecSuccess {
            throw KeychainCredentialError.status(status)
        }
    }

    func resolve(_ handle: CredentialHandle) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: handle.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainCredentialError.status(status) }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ handle: CredentialHandle) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: handle.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainCredentialError.status(status) }
    }
}

@MainActor
@main
private enum CorralAppMain {
    static func main() {
        let application = NSApplication.shared
        let background = ProcessInfo.processInfo.environment["CORRAL_NATIVE_BACKGROUND"] == "1"
        application.setActivationPolicy(background ? .accessory : .regular)
        let delegate = CorralAppDelegate()
        application.delegate = delegate
        application.run()
    }
}
