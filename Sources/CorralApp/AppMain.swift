import AppKit
import CorralContracts
import CorralProtocol
import CorralServices
import Security

public enum CorralAppIdentity {
    public static let bundleIdentifier = "com.corral.native.dev"
}

private actor KeychainDeviceCredentialVault: DeviceCredentialVault {
    private let service = CorralAppIdentity.bundleIdentifier

    func store(_ secret: String, for handle: CredentialHandle) async throws {
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

    func resolve(_ handle: CredentialHandle) async throws -> String? {
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
        guard status == errSecSuccess, let data = result as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            throw KeychainCredentialError.status(status)
        }
        return secret
    }

    func delete(_ handle: CredentialHandle) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: handle.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialError.status(status)
        }
    }
}

private enum KeychainCredentialError: Error {
    case status(OSStatus)
}

@MainActor
final class CorralAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: CorralApplicationCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        let background = environment["CORRAL_NATIVE_BACKGROUND"] == "1"
        NSApp.setActivationPolicy(background ? .accessory : .regular)
        NSApp.mainMenu = makeMainMenu()
        Task { @MainActor in await startCoordinator(environment: environment, background: background) }
    }

    private func startCoordinator(environment: [String: String], background: Bool) async {
        do {
            let sessionLink = URLSessionSessionLink(codec: ProtocolV1Codec())
            let lifecycle = CoordinatorDeviceSessionLifecycle(sessionLink: sessionLink)
            let repository = try DeviceRepository(
                deletionConfirmer: AppKitDeviceDeletionConfirmer(),
                sessionLifecycle: lifecycle
            )
            let credentials = KeychainDeviceCredentialVault()
            let workspaceStore = try CorralWorkspaceStore()
            let preferencesStore = try UserPreferencesStore()
            let coordinator = CorralApplicationCoordinator(
                deviceRepository: repository,
                credentialVault: credentials,
                sessionLink: sessionLink,
                deviceSessionLifecycle: lifecycle,
                workspaceStore: workspaceStore,
                userPreferencesStore: preferencesStore,
                initialWorkspaceState: await workspaceStore.snapshot(),
                initialUserPreferences: await preferencesStore.snapshot(),
                environment: environment
            )
            self.coordinator = coordinator
            if background {
                coordinator.windowController.window?.orderBack(nil)
            } else {
                coordinator.windowController.showWindow(nil)
                coordinator.windowController.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            await coordinator.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Corral Native could not start"
            alert.informativeText = String(describing: error)
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Corral Native")
        appMenu.addItem(withTitle: "Quit Corral Native", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let newAgent = NSMenuItem(title: "New Agent", action: #selector(showNewAgent(_:)), keyEquivalent: "n")
        newAgent.target = self
        fileMenu.addItem(newAgent)
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        return menu
    }

    @objc private func showNewAgent(_ sender: Any?) { coordinator?.showNewAgentDialog() }

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
