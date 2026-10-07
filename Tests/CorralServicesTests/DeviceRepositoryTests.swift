import CorralContracts
import CorralServices
import Foundation
import XCTest

final class DeviceRepositoryTests: XCTestCase {
    func testCRUDRenameUsesPrivateNamespacedStorageAndCascadesConfirmedDelete() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let lifecycle = RecordingSessionLifecycle()
        let device = try makeDevice(id: "remote-1", name: "Build host")
        let unconfirmed = try DeviceRepository(applicationSupportDirectory: support)

        try await unconfirmed.save(device)
        do {
            try await unconfirmed.delete(id: device.id)
            XCTFail("Deletion without explicit confirmation must fail closed")
        } catch let error as DeviceRepositoryError {
            XCTAssertEqual(error, .confirmationRequired)
        }
        let remainsAfterUnconfirmedDelete = try await unconfirmed.listDevices()
        XCTAssertEqual(remainsAfterUnconfirmedDelete, [device])

        let confirmer = AlwaysConfirmDeletion()
        let repository = try DeviceRepository(
            applicationSupportDirectory: support,
            deletionConfirmer: confirmer,
            sessionLifecycle: lifecycle
        )
        let fetched = await repository.device(id: device.id)
        XCTAssertEqual(fetched, device)
        try await repository.rename(id: device.id, to: "Renamed host")
        let renamed = try await repository.listDevices()
        XCTAssertEqual(renamed.first?.name, "Renamed host")
        XCTAssertEqual(renamed.first?.endpoint, device.endpoint)
        XCTAssertEqual(renamed.first?.credential, device.credential)

