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

    func testProductionPortIsPrunedAndApprovedDeviceSurvivesLoad() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let namespace = support.appendingPathComponent(DeviceRepository.namespace, isDirectory: true)
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
        let invalidProductionDevice: [String: Any] = [
            "id": "production",
            "name": "Must be pruned",
            "endpoint": ["scheme": "ws", "host": "127.0.0.1", "port": 9900],
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
