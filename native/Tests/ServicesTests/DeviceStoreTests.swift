import Foundation
import XCTest
@testable import Services

final class DeviceStoreTests: XCTestCase {
    func testSaveLoadDeleteUsesOnlyWhitelistedFieldsAnd0600() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("devices.json")
        let store = DeviceStore(fileURL: file)
        let device = Device(id: "one", name: "Local", url: "ws://127.0.0.1:9900/ws", token: "")

        try await store.save([device])
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [device])
        XCTAssertEqual(try fileMode(file), 0o600)

        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let persistedDevices = try XCTUnwrap(persisted?["devices"] as? [[String: Any]])
        XCTAssertEqual(Set(persistedDevices[0].keys), ["id", "name", "url", "token"])

        try await store.delete()
        let afterDelete = try await store.load()
        XCTAssertEqual(afterDelete, [])
    }

    func testSaveRejectsInvalidDevicesAndDoesNotOverwriteExistingData() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceStore(fileURL: root.appendingPathComponent("devices.json"))
        let valid = Device(id: "one", name: "Remote", url: "wss://daemon.example/ws", token: "value")
        try await store.save([valid])

        let invalid = Device(id: "", name: "Remote", url: "wss://daemon.example/ws", token: "value")
        do {
            try await store.save([invalid])
            XCTFail("invalid device should be rejected")
        } catch {
            XCTAssertEqual(error as? DeviceStoreError, .invalidDevices)
        }
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [valid])
    }

    func testMalformedOrNonWhitelistedStoredJSONFailsClosed() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("devices.json")
        let store = DeviceStore(fileURL: file)

        try writePrivate(Data("not-json".utf8), to: file)
        do {
            _ = try await store.load()
            XCTFail("malformed store should be rejected")
        } catch {
            XCTAssertEqual(error as? DeviceStoreError, .invalidStoredData)
        }

        let extraField = #"{"devices":[{"id":"one","name":"Local","url":"ws://127.0.0.1:9900/ws","token":"","unexpected":true}]}"#
        try writePrivate(Data(extraField.utf8), to: file)
        do {
            _ = try await store.load()
            XCTFail("unknown device fields should be rejected")
        } catch {
            XCTAssertEqual(error as? DeviceStoreError, .invalidStoredData)
        }
    }

    func testConcurrentSavesAreSerializedAndLeaveOneCompleteList() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("devices.json")
        let store = DeviceStore(fileURL: file)
        let candidates = (0..<40).map { index in
            [Device(id: "device-\(index)", name: "Device \(index)", url: "wss://daemon.example/\(index)", token: "value-\(index)")]
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for devices in candidates {
                group.addTask { try await store.save(devices) }
            }
            try await group.waitForAll()
        }

        let result = try await store.load()
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(candidates.contains(result))
        XCTAssertEqual(try fileMode(file), 0o600)
    }

    func testSeparateFilesDoNotShareDeviceLists() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = DeviceStore(fileURL: root.appendingPathComponent("first/devices.json"))
        let second = DeviceStore(fileURL: root.appendingPathComponent("second/devices.json"))
        let device = Device(id: "one", name: "Local", url: "ws://localhost:9900/ws", token: "")

        try await first.save([device])
        let firstLoaded = try await first.load()
        let secondLoaded = try await second.load()
        XCTAssertEqual(firstLoaded, [device])
        XCTAssertEqual(secondLoaded, [])
    }

    func testPrepareCreatesPrivateEmptyStoreWithoutKeychain() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("nested/devices.json")
        let store = DeviceStore(fileURL: file)

        try await store.prepare()

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try fileMode(file), 0o600)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [])
    }

    func testLegacyArrayFormatRemainsReadable() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("devices.json")
        let store = DeviceStore(fileURL: file)
        let device = Device(id: "one", name: "Local", url: "ws://localhost:9900/ws", token: "")
        let data = try JSONEncoder().encode([device])
        try writePrivate(data, to: file)

        let loaded = try await store.load()
        XCTAssertEqual(loaded, [device])
    }

    func testPrepareTightensExistingFilePermissions() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("devices.json")
        let store = DeviceStore(fileURL: file)
        try await store.save([])
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: file.path)

        try await store.prepare()

        XCTAssertEqual(try fileMode(file), 0o600)
    }

    func testSymlinkStoreFailsClosed() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.json")
        let link = root.appendingPathComponent("devices.json")
        try writePrivate(Data(#"{"devices":[]}"#.utf8), to: outside)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let store = DeviceStore(fileURL: link)

        do {
            _ = try await store.load()
            XCTFail("symlink store should be rejected")
        } catch {
            XCTAssertEqual(error as? DeviceStoreError, .invalidStoredData)
        }
    }

    private func fixtureDirectory() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("device-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writePrivate(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(
            atPath: file.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw DeviceStoreError.io
        }
    }

    private func fileMode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}
