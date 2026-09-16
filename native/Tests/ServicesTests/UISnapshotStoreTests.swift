import Foundation
import XCTest
@testable import Services

final class UISnapshotStoreTests: XCTestCase {
    func testSaveLoadUsesWhitelistedValuesAnd0600File() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(UISnapshotStore.fileName)
        let store = UISnapshotStore(fileURL: file)
        let snapshot: [String: Any] = [
            "am.workspace.v2": ["version": 2, "activeTabId": "tab-1"],
            "am.fav": ["space-a", "space-b"],
            "am.collapsed": true,
            "am.selected": "all",
        ]

        try store.save(snapshot)

        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded["am.collapsed"] as? Bool, true)
        XCTAssertEqual(loaded["am.selected"] as? String, "all")
        XCTAssertEqual(loaded["am.fav"] as? [String], ["space-a", "space-b"])
    }

    func testSaveAcceptsEmptySnapshot() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UISnapshotStore(fileURL: root.appendingPathComponent(UISnapshotStore.fileName))

        try store.save([:] as [String: Any])

        XCTAssertEqual(store.load()?.count, 0)
    }

    func testSaveAcceptsVersionedValuesEnvelope() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UISnapshotStore(fileURL: root.appendingPathComponent(UISnapshotStore.fileName))

        try store.save([
            "version": 1,
            "values": ["am.spacesOpen": false],
        ] as [String: Any])

        XCTAssertEqual(store.load()?["am.spacesOpen"] as? Bool, false)
    }

    func testSaveRejectsUnknownAndSensitiveFieldsIncludingNested() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UISnapshotStore(fileURL: root.appendingPathComponent(UISnapshotStore.fileName))

        XCTAssertThrowsError(try store.save(["am.unknown": true])) { error in
            XCTAssertEqual(error as? UISnapshotError, .invalidSnapshot)
        }
        XCTAssertThrowsError(try store.save(["token": "must-not-persist"])) { error in
            XCTAssertEqual(error as? UISnapshotError, .sensitiveField)
        }
        XCTAssertThrowsError(try store.save([
            "am.workspace.v2": ["api_key": "must-not-persist"],
        ])) { error in
            XCTAssertEqual(error as? UISnapshotError, .sensitiveField)
        }
    }

    func testLoadFailsClosedForMissingMalformedOrNonPrivateFile() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(UISnapshotStore.fileName)
        let store = UISnapshotStore(fileURL: file)

        XCTAssertNil(store.load())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: file.path)
        XCTAssertNil(store.load())

        try store.save(["am.collapsed": true])
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: file.path)
        XCTAssertNil(store.load())
    }

    func testSaveRejectsOversizedSnapshot() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UISnapshotStore(fileURL: root.appendingPathComponent(UISnapshotStore.fileName))
        let oversized = String(repeating: "x", count: UISnapshotStore.maxBytes)

        XCTAssertThrowsError(try store.save(["am.selected": oversized])) { error in
            XCTAssertEqual(error as? UISnapshotError, .tooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    private func fixtureDirectory() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("ui-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