        let file = support
            .appendingPathComponent(DeviceRepository.namespace, isDirectory: true)
            .appendingPathComponent(DeviceRepository.storageFilename)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("password"))

        try await repository.delete(id: device.id)
        let remaining = try await repository.listDevices()
        XCTAssertTrue(remaining.isEmpty)
        let cleanupCalls = await lifecycle.calls
        XCTAssertEqual(cleanupCalls, ["disconnect:\(device.id.rawValue)", "remove:\(device.id.rawValue)"])
        let confirmationCount = await confirmer.confirmationCount
        XCTAssertEqual(confirmationCount, 2)
    }

    func testSecondConfirmationCanCancelDeletionBeforeSessionCleanup() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let lifecycle = RecordingSessionLifecycle()
        let device = try makeDevice(id: "remote-2", name: "Protected host")
        let repository = try DeviceRepository(
            applicationSupportDirectory: support,
            deletionConfirmer: RejectFinalConfirmation(),
            sessionLifecycle: lifecycle
        )
        try await repository.save(device)

        do {
            try await repository.delete(id: device.id)
            XCTFail("A rejected second confirmation must cancel deletion")
        } catch let error as DeviceRepositoryError {
            XCTAssertEqual(error, .deletionNotConfirmed)
        }
        let devices = try await repository.listDevices()
        XCTAssertEqual(devices, [device])
        let cleanupCalls = await lifecycle.calls
        XCTAssertTrue(cleanupCalls.isEmpty)
    }

    func testFirstLaunchStartsEmptyInDedicatedNamespace() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let repository = try DeviceRepository(applicationSupportDirectory: support)

        let devices = try await repository.listDevices()
        XCTAssertTrue(devices.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: support.appendingPathComponent(DeviceRepository.namespace, isDirectory: true).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent(DeviceRepository.storageFilename).path))
    }

    func testNonLoopbackDeviceIsPrunedAndApprovedDeviceSurvivesLoad() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let namespace = support.appendingPathComponent(DeviceRepository.namespace, isDirectory: true)
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
        let invalidProductionDevice: [String: Any] = [
            "id": "production",
            "name": "Must be pruned",
            "endpoint": ["scheme": "ws", "host": "production.example", "port": 9900],
            "credentialHandle": "keychain-item:production"
        ]
        let approvedDevice: [String: Any] = [
            "id": "development",
            "name": "Local development",
            "endpoint": ["scheme": "ws", "host": "localhost", "port": 9919],
            "credentialHandle": "keychain-item:development"
        ]
        let data = try JSONSerialization.data(withJSONObject: [invalidProductionDevice, approvedDevice])
        let file = namespace.appendingPathComponent(DeviceRepository.storageFilename)
        try data.write(to: file)

        let repository = try DeviceRepository(applicationSupportDirectory: support)
        let devices = try await repository.listDevices()
        XCTAssertEqual(devices.map(\.id), [DeviceID("development")])
        let stored = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(stored.contains("9900"))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testLoopback9900LoadsAndSavesWithoutAFeatureFlag() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let namespace = support.appendingPathComponent(DeviceRepository.namespace, isDirectory: true)
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
        let localProductionDevice: [String: Any] = [
            "id": "local-production",
            "name": "Local manual acceptance",
            "endpoint": ["scheme": "ws", "host": "127.0.0.1", "port": 9900],
            "credentialHandle": "keychain-item:local-production"
        ]
        let remoteProductionDevice: [String: Any] = [
            "id": "remote-production",
            "name": "Must still be pruned",
            "endpoint": ["scheme": "ws", "host": "production.example", "port": 9900],
            "credentialHandle": "keychain-item:remote-production"
        ]
        let file = namespace.appendingPathComponent(DeviceRepository.storageFilename)
        try JSONSerialization.data(withJSONObject: [localProductionDevice, remoteProductionDevice]).write(to: file)

        let repository = try DeviceRepository(applicationSupportDirectory: support)
        let loaded = try await repository.listDevices()
        XCTAssertEqual(loaded.map(\.id), [DeviceID("local-production")])
        XCTAssertEqual(loaded[0].endpoint.url.absoluteString, "ws://127.0.0.1:9900/ws")
        let afterPruning = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertTrue(afterPruning.contains("9900"))
        XCTAssertFalse(afterPruning.contains("remote-production"))

        try await repository.save(loaded[0])
        let reloaded = try DeviceRepository(applicationSupportDirectory: support)
        let reloadedDevices = try await reloaded.listDevices()
        XCTAssertEqual(reloadedDevices, loaded)
        XCTAssertTrue(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("9900"))
    }

    func testHostRoutesPersistReloadAndSurviveRename() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let lan = try ApprovedEndpoint(host: "192.168.31.116", port: 9931, pairingHostID: "studio-host-01")
        let tailnet = try ApprovedEndpoint(host: "100.101.2.3", port: 9931, pairingHostID: "studio-host-01")
        let device = DeviceRecord(id: DeviceID("studio"), name: "Studio", endpoint: lan, credential: CredentialHandle("c"), alternateEndpoints: [tailnet])
        let repository = try DeviceRepository(applicationSupportDirectory: support)
        try await repository.save(device)
        try await repository.rename(id: device.id, to: "Mac Studio")

        let reloaded = try await DeviceRepository(applicationSupportDirectory: support).listDevices()
        XCTAssertEqual(reloaded.first?.name, "Mac Studio")
        XCTAssertEqual(reloaded.first?.endpoints, [tailnet, lan], "Rename must not drop the Tailscale route")
    }

    func testOneUnusableStoredRouteNeverPrunesTheHost() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let directory = support.appendingPathComponent(DeviceRepository.namespace, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = """
        [{"id":"studio","name":"Studio","credentialHandle":"c",
          "endpoint":{"scheme":"ws","host":"192.168.31.116","port":9931,"path":"/ws","pairingHostID":"studio-host-01"},
          "alternateEndpoints":[{"scheme":"ws","host":"8.8.8.8","port":9931,"path":"/ws","pairingHostID":"studio-host-01"},
                                {"scheme":"ws","host":"100.101.2.3","port":9931,"path":"/ws","pairingHostID":"studio-host-01"}]},
         {"id":"legacy","name":"Legacy","credentialHandle":"l",
          "endpoint":{"scheme":"ws","host":"127.0.0.1","port":9919,"path":"/ws"}}]
        """
        let file = directory.appendingPathComponent(DeviceRepository.storageFilename)
        try Data(store.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        let devices = try await DeviceRepository(applicationSupportDirectory: support).listDevices()
        XCTAssertEqual(devices.map(\.id.rawValue), ["studio", "legacy"])
        XCTAssertEqual(devices.first?.endpoints.map(\.host), ["100.101.2.3", "192.168.31.116"], "The public 8.8.8.8 route is dropped, the host kept")
        XCTAssertEqual(devices.last?.alternateEndpoints, [])
    }

    private func makeDevice(id: String, name: String) throws -> DeviceRecord {
        DeviceRecord(
            id: DeviceID(id),
            name: name,
            endpoint: try ApprovedEndpoint(host: "localhost", port: ApprovedEndpoint.developmentPort),
            credential: CredentialHandle("keychain-item:\(id)")
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private actor AlwaysConfirmDeletion: DeviceDeletionConfirming {
    private(set) var confirmationCount = 0

    func confirmFirstDeletion(of device: DeviceRecord) async -> Bool {
        confirmationCount += 1
        return true
    }

    func confirmFinalDeletion(of device: DeviceRecord) async -> Bool {
        confirmationCount += 1
        return true
    }
}

private struct RejectFinalConfirmation: DeviceDeletionConfirming {
    func confirmFirstDeletion(of device: DeviceRecord) async -> Bool { true }
    func confirmFinalDeletion(of device: DeviceRecord) async -> Bool { false }
}

private actor RecordingSessionLifecycle: DeviceSessionLifecycle {
    private(set) var calls: [String] = []

    func disconnectSessions(on deviceID: DeviceID) async throws {
        calls.append("disconnect:\(deviceID.rawValue)")
    }

    func removeSessions(on deviceID: DeviceID) async throws {
        calls.append("remove:\(deviceID.rawValue)")
    }
}
