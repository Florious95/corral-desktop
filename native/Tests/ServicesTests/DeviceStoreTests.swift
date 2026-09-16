import Foundation
import XCTest
@testable import Services

final class DeviceStoreTests: XCTestCase {
    func testSaveLoadDeleteUsesOnlyWhitelistedFields() async throws {
        let keychain = InMemoryKeychain()
        let storeNamespace = namespace("store")
        let store = DeviceStore(namespace: storeNamespace, keychain: keychain)
        let device = Device(id: "one", name: "Local", url: "ws://127.0.0.1:9900/ws", token: "")

        try await store.save([device])
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [device])

        let persisted = try XCTUnwrap(keychain.data(for: storeNamespace))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: persisted) as? [[String: Any]])
        XCTAssertEqual(Set(object[0].keys), ["id", "name", "url", "token"])

        try await store.delete()
        let afterDelete = try await store.load()
        XCTAssertEqual(afterDelete, [])
        XCTAssertTrue(keychain.operations.contains(.delete))
    }

    func testSaveRejectsInvalidDevicesAndDoesNotOverwriteExistingData() async throws {
        let keychain = InMemoryKeychain()
        let store = DeviceStore(namespace: namespace("validation"), keychain: keychain)
        let valid = Device(id: "one", name: "Remote", url: "wss://daemon.example/ws", token: "token")
        try await store.save([valid])

        let invalid = Device(id: "", name: "Remote", url: "wss://daemon.example/ws", token: "token")
        await XCTAssertThrowsErrorAsync(try await store.save([invalid])) { error in
            XCTAssertEqual(error as? DeviceStoreError, .invalidDevices)
        }
        let remoteWithoutToken = Device(id: "two", name: "Remote", url: "wss://daemon.example/ws", token: "")
        await XCTAssertThrowsErrorAsync(try await store.save([remoteWithoutToken])) { error in
            XCTAssertEqual(error as? DeviceStoreError, .invalidDevices)
        }
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [valid])
    }

    func testMalformedOrNonWhitelistedStoredJSONFailsClosed() async throws {
        let keychain = InMemoryKeychain()
        let storeNamespace = namespace("malformed")
        let store = DeviceStore(namespace: storeNamespace, keychain: keychain)

        keychain.setData(Data("not-json".utf8), for: storeNamespace)
        await XCTAssertThrowsErrorAsync(try await store.load()) { error in
            XCTAssertEqual(error as? DeviceStoreError, .invalidStoredData)
        }

        let extraField = #"[{"id":"one","name":"Local","url":"ws://127.0.0.1:9900/ws","token":"","unexpected":true}]"#
        keychain.setData(Data(extraField.utf8), for: storeNamespace)
        await XCTAssertThrowsErrorAsync(try await store.load()) { error in
            XCTAssertEqual(error as? DeviceStoreError, .invalidStoredData)
        }
    }

    func testConcurrentSavesAreSerializedAndLeaveOneCompleteList() async throws {
        let keychain = InMemoryKeychain()
        let store = DeviceStore(namespace: namespace("concurrent"), keychain: keychain)
        let candidates = (0..<40).map { index in
            [Device(id: "device-\(index)", name: "Device \(index)", url: "wss://daemon.example/\(index)", token: "token-\(index)")]
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for devices in candidates {
                group.addTask {
                    try await store.save(devices)
                }
            }
            try await group.waitForAll()
        }

        let result = try await store.load()
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(candidates.contains(result))
    }

    func testNamespacesDoNotShareKeychainItems() async throws {
        let keychain = InMemoryKeychain()
        let first = DeviceStore(namespace: namespace("first"), keychain: keychain)
        let second = DeviceStore(namespace: namespace("second"), keychain: keychain)
        let device = Device(id: "one", name: "Local", url: "ws://localhost:9900/ws", token: "")

        try await first.save([device])
        let firstLoaded = try await first.load()
        let secondLoaded = try await second.load()
        XCTAssertEqual(firstLoaded, [device])
        XCTAssertEqual(secondLoaded, [])
    }

    func testSystemKeychainCRUDUsesAnIsolatedNamespace() throws {
        let namespace = KeychainNamespace(
            service: "com.agentmirror.tests.\(UUID().uuidString)",
            account: "devices"
        )
        let keychain = SystemKeychain()
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        defer { try? keychain.delete(namespace: namespace) }

        XCTAssertNil(try keychain.copyMatching(namespace: namespace))
        try keychain.add(data: first, namespace: namespace)
        XCTAssertEqual(try keychain.copyMatching(namespace: namespace), first)
        try keychain.update(data: second, namespace: namespace)
        XCTAssertEqual(try keychain.copyMatching(namespace: namespace), second)
        try keychain.delete(namespace: namespace)
        XCTAssertNil(try keychain.copyMatching(namespace: namespace))
    }

    func testMigrationCopiesLegacyEnvelopeLeavesSourceAndMarksVersion() async throws {
        let keychain = InMemoryKeychain()
        let namespace = namespace("migration")
        let devices = [Device(id: "one", name: "Remote", url: "wss://daemon.example/ws", token: "secret")]
        let source = Data(#"{"devices":[{"id":"one","name":"Remote","url":"wss://daemon.example/ws","token":"secret"}],"other":true}"#.utf8)
        let reader = StaticReader(result: .success(source))
        let migration = DeviceMigration(namespace: namespace, keychain: keychain, reader: reader)

        let result = try await migration.migrate(from: legacyURL())
        XCTAssertEqual(result, .migrated(deviceCount: 1))
        let store = DeviceStore(namespace: namespace, keychain: keychain)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, devices)
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertEqual(reader.lastData, source)
        let secondResult = try await migration.migrate(from: legacyURL())
        XCTAssertEqual(secondResult, .alreadyMigrated)
        XCTAssertEqual(reader.readCount, 1)

        let markerNamespace = KeychainNamespace(service: namespace.service, account: "migration-devices-v1")
        XCTAssertEqual(keychain.data(for: markerNamespace), Data("devices-v1".utf8))
    }

    func testMalformedMigrationPreservesSourceAndDoesNotWriteDevices() async throws {
        let keychain = InMemoryKeychain()
        let namespace = namespace("bad-migration")
        let source = Data(#"{"devices":[{"id":"one","name":7,"url":"wss://daemon.example/ws","token":"secret"}]}"#.utf8)
        let reader = StaticReader(result: .success(source))
        let migration = DeviceMigration(namespace: namespace, keychain: keychain, reader: reader)

        await XCTAssertThrowsErrorAsync(try await migration.migrate(from: legacyURL())) { error in
            XCTAssertEqual(error as? MigrationError, .invalidLegacyData)
        }
        let store = DeviceStore(namespace: namespace, keychain: keychain)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [])
        XCTAssertEqual(reader.lastData, source)
        let markerNamespace = KeychainNamespace(service: namespace.service, account: "migration-devices-v1")
        XCTAssertNil(keychain.data(for: markerNamespace))
    }

    func testFailedMigrationLeavesReal0600SourceUntouched() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("s1-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("devices.json")
        let source = Data(#"{"devices":[{"id":"one","name":"Remote","url":"wss://daemon.example/ws","token":"secret"}]}"#.utf8)
        try source.write(to: sourceURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceURL.path)
        let beforeMode = try fileMode(sourceURL)

        let keychain = InMemoryKeychain()
        keychain.failure(for: .add, is: KeychainError.status(Int32(errSecAuthFailed)))
        let namespace = namespace("failed-file-migration")
        let migration = DeviceMigration(namespace: namespace, keychain: keychain, reader: FileManagerDevicesFileReader())

        await XCTAssertThrowsErrorAsync(try await migration.migrate(from: sourceURL)) { error in
            XCTAssertEqual(error as? MigrationError, .keychain(.status(Int32(errSecAuthFailed))))
        }
        XCTAssertEqual(try Data(contentsOf: sourceURL), source)
        XCTAssertEqual(try fileMode(sourceURL), beforeMode)
    }

    func testMissingSourceMarksMigrationWithoutCreatingEmptyDeviceOverwrite() async throws {
        let keychain = InMemoryKeychain()
        let namespace = namespace("missing")
        let existing = [Device(id: "one", name: "Remote", url: "wss://daemon.example/ws", token: "token")]
        let existingStore = DeviceStore(namespace: namespace, keychain: keychain)
        try await existingStore.save(existing)
        let migration = DeviceMigration(
            namespace: namespace,
            keychain: keychain,
            reader: StaticReader(result: .failure(.notFound))
        )

        let result = try await migration.migrate(from: legacyURL())
        XCTAssertEqual(result, .noLegacyFile)
        let loaded = try await existingStore.load()
        XCTAssertEqual(loaded, existing)
        let secondResult = try await migration.migrate(from: legacyURL())
        XCTAssertEqual(secondResult, .alreadyMigrated)
    }

    private func namespace(_ label: String) -> KeychainNamespace {
        KeychainNamespace(service: "com.agentmirror.tests.\(label).\(UUID().uuidString)", account: "devices")
    }

    private func legacyURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("devices.json")
    }

    private func fileMode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}

