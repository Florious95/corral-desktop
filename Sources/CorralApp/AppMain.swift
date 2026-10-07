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
            var environment = environment
            let explicitEndpoint = environment["CORRAL_NATIVE_ENDPOINT"].flatMap { $0.isEmpty ? nil : $0 }
            let resources = Bundle.main.resourceURL?.appendingPathComponent(BundledRuntime.folderName, isDirectory: true)
            let hasRuntime = resources.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(BundledRuntime.manifestName).path) } == true
            if Bundle.main.object(forInfoDictionaryKey: "CorralSelfContainedRuntime") as? Bool == true, !hasRuntime {
                throw BundledRuntime.Failure.invalidManifest
            }
            if hasRuntime, explicitEndpoint == nil { environment["CORRAL_NATIVE_PREFER_LOCAL"] = "1" }
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
            let hasExplicitEndpoint = explicitEndpoint != nil
            var runtimeToken: String?
            var runtimeConfiguration: BundledRuntime.Configuration?
            if hasRuntime, !hasExplicitEndpoint, let resources {
                let home = URL(fileURLWithPath: environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path).resolvingSymlinksInPath()
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent(DeviceRepository.namespace, isDirectory: true)
                runtimeConfiguration = BundledRuntime.Configuration(resources: resources, home: home, support: support,
                    port: 9900, label: "com.corral.native.dev.agentmirrord")
            }
#if DEBUG
            if environment["CORRAL_NATIVE_BOOTSTRAP_RUNTIME"] == "1" {
                guard let acceptanceDirectory, let supportDirectory, hasRuntime, let resources,
                      let explicitEndpoint, let url = URL(string: explicitEndpoint),
                      let endpoint = try? ApprovedEndpoint(url: url), endpoint.port != 9900,
                      endpoint.host == "127.0.0.1", endpoint.scheme == "ws" else { throw CorralAcceptanceDriver.Failure.unsafeConfiguration }
                let home = acceptanceDirectory.appendingPathComponent("home", isDirectory: true)
                guard home.resolvingSymlinksInPath().path.hasPrefix(acceptanceDirectory.path + "/") else { throw CorralAcceptanceDriver.Failure.unsafeConfiguration }
                runtimeConfiguration = BundledRuntime.Configuration(resources: resources, home: home,
                    support: supportDirectory.appendingPathComponent(DeviceRepository.namespace, isDirectory: true),
                    port: endpoint.port, label: "com.corral.native.test." + String(BundledRuntime.hash(Data(acceptanceDirectory.path.utf8)).prefix(12)),
                    discoveryDirectory: acceptanceDirectory.appendingPathComponent("tmux-\(getuid())", isDirectory: true),
                    activityDirectory: acceptanceDirectory.appendingPathComponent("pi-activity", isDirectory: true))
            }
#endif
            if let runtimeConfiguration {
                let ready = try await BundledRuntime.shared.prepare(runtimeConfiguration)
                runtimeToken = ready.token
            }
            let startupDevices = try await repository.listDevices()
            let startupUsesLocalHost = startupDevices.first?.id == LocalDaemonTokenDiscovery.deviceID || startupDevices.isEmpty
            if runtimeConfiguration == nil, !hasExplicitEndpoint, startupUsesLocalHost {
                let token = await LocalDaemonTokenDiscovery.token(environment: environment, credentialVault: credentials)
                await LocalDaemonSupervisor.ensureLocalDaemonRunning(token: token, environment: environment)
            }
            await coordinator.start(bootstrapToken: runtimeToken)
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
