import Foundation
import Security

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
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            throw LegacyDevicesFileError.notFound
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
    case keychain(KeychainError)
    case invalidLegacyData
    case verificationFailed
    case unsupportedMarker
}

/// Copies the legacy Tauri store into Keychain without modifying the source
/// file. A separate non-secret Keychain item makes the operation one-shot.
public actor DeviceMigration {
    public static let currentVersion = "devices-v1"

    private static let markerAccount = "migration-devices-v1"
    private static let markerData = Data(currentVersion.utf8)

    private let store: DeviceStore
    private let keychain: any KeychainClient
    private let markerNamespace: KeychainNamespace
    private let reader: any LegacyDevicesFileReader

    public init(
        namespace: KeychainNamespace = .currentApp,
        keychain: any KeychainClient = SystemKeychain(),
        reader: any LegacyDevicesFileReader = FileManagerDevicesFileReader()
    ) {
        self.store = DeviceStore(namespace: namespace, keychain: keychain)
        self.keychain = keychain
        self.markerNamespace = KeychainNamespace(
            service: namespace.service,
            account: Self.markerAccount,
            accessGroup: namespace.accessGroup
        )
        self.reader = reader
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
            try await store.save(devices)
            guard try await store.load() == devices else {
                throw MigrationError.verificationFailed
            }
        } catch let error as MigrationError {
            throw error
        } catch let error as DeviceStoreError {
            if case let .keychain(keychainError) = error {
                throw MigrationError.keychain(keychainError)
            }
            throw MigrationError.invalidLegacyData
        } catch {
            throw MigrationError.verificationFailed
        }

        // The source is deliberately left untouched. If marker persistence
        // fails, a later run safely repeats the idempotent Keychain write.
        try writeMarker()
        return .migrated(deviceCount: devices.count)
    }

    private func checkMarker() throws -> Bool {
        do {
            guard let marker = try keychain.copyMatching(namespace: markerNamespace) else {
                return false
            }
            guard marker == Self.markerData else {
                throw MigrationError.unsupportedMarker
            }
            return true
        } catch let error as MigrationError {
            throw error
        } catch let error as KeychainError {
            throw MigrationError.keychain(error)
        } catch {
            throw MigrationError.keychain(.invalidResult)
        }
    }

    private func writeMarker() throws {
        do {
            try keychain.update(data: Self.markerData, namespace: markerNamespace)
        } catch let error as KeychainError where error.statusCode == Int32(errSecItemNotFound) {
            do {
                try keychain.add(data: Self.markerData, namespace: markerNamespace)
            } catch let addError as KeychainError where addError.statusCode == Int32(errSecDuplicateItem) {
                do {
                    try keychain.update(data: Self.markerData, namespace: markerNamespace)
                } catch let updateError as KeychainError {
                    throw MigrationError.keychain(updateError)
                } catch {
                    throw MigrationError.keychain(.invalidResult)
                }
            } catch let addError as KeychainError {
                throw MigrationError.keychain(addError)
            } catch {
                throw MigrationError.keychain(.invalidResult)
            }
        } catch let error as KeychainError {
            throw MigrationError.keychain(error)
        } catch {
            throw MigrationError.keychain(.invalidResult)
        }
    }

    private static func decodeLegacyDevices(_ data: Data) throws -> [Device] {
        let decoder = JSONDecoder()
        do {
            // Tauri plugin-store writes an object whose `devices` value is the
            // array. Other plugin keys are intentionally ignored.
            let envelope = try decoder.decode(LegacyEnvelope.self, from: data)
            return envelope.devices
        } catch {
            do {
                // Accept the original array form as well for older snapshots.
                return try decoder.decode([Device].self, from: data)
            } catch {
                throw MigrationError.invalidLegacyData
            }
        }
    }

    private struct LegacyEnvelope: Decodable {
        let devices: [Device]

        private enum CodingKeys: String, CodingKey {
            case devices
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            devices = container.contains(.devices)
                ? try container.decode([Device].self, forKey: .devices)
                : []
        }
    }
}
