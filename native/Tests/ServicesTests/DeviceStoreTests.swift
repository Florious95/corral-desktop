import Foundation
import Darwin
import XCTest
@testable import Services

final class DeviceStoreTests: XCTestCase {
    func testSaveLoadDeleteUsesOnlyWhitelistedFieldsAnd0600File() async throws {
        let fixture = Fixture()
        let fileURL = fixture.directory.appendingPathComponent("devices.json")
        let store = DeviceStore(fileURL: fileURL)
        let device = Device(
            id: "one",
            name: "Local",
            url: "ws://127.0.0.1:9900/ws",
            token: "token-value"
        )

        try await store.save([device])

        let loaded = try await store.load()
        XCTAssertEqual(loaded, [device])
        XCTAssertEqual(fileMode(fileURL), 0o600)
        XCTAssertEqual(fileMode(fixture.directory), 0o700)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["devices"])
        let encodedDevice = try XCTUnwrap(
            (object["devices"] as? [[String: Any]])?.first
        )
        XCTAssertEqual(Set(encodedDevice.keys), ["id", "name", "url", "token"])

        try await store.delete()
        let loadedAfterDelete = try await store.load()
        XCTAssertEqual(loadedAfterDelete, [])
    }

    func testMissingFileLoadsAsEmptyAndSeparateURLsAreIsolated() async throws {
        let fixture = Fixture()
        let first = DeviceStore(fileURL: fixture.directory.appendingPathComponent("one.json"))
        let second = DeviceStore(fileURL: fixture.directory.appendingPathComponent("two.json"))
        let device = Device(id: "one", name: "Local", url: "ws://localhost:9900/ws", token: "")

        let initial = try await first.load()
        XCTAssertEqual(initial, [])
        try await first.save([device])
        let firstLoaded = try await first.load()
        let secondLoaded = try await second.load()
        XCTAssertEqual(firstLoaded, [device])
        XCTAssertEqual(secondLoaded, [])
    }

    func testInvalidDevicesAreRejectedBeforeAnyWrite() async throws {
        let fixture = Fixture()
        let fileURL = fixture.directory.appendingPathComponent("devices.json")
        let store = DeviceStore(fileURL: fileURL)
        let valid = Device(id: "one", name: "Local", url: "ws://localhost:9900/ws", token: "")
        try await store.save([valid])
        let before = try Data(contentsOf: fileURL)

        let invalid = Device(id: "", name: "Local", url: "ws://localhost:9900/ws", token: "")
        await XCTAssertThrowsErrorAsync(try await store.save([invalid])) { error in
            XCTAssertEqual(error as? DeviceStoreError, .invalidDevices)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
    }

    func testMalformedAndUnknownFieldsFailClosed() async throws {
        let fixture = Fixture()
        let fileURL = fixture.directory.appendingPathComponent("devices.json")
        let store = DeviceStore(fileURL: fileURL)

        let malformedInputs = [
            Data(#"{"# .utf8),
            Data(#"{"devices":[],"other":true}"#.utf8),
            Data(#"{"devices":[{"id":"one","name":"Local","url":"ws://localhost:1","token":"","other":true}]}"#.utf8),
        ]
        for input in malformedInputs {
            try write0600(input, to: fileURL)
            await XCTAssertThrowsErrorAsync(try await store.load()) { error in
                XCTAssertEqual(error as? DeviceStoreError, .invalidStoredData)
            }
        }
    }

    func testNonPrivateFileFailsClosed() async throws {
        let fixture = Fixture()
        let fileURL = fixture.directory.appendingPathComponent("devices.json")
        let store = DeviceStore(fileURL: fileURL)
        try write0600(Data(#"{"devices":[]}"#.utf8), to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: fileURL.path
        )

        await XCTAssertThrowsErrorAsync(try await store.load()) { error in
            XCTAssertEqual(error as? DeviceStoreError, .invalidStoredData)
        }
    }

    func testSymlinkFailsClosed() async throws {
        let fixture = Fixture()
        let target = fixture.directory.appendingPathComponent("target.json")
        let link = fixture.directory.appendingPathComponent("devices.json")
        try write0600(Data(#"{"devices":[]}"#.utf8), to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = DeviceStore(fileURL: link)

        await XCTAssertThrowsErrorAsync(try await store.load()) { error in
            XCTAssertEqual(error as? DeviceStoreError, .invalidStoredData)
        }
    }

    func testConcurrentActorSavesLeaveOneCompleteCandidate() async throws {
        let fixture = Fixture()
        let store = DeviceStore(fileURL: fixture.directory.appendingPathComponent("devices.json"))
        let candidates = (0..<12).map { index in
            [Device(
                id: "device-\(index)",
                name: "Device \(index)",
                url: "ws://localhost:\(9900 + index)/ws",
                token: ""
            )]
        }

        await withTaskGroup(of: Void.self) { group in
            for candidate in candidates {
                group.addTask {
                    try? await store.save(candidate)
                }
            }
        }

        let loaded = try await store.load()
        XCTAssertTrue(candidates.contains(loaded))
        XCTAssertEqual(fileMode(fixture.directory.appendingPathComponent("devices.json")), 0o600)
    }

    func testMigrationPreservesDistinctSourceAndWritesMarker() async throws {
        let fixture = Fixture()
        let sourceURL = fixture.directory.appendingPathComponent("legacy-devices.json")
        let targetURL = fixture.directory
            .appendingPathComponent("native", isDirectory: true)
            .appendingPathComponent("devices.json")
        let source = Data(#"{"devices":[{"id":"one","name":"Remote","url":"wss://daemon.example/ws","token":"legacy-token"}]}"#.utf8)
        try write0600(source, to: sourceURL)
        let migration = DeviceMigration(
            namespace: DeviceStoreNamespace(fileURL: targetURL),
            reader: FileManagerDevicesFileReader()
        )

        let migrationResult = try await migration.migrate(from: sourceURL)
        XCTAssertEqual(migrationResult, .migrated(deviceCount: 1))
        XCTAssertEqual(try Data(contentsOf: sourceURL), source)
        XCTAssertEqual(fileMode(sourceURL), 0o600)
        let store = DeviceStore(fileURL: targetURL)
        let loaded = try await store.load()
        XCTAssertEqual(
            loaded,
            [Device(id: "one", name: "Remote", url: "wss://daemon.example/ws", token: "legacy-token")]
        )
        let markerURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent(DeviceMigration.markerFileName)
        XCTAssertEqual(try Data(contentsOf: markerURL), Data(DeviceMigration.currentVersion.utf8))
        XCTAssertEqual(fileMode(markerURL), 0o600)
        let secondResult = try await migration.migrate(from: sourceURL)
        XCTAssertEqual(secondResult, .alreadyMigrated)
    }

    func testMigrationAcceptsEmptyTauriStoreObject() async throws {
        let fixture = Fixture()
        let sourceURL = fixture.directory.appendingPathComponent("legacy-devices.json")
        let targetURL = fixture.directory.appendingPathComponent("target/devices.json")
        let source = Data("{}".utf8)
        try write0600(source, to: sourceURL)

        let migration = DeviceMigration(namespace: DeviceStoreNamespace(fileURL: targetURL))
        let migrationResult = try await migration.migrate(from: sourceURL)
        XCTAssertEqual(migrationResult, .migrated(deviceCount: 0))
        let loaded = try await DeviceStore(fileURL: targetURL).load()
        XCTAssertEqual(loaded, [])
        XCTAssertEqual(try Data(contentsOf: sourceURL), source)
    }

    func testMigrationSupportsSourceAtTargetAndKeepsLogicalDevices() async throws {
        let fixture = Fixture()
        let targetURL = fixture.directory.appendingPathComponent("devices.json")
        let source = Data(#"{"devices":[{"id":"one","name":"Local","url":"ws://localhost:9900/ws","token":""}]}"#.utf8)
        try write0600(source, to: targetURL)
        let migration = DeviceMigration(
            namespace: DeviceStoreNamespace(fileURL: targetURL),
            reader: FileManagerDevicesFileReader()
        )

        let migrationResult = try await migration.migrate(from: targetURL)
        XCTAssertEqual(migrationResult, .migrated(deviceCount: 1))
        XCTAssertEqual(try Data(contentsOf: targetURL), source)
        let loaded = try await DeviceStore(fileURL: targetURL).load()
        XCTAssertEqual(
            loaded,
            [Device(id: "one", name: "Local", url: "ws://localhost:9900/ws", token: "")]
        )
        XCTAssertEqual(fileMode(targetURL), 0o600)
    }

    func testMalformedMigrationLeavesSourceUntouchedAndWritesNoMarker() async throws {
        let fixture = Fixture()
        let sourceURL = fixture.directory.appendingPathComponent("legacy-devices.json")
        let targetURL = fixture.directory.appendingPathComponent("target/devices.json")
        let source = Data(#"{"devices":[{"id":"one","name":7,"url":"ws://localhost:1","token":""}]}"#.utf8)
        try write0600(source, to: sourceURL)
        let sourceMode = fileMode(sourceURL)
        let migration = DeviceMigration(
            namespace: DeviceStoreNamespace(fileURL: targetURL),
            reader: FileManagerDevicesFileReader()
        )

        await XCTAssertThrowsErrorAsync(try await migration.migrate(from: sourceURL)) { error in
            XCTAssertEqual(error as? MigrationError, .invalidLegacyData)
        }
        XCTAssertEqual(try Data(contentsOf: sourceURL), source)
        XCTAssertEqual(fileMode(sourceURL), sourceMode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: targetURL.deletingLastPathComponent()
                .appendingPathComponent(DeviceMigration.markerFileName).path
        ))
    }

    func testMigrationMissingSourceOnlyWritesMarker() async throws {
        let fixture = Fixture()
        let targetURL = fixture.directory.appendingPathComponent("target/devices.json")
        let missingURL = fixture.directory.appendingPathComponent("missing.json")
        let migration = DeviceMigration(namespace: DeviceStoreNamespace(fileURL: targetURL))

        let migrationResult = try await migration.migrate(from: missingURL)
        XCTAssertEqual(migrationResult, .noLegacyFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
        let markerURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent(DeviceMigration.markerFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertEqual(fileMode(markerURL), 0o600)
    }

    func testMigrationRejectsInvalidMarker() async throws {
        let fixture = Fixture()
        let targetURL = fixture.directory.appendingPathComponent("target/devices.json")
        let markerURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent(DeviceMigration.markerFileName)
        try write0600(Data("wrong-version".utf8), to: markerURL)
        let migration = DeviceMigration(namespace: DeviceStoreNamespace(fileURL: targetURL))

        await XCTAssertThrowsErrorAsync(try await migration.migrate(from: fixture.directory.appendingPathComponent("missing.json"))) { error in
            XCTAssertEqual(error as? MigrationError, .unsupportedMarker)
        }
    }
}

private final class Fixture {
    let directory: URL

    init() {
        directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("device-store-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func write0600(_ data: Data, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    guard FileManager.default.createFile(
        atPath: url.path,
        contents: data,
        attributes: [.posixPermissions: NSNumber(value: 0o600)]
    ) else {
        throw NSError(domain: "DeviceStoreTests", code: 1)
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: url.path
    )
}

private func fileMode(_ url: URL) -> Int {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return -1 }
    return Int(info.st_mode & 0o777)
}

private func XCTAssertThrowsErrorAsync<T: Sendable>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error")
    } catch {
        handler(error)
    }
}