private final class InMemoryKeychain: KeychainClient, @unchecked Sendable {
    enum Operation: Hashable {
        case copyMatching
        case add
        case update
        case delete
    }

    private let lock = NSLock()
    private var values: [KeychainNamespace: Data] = [:]
    private var failures: [Operation: KeychainError] = [:]
    private(set) var operations: [Operation] = []

    func copyMatching(namespace: KeychainNamespace) throws -> Data? {
        try withLock {
            operations.append(.copyMatching)
            try failIfConfigured(.copyMatching)
            return values[namespace]
        }
    }

    func add(data: Data, namespace: KeychainNamespace) throws {
        try withLock {
            operations.append(.add)
            try failIfConfigured(.add)
            guard values[namespace] == nil else {
                throw KeychainError.status(Int32(errSecDuplicateItem))
            }
            values[namespace] = data
        }
    }

    func update(data: Data, namespace: KeychainNamespace) throws {
        try withLock {
            operations.append(.update)
            try failIfConfigured(.update)
            guard values[namespace] != nil else {
                throw KeychainError.status(Int32(errSecItemNotFound))
            }
            values[namespace] = data
        }
    }

    func delete(namespace: KeychainNamespace) throws {
        try withLock {
            operations.append(.delete)
            try failIfConfigured(.delete)
            guard values.removeValue(forKey: namespace) != nil else {
                throw KeychainError.status(Int32(errSecItemNotFound))
            }
        }
    }

    func setData(_ data: Data, for namespace: KeychainNamespace) {
        withLock {
            values[namespace] = data
        }
    }

    func data(for namespace: KeychainNamespace) -> Data? {
        withLock { values[namespace] }
    }

    func failure(for operation: Operation, is error: KeychainError) {
        withLock { failures[operation] = error }
    }

    private func failIfConfigured(_ operation: Operation) throws {
        if let error = failures.removeValue(forKey: operation) {
            throw error
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private final class StaticReader: LegacyDevicesFileReader, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<Data, LegacyDevicesFileError>
    private(set) var readCount = 0
    private(set) var lastData: Data?

    init(result: Result<Data, LegacyDevicesFileError>) {
        self.result = result
    }

    func read(from url: URL) throws -> Data {
        lock.lock()
        readCount += 1
        defer { lock.unlock() }
        switch result {
        case let .success(data):
            lastData = data
            return data
        case let .failure(error):
            throw error
        }
    }
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
