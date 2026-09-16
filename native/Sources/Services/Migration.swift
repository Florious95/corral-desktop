import Foundation
import Darwin

private struct LegacyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

public enum LegacyDevicesFileError: Error, Equatable, Sendable {
    case notFound
    case unreadable
}

public protocol LegacyDevicesFileReader: Sendable {
    func read(from url: URL) throws -> Data
}

public struct FileManagerDevicesFileReader: LegacyDevicesFileReader, Sendable {
    public init() {}

    public func read(from url: URL) throws -> Data {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT {
                throw LegacyDevicesFileError.notFound
            }
            throw LegacyDevicesFileError.unreadable
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o777) == 0o600 else {
            throw LegacyDevicesFileError.unreadable
        }
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw LegacyDevicesFileError.unreadable
        }
    }
}

public enum MigrationResult: Equatable, Sendable {
    case migrated(deviceCount: Int)
    case alreadyMigrated
    case noLegacyFile
}

public enum MigrationError: Error, Equatable, Sendable {
    case storage
    case invalidLegacyData
    case verificationFailed
    case unsupportedMarker
}

/// Performs the one-shot legacy Tauri devices.json migration using only
/// private files. The source is never removed; malformed input or any write
/// failure leaves it byte-for-byte intact.
public actor DeviceMigration {
    public static let currentVersion = "devices-v1"
    public static let markerFileName = "devices.json.migration-v1"

    private static let markerData = Data(currentVersion.utf8)

    private let store: DeviceStore
    private let targetURL: URL
    private let markerURL: URL
    private let reader: any LegacyDevicesFileReader
    private let fileManager: FileManager

    public init(
        namespace: DeviceStoreNamespace = .currentApp,
        reader: any LegacyDevicesFileReader = FileManagerDevicesFileReader()
    ) {
        self.store = DeviceStore(namespace: namespace)
        self.targetURL = namespace.fileURL
        self.markerURL = namespace.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(Self.markerFileName, isDirectory: false)
        self.reader = reader
        self.fileManager = .default
    }

    public func migrate(from legacyURL: URL) async throws -> MigrationResult {
        if try checkMarker() {
            return .alreadyMigrated
        }

        let legacyData: Data
        do {
            legacyData = try reader.read(from: legacyURL)
        } catch let error as LegacyDevicesFileError {
            switch error {
            case .notFound:
                try writeMarker()
                return .noLegacyFile
            case .unreadable:
                throw MigrationError.invalidLegacyData
            }
        } catch {
            throw MigrationError.invalidLegacyData
        }

        let devices = try Self.decodeLegacyDevices(legacyData)
        do {
            let sourceIsExistingTarget = legacyURL.standardizedFileURL == targetURL
                && PrivateFileStore.pathExists(targetURL.path)
            if !sourceIsExistingTarget {
                try await store.save(devices)
            }
            guard try await store.load() == devices else {
                throw MigrationError.verificationFailed
            }
        } catch let error as MigrationError {
            throw error
        } catch is DeviceStoreError {
            throw MigrationError.storage
        } catch {
            throw MigrationError.verificationFailed
        }

        // Marker persistence is last. If it fails, a retry repeats an
        // idempotent write while the source remains available and untouched.
        try writeMarker()
        return .migrated(deviceCount: devices.count)
    }

    private func checkMarker() throws -> Bool {
        var info = stat()
        guard lstat(markerURL.path, &info) == 0 else {
            guard errno == ENOENT else { throw MigrationError.storage }
            return false
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o777) == 0o600 else {
            throw MigrationError.unsupportedMarker
        }
        do {
            let marker = try Data(contentsOf: markerURL, options: [.mappedIfSafe])
            guard marker == Self.markerData else {
                throw MigrationError.unsupportedMarker
            }
            return true
        } catch let error as MigrationError {
            throw error
        } catch {
            throw MigrationError.storage
        }
    }

    private func writeMarker() throws {
        do {
            try PrivateFileStore.writeAtomically(
                Self.markerData,
                to: markerURL,
                fileManager: fileManager
            )
        } catch {
            throw MigrationError.storage
        }
    }

    private static func decodeLegacyDevices(_ data: Data) throws -> [Device] {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(LegacyEnvelope.self, from: data).devices
        } catch {
            do {
                // Accept the original array form used by early native probes.
                return try decoder.decode([Device].self, from: data)
            } catch {
                throw MigrationError.invalidLegacyData
            }
        }
    }

    private struct LegacyEnvelope: Decodable {
        let devices: [Device]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case devices
        }

        init(from decoder: Decoder) throws {
            let allFields = try decoder.container(keyedBy: LegacyCodingKey.self)
            let expected = Set(CodingKeys.allCases.map(\.stringValue))
            let actual = Set(allFields.allKeys.map(\.stringValue))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard actual.isSubset(of: expected) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .devices,
                    in: container,
                    debugDescription: "legacy store contains unsupported fields"
                )
            }
            // Tauri creates an empty `{}` file before its store plugin first
            // persists a devices key. Treat that exact empty object as an
            // empty device list; every non-empty envelope still requires the
            // canonical devices array.
            devices = actual.isEmpty
                ? []
                : try container.decode([Device].self, forKey: .devices)
        }
    }
}
