import Foundation
import Security

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

public struct KeychainNamespace: Equatable, Hashable, Sendable {
    public let service: String
    public let account: String
    public let accessGroup: String?

    public init(service: String, account: String, accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public static let production = KeychainNamespace(
        service: "com.agentmirror.desktop.devices.v1",
        account: "device-list"
    )

    /// Keep command-line probes and isolated test bundles from reading the
    /// production Keychain item. Only the signed release bundle gets the
    /// historical production service name.
    public static var currentApp: KeychainNamespace {
        guard Bundle.main.bundleIdentifier == "com.agentmirror.desktop" else {
            return KeychainNamespace(
                service: "com.agentmirror.desktop.test.devices.v1",
                account: "device-list"
            )
        }
        return .production
    }
}

public enum KeychainError: Error, Equatable, Sendable {
    case status(Int32)
    case invalidResult

    var statusCode: Int32? {
        guard case let .status(value) = self else { return nil }
        return value
    }
}

/// Narrow abstraction used by DeviceStore and Migration. Production uses the
/// Security framework; tests inject an isolated in-memory implementation.
public protocol KeychainClient: Sendable {
    func copyMatching(namespace: KeychainNamespace) throws -> Data?
    func add(data: Data, namespace: KeychainNamespace) throws
    func update(data: Data, namespace: KeychainNamespace) throws
    func delete(namespace: KeychainNamespace) throws
}

/// Security.framework-backed generic-password storage. The keychain item is
/// device-only and is not synchronizable to iCloud.
public final class SystemKeychain: KeychainClient, @unchecked Sendable {
    public init() {}

    public func copyMatching(namespace: KeychainNamespace) throws -> Data? {
        var query = baseQuery(namespace)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = result as? Data else { throw KeychainError.invalidResult }
        return data
    }

    public func add(data: Data, namespace: KeychainNamespace) throws {
        var attributes = baseQuery(namespace)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func update(data: Data, namespace: KeychainNamespace) throws {
        let query = baseQuery(namespace)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func delete(namespace: KeychainNamespace) throws {
        let status = SecItemDelete(baseQuery(namespace) as CFDictionary)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    private func baseQuery(_ namespace: KeychainNamespace) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: namespace.service,
            kSecAttrAccount as String: namespace.account,
        ]
        if let accessGroup = namespace.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

public enum DeviceStoreError: Error, Equatable, Sendable {
    case invalidDevices
    case invalidStoredData
    case keychain(KeychainError)
}

/// Actor-isolated device list. All writes replace one keychain item, and all
/// callers therefore observe serialized, whole-list updates.
public actor DeviceStore {
    public static let shared = DeviceStore(namespace: .currentApp)

    public let namespace: KeychainNamespace
    private let keychain: any KeychainClient

    public init(
        namespace: KeychainNamespace = .production,
        keychain: any KeychainClient = SystemKeychain()
    ) {
        self.namespace = namespace
        self.keychain = keychain
    }

    public func loadDevices() throws -> [Device] {
        try load()
    }

    public func saveDevices(_ devices: [Device]) throws {
        try save(devices)
    }

    public func load() throws -> [Device] {
        do {
            guard let data = try keychain.copyMatching(namespace: namespace) else {
                return []
            }
            return try JSONDecoder().decode([Device].self, from: data)
        } catch let error as KeychainError {
            throw DeviceStoreError.keychain(error)
        } catch {
            throw DeviceStoreError.invalidStoredData
        }
    }

    public func save(_ devices: [Device]) throws {
        guard devices.allSatisfy(Device.isValid) else {
            throw DeviceStoreError.invalidDevices
        }

        let data: Data
        do {
            data = try JSONEncoder().encode(devices)
        } catch {
            throw DeviceStoreError.invalidDevices
        }

        do {
            try keychain.update(data: data, namespace: namespace)
        } catch let error as KeychainError where error.statusCode == Int32(errSecItemNotFound) {
            do {
                try keychain.add(data: data, namespace: namespace)
            } catch let addError as KeychainError where addError.statusCode == Int32(errSecDuplicateItem) {
                // Another process may have created the item between update and
                // add. Retrying update keeps the operation whole-list atomic.
                do {
                    try keychain.update(data: data, namespace: namespace)
                } catch let updateError as KeychainError {
                    throw DeviceStoreError.keychain(updateError)
                } catch {
                    throw DeviceStoreError.keychain(.invalidResult)
                }
            } catch let addError as KeychainError {
                throw DeviceStoreError.keychain(addError)
            } catch {
                throw DeviceStoreError.keychain(.invalidResult)
            }
        } catch let error as KeychainError {
            throw DeviceStoreError.keychain(error)
        } catch {
            throw DeviceStoreError.keychain(.invalidResult)
        }
    }

    public func delete() throws {
        do {
            try keychain.delete(namespace: namespace)
        } catch let error as KeychainError where error.statusCode == Int32(errSecItemNotFound) {
            return
        } catch let error as KeychainError {
            throw DeviceStoreError.keychain(error)
        } catch {
            throw DeviceStoreError.keychain(.invalidResult)
        }
    }
}
