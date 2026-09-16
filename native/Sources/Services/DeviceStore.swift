import Foundation
import Darwin

/// The only persisted device fields. Unknown fields and invalid device values
/// are rejected so credentials cannot be smuggled into the store.
private struct AnyCodingKey: CodingKey {
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

public struct Device: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let url: String
    public let token: String

    public init(id: String, name: String, url: String, token: String) {
        self.id = id
        self.name = name
        self.url = url
        self.token = token
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case name
        case url
        case token
    }

    public init(from decoder: Decoder) throws {
        let allFields = try decoder.container(keyedBy: AnyCodingKey.self)
        let expected = Set(CodingKeys.allCases.map(\.stringValue))
        let actual = Set(allFields.allKeys.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard actual == expected else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "device contains unsupported fields"
            )
        }

        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            url: try container.decode(String.self, forKey: .url),
            token: try container.decode(String.self, forKey: .token)
        )
        guard Self.isValid(self) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "device does not satisfy the schema"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(token, forKey: .token)
    }

    static func isValid(_ device: Device) -> Bool {
        guard !device.id.isEmpty, !device.name.isEmpty, !device.url.isEmpty else {
            return false
        }
        return !device.token.isEmpty || isLoopbackURL(device.url)
    }

    static func isLoopbackURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let host = url.host?.lowercased() else {
            return false
        }
        return host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host == "[::1]"
    }
}

public enum DeviceStoreError: Error, Equatable, Sendable {
    case invalidDevices
    case invalidStoredData
    case io
}

/// Atomic, actor-isolated device storage. The file is private to the current
/// app user (0600) and lives alongside the former Tauri devices.json path.
public actor DeviceStore {
    public static let fileName = "devices.json"
    public static let shared = DeviceStore(fileURL: DeviceStore.defaultFileURL())

    public let fileURL: URL
    private let fileManager: FileManager

    public init(
        fileURL: URL = DeviceStore.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
        let bundleID = Bundle.main.bundleIdentifier ?? "com.agentmirror.desktop.test"
        return appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Ensure the existing Tauri-compatible path is a regular 0600 file. A
    /// missing store is initialized with an empty device envelope. Symlinks
    /// and other special files fail closed rather than being followed.
    public func prepare() throws {
        if Self.lstatInfo(atPath: fileURL.path) == nil {
            guard errno == ENOENT else { throw DeviceStoreError.io }
            try writeAtomically(Self.encodeEnvelope([]))
            return
        }
        guard Self.isRegularFile(atPath: fileURL.path) else {
            throw DeviceStoreError.invalidStoredData
        }
        try setPrivatePermissions()
    }

    public func loadDevices() throws -> [Device] {
        try load()
    }

    public func saveDevices(_ devices: [Device]) throws {
        try save(devices)
    }

    public func load() throws -> [Device] {
        try prepare()
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw DeviceStoreError.io
        }

        do {
            // plugin-store's existing representation is an object envelope.
            return try JSONDecoder().decode(DeviceEnvelope.self, from: data).devices
        } catch {
            do {
                // Keep compatibility with early snapshots that stored an array.
                return try JSONDecoder().decode([Device].self, from: data)
            } catch {
                throw DeviceStoreError.invalidStoredData
            }
        }
    }

    public func save(_ devices: [Device]) throws {
        guard devices.allSatisfy(Device.isValid) else {
            throw DeviceStoreError.invalidDevices
        }
        try prepare()
        try writeAtomically(Self.encodeEnvelope(devices))
    }

    public func delete() throws {
        guard Self.lstatInfo(atPath: fileURL.path) != nil else {
            guard errno == ENOENT else { throw DeviceStoreError.io }
            return
        }
        guard Self.isRegularFile(atPath: fileURL.path) else {
            throw DeviceStoreError.invalidStoredData
        }
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            throw DeviceStoreError.io
        }
    }

    private func setPrivatePermissions() throws {
        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw DeviceStoreError.io
        }
    }

    private func writeAtomically(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            let temporaryURL = directory.appendingPathComponent(
                ".\(Self.fileName).\(UUID().uuidString).tmp",
                isDirectory: false
            )
            guard fileManager.createFile(
                atPath: temporaryURL.path,
                contents: data,
                attributes: [.posixPermissions: NSNumber(value: 0o600)]
            ) else {
                throw DeviceStoreError.io
            }
            do {
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)],
                    ofItemAtPath: temporaryURL.path
                )
                if Self.lstatInfo(atPath: fileURL.path) != nil {
                    guard Self.isRegularFile(atPath: fileURL.path) else {
                        throw DeviceStoreError.invalidStoredData
                    }
                    _ = try fileManager.replaceItemAt(
                        fileURL,
                        withItemAt: temporaryURL,
                        backupItemName: nil,
                        options: .usingNewMetadataOnly
                    )
                } else {
                    guard errno == ENOENT else { throw DeviceStoreError.io }
                    try fileManager.moveItem(at: temporaryURL, to: fileURL)
                }
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                throw error
            }
        } catch let error as DeviceStoreError {
            throw error
        } catch {
            throw DeviceStoreError.io
        }
    }

    private static func encodeEnvelope(_ devices: [Device]) throws -> Data {
        do {
            return try JSONEncoder().encode(DeviceEnvelope(devices: devices))
        } catch {
            throw DeviceStoreError.io
        }
    }

    private static func lstatInfo(atPath path: String) -> stat? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info
    }

    private static func isRegularFile(atPath path: String) -> Bool {
        guard let info = lstatInfo(atPath: path) else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }
}

private struct DeviceEnvelope: Codable {
    let devices: [Device]

    init(devices: [Device]) {
        self.devices = devices
    }

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
