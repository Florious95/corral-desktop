import Foundation
import Darwin

/// The only persisted device fields. The custom Codable implementation rejects
/// unknown fields so secrets or UI state cannot silently enter the store.
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

/// Identity and location of the private on-disk device store.
///
/// The explicit URL keeps tests isolated and gives the app one private store.
public struct DeviceStoreNamespace: Equatable, Hashable, Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    public static var currentApp: DeviceStoreNamespace {
        DeviceStoreNamespace(fileURL: defaultFileURL(fileManager: .default))
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
        let bundleID = Bundle.main.bundleIdentifier ?? "com.agentmirror.desktop"
        return appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent(DeviceStore.fileName, isDirectory: false)
    }
}

public enum DeviceStoreError: Error, Equatable, Sendable {
    case invalidDevices
    case invalidStoredData
    case storage
}

/// Shared private-file primitives for devices.json and its migration marker.
/// All path inspection uses lstat, so symlinks are never followed as stores.
enum PrivateFileStore {
    static func pathExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func isPrivateRegularFile(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return (info.st_mode & 0o777) == 0o600
    }

    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func ensurePrivateDirectory(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        if pathExists(directory.path) {
            guard isDirectory(directory.path) else { throw DeviceStoreError.storage }
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
            return
        }

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        guard isDirectory(directory.path) else { throw DeviceStoreError.storage }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directory.path
        )
    }

    static func writeAtomically(
        _ data: Data,
        to fileURL: URL,
        fileManager: FileManager
    ) throws {
        let directory = fileURL.deletingLastPathComponent()
        try ensurePrivateDirectory(directory, fileManager: fileManager)

        let temporaryURL = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw DeviceStoreError.storage
        }

        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: temporaryURL.path
            )
            if pathExists(fileURL.path) {
                guard isRegular(fileURL.path) else { throw DeviceStoreError.storage }
                _ = try fileManager.replaceItemAt(
                    fileURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: fileURL.path
            )
            guard isPrivateRegularFile(fileURL.path) else {
                throw DeviceStoreError.storage
            }
        } catch let error as DeviceStoreError {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw DeviceStoreError.storage
        }
    }

    static func isRegular(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }
}

private struct DevicesEnvelope: Codable {
    let devices: [Device]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case devices
    }

    init(devices: [Device]) {
        self.devices = devices
    }

    init(from decoder: Decoder) throws {
        let allFields = try decoder.container(keyedBy: AnyCodingKey.self)
        let expected = Set(CodingKeys.allCases.map(\.stringValue))
        let actual = Set(allFields.allKeys.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard actual == expected else {
            throw DecodingError.dataCorruptedError(
                forKey: .devices,
                in: container,
                debugDescription: "device store contains unsupported fields"
            )
        }
        devices = try container.decode([Device].self, forKey: .devices)
    }
}

/// Actor-isolated device list backed solely by a private 0600 devices.json.
/// All writes use a temporary file and atomic replacement, so readers observe
/// either the old complete list or the new complete list.
public actor DeviceStore {
    public static let fileName = "devices.json"
    public static let shared = DeviceStore(namespace: .currentApp)

    public let namespace: DeviceStoreNamespace
    public let fileURL: URL
    private let fileManager: FileManager

    public init(
        namespace: DeviceStoreNamespace = .currentApp,
        fileManager: FileManager = .default
    ) {
        self.namespace = namespace
        self.fileURL = namespace.fileURL
        self.fileManager = fileManager
    }

    public init(
        fileURL: URL,
        fileManager: FileManager = .default
    ) {
        let namespace = DeviceStoreNamespace(fileURL: fileURL)
        self.namespace = namespace
        self.fileURL = namespace.fileURL
        self.fileManager = fileManager
    }

    public func loadDevices() throws -> [Device] {
        try load()
    }

    public func saveDevices(_ devices: [Device]) throws {
        try save(devices)
    }

    public func load() throws -> [Device] {
        guard PrivateFileStore.pathExists(fileURL.path) else { return [] }
        guard PrivateFileStore.isPrivateRegularFile(fileURL.path) else {
            throw DeviceStoreError.invalidStoredData
        }

        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            do {
                return try JSONDecoder().decode(DevicesEnvelope.self, from: data).devices
            } catch {
                // A very early native probe wrote a direct array. Continue to
                // accept it while all new writes use the Tauri envelope.
                return try JSONDecoder().decode([Device].self, from: data)
            }
        } catch let error as DeviceStoreError {
            throw error
        } catch {
            throw DeviceStoreError.invalidStoredData
        }
    }

    public func save(_ devices: [Device]) throws {
        guard devices.allSatisfy(Device.isValid) else {
            throw DeviceStoreError.invalidDevices
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(DevicesEnvelope(devices: devices))
            try PrivateFileStore.writeAtomically(data, to: fileURL, fileManager: fileManager)
        } catch let error as DeviceStoreError {
            throw error
        } catch {
            throw DeviceStoreError.storage
        }
    }

    public func delete() throws {
        guard PrivateFileStore.pathExists(fileURL.path) else { return }
        guard PrivateFileStore.isRegular(fileURL.path) else {
            throw DeviceStoreError.storage
        }
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            throw DeviceStoreError.storage
        }
    }
}
