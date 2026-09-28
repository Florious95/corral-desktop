import CorralContracts
import CorralServices
import Darwin
import XCTest
@testable import CorralApp

@MainActor
final class LegacyDeviceStoreMigrationTests: XCTestCase {
    func testMigratesOnlyLoopback9900AndMovesTokenOutOfTheStore() async throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-native-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let directory = support.appendingPathComponent(DeviceRepository.namespace, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let storeURL = directory.appendingPathComponent(DeviceRepository.storageFilename)
        let legacy: [String: Any] = ["devices": [
            ["id": "local-device", "name": "Local production", "url": "ws://127.0.0.1:9900/ws", "token": "fixture-loopback-secret"],
            ["id": "lan-device", "name": "LAN device", "url": "ws://192.168.31.110:9900/ws", "token": "fixture-lan-secret"]
        ]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: storeURL)
        XCTAssertEqual(chmod(storeURL.path, 0o600), 0)

        let vault = MigrationCredentialVault()
        try await LegacyDeviceStoreMigration.migrateIfNeeded(at: storeURL, credentialVault: vault)

        let migratedData = try Data(contentsOf: storeURL)
        let text = try XCTUnwrap(String(data: migratedData, encoding: .utf8))
        XCTAssertFalse(text.contains("fixture-loopback-secret"))
        XCTAssertFalse(text.contains("fixture-lan-secret"))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: migratedData) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0]["token"])
        XCTAssertEqual(rows[0]["id"] as? String, "local-device")
        let endpoint = try XCTUnwrap(rows[0]["endpoint"] as? [String: Any])
        XCTAssertEqual(endpoint["host"] as? String, "127.0.0.1")
        XCTAssertEqual(endpoint["port"] as? Int, 9900)

        let mode = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: storeURL.path)[.posixPermissions]) as? NSNumber).intValue
        XCTAssertEqual(mode & 0o777, 0o600)
        let repository = try DeviceRepository(applicationSupportDirectory: support)
        let devices = try await repository.listDevices()
        XCTAssertEqual(devices.count, 1)
        let device = try XCTUnwrap(devices.first)
        XCTAssertEqual(device.endpoint.url.absoluteString, "ws://127.0.0.1:9900/ws")
        let resolvedSecret = try await vault.resolve(device.credential)
        XCTAssertEqual(resolvedSecret, "fixture-loopback-secret")
    }
}

private actor MigrationCredentialVault: DeviceCredentialVault {
    private var values: [CredentialHandle: String] = [:]

    func store(_ secret: String, for handle: CredentialHandle) async throws { values[handle] = secret }
    func resolve(_ handle: CredentialHandle) async throws -> String? { values[handle] }
    func delete(_ handle: CredentialHandle) async throws { values.removeValue(forKey: handle) }
}
