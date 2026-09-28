import AppKit
import CorralContracts
import CorralProtocol
import CorralServices
import Darwin

public enum CorralAppIdentity {
    public static let bundleIdentifier = "com.corral.native.dev"
}

enum LegacyDeviceStoreMigration {
    enum MigrationError: Error { case unsafeStore, malformedStore, missingLoopbackDevice, storeCommitFailed }

    private struct LegacyStore: Decodable { let devices: [LegacyDevice] }
    private struct LegacyDevice: Decodable {
        let id: String?
        let name: String?
        let url: String?
        let token: String?
    }
    private struct LoopbackDevice {
        let id: String
        let name: String
        let token: String
    }
    private struct PersistedDevice: Encodable {
        struct Endpoint: Encodable {
            let scheme: String
            let host: String
            let port: Int
        }
        let id: String
        let name: String
        let endpoint: Endpoint
        let credentialHandle: String
    }

    static func migrateIfNeeded(credentialVault: any DeviceCredentialVault) async throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let url = support.appendingPathComponent(DeviceRepository.namespace, isDirectory: true)
            .appendingPathComponent(DeviceRepository.storageFilename, isDirectory: false)
        try await migrateIfNeeded(at: url, credentialVault: credentialVault)
    }

    static func migrateIfNeeded(at url: URL, credentialVault: any DeviceCredentialVault) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try validatePrivateStore(url)
        let legacyData = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: legacyData) as? [String: Any], root["devices"] != nil else { return }
        guard let legacy = try? JSONDecoder().decode(LegacyStore.self, from: legacyData) else {
            throw MigrationError.malformedStore
        }
        let targets = legacy.devices.compactMap { record -> LoopbackDevice? in
            guard let id = record.id, !id.isEmpty,
                  let name = record.name, !name.isEmpty,
                  let rawURL = record.url,
                  let token = record.token,
                  !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let components = URLComponents(string: rawURL),
                  components.scheme?.lowercased() == "ws",
                  components.host?.lowercased() == "127.0.0.1",
                  components.port == 9900,
                  components.path == ApprovedEndpoint.webSocketPath,
                  components.user == nil, components.password == nil,
                  components.query == nil, components.fragment == nil,
                  let endpointURL = URL(string: rawURL),
                  let endpoint = try? ApprovedEndpoint(url: endpointURL),
                  endpoint.url.absoluteString == "ws://127.0.0.1:9900/ws" else { return nil }
            return LoopbackDevice(id: id, name: name, token: token)
        }
        guard targets.count == 1, let device = targets.first else { throw MigrationError.missingLoopbackDevice }

        let handle = CredentialHandle("keychain-item:\(UUID().uuidString)")
        try await credentialVault.store(device.token, for: handle)
        let v2 = [PersistedDevice(
            id: device.id,
            name: device.name,
            endpoint: .init(scheme: "ws", host: "127.0.0.1", port: 9900),
            credentialHandle: handle.rawValue
        )]
        do {
            let data = try JSONEncoder().encode(v2)
            try data.write(to: url, options: .atomic)
            guard chmod(url.path, mode_t(0o600)) == 0 else { throw MigrationError.storeCommitFailed }
            try validatePrivateStore(url, requireExactMode: true)
        } catch {
            try? legacyData.write(to: url, options: .atomic)
            _ = chmod(url.path, mode_t(0o600))
            try? await credentialVault.delete(handle)
            throw MigrationError.storeCommitFailed
        }
    }

    private static func validatePrivateStore(_ url: URL, requireExactMode: Bool = false) throws {
        var file = stat()
        var directory = stat()
        guard lstat(url.path, &file) == 0,
              (file.st_mode & S_IFMT) == S_IFREG,
              file.st_uid == getuid(),
              (file.st_mode & 0o077) == 0,
              (!requireExactMode || (file.st_mode & 0o777) == 0o600),
              lstat(url.deletingLastPathComponent().path, &directory) == 0,
              (directory.st_mode & S_IFMT) == S_IFDIR,
              directory.st_uid == getuid(),
              (directory.st_mode & 0o077) == 0 else {
            throw MigrationError.unsafeStore
        }
    }
}

@MainActor
final class CorralAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: CorralApplicationCoordinator?
#if DEBUG
    private var acceptanceDriver: CorralAcceptanceDriver?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        let background = environment["CORRAL_NATIVE_BACKGROUND"] == "1"
        NSApp.setActivationPolicy(background ? .accessory : .regular)
        NSApp.mainMenu = makeMainMenu()
        Task { @MainActor in await startCoordinator(environment: environment, background: background) }
    }

    private func startCoordinator(environment: [String: String], background: Bool) async {
        do {
            var supportDirectory: URL?
#if DEBUG
            let acceptanceDirectory = try CorralAcceptanceDriver.directory(environment: environment)
            supportDirectory = acceptanceDirectory?.appendingPathComponent("storage", isDirectory: true)
#endif
            let credentials: any DeviceCredentialVault
            if let supportDirectory {
                credentials = PrivateFileCredentialVault(directoryURL: supportDirectory.appendingPathComponent("credentials", isDirectory: true))
            } else {
                credentials = AppDeviceCredentialVault()
                try await LegacyDeviceStoreMigration.migrateIfNeeded(credentialVault: credentials)
            }
            let sessionLink = URLSessionSessionLink(codec: ProtocolV1Codec())
            let lifecycle = CoordinatorDeviceSessionLifecycle(sessionLink: sessionLink)
            let repository = try DeviceRepository(
                applicationSupportDirectory: supportDirectory,
                deletionConfirmer: AppKitDeviceDeletionConfirmer(),
                sessionLifecycle: lifecycle
            )
            let workspaceStore = try CorralWorkspaceStore(applicationSupportDirectory: supportDirectory)
            let preferencesStore = try UserPreferencesStore(applicationSupportDirectory: supportDirectory)
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
#if DEBUG
            if let acceptanceDirectory {
                let driver = CorralAcceptanceDriver(directory: acceptanceDirectory, coordinator: coordinator)
                acceptanceDriver = driver
                driver.start()
            }
#endif
        } catch {
            if background {
                FileHandle.standardError.write(Data("Corral Native could not start: \(error)\n".utf8))
                NSApp.terminate(nil)
                return
            }
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
