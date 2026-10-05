import CorralContracts
import CorralServices
import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

struct KeychainCredentialError: Error {
    let status: OSStatus
}

protocol KeychainCredentialStorage: Sendable {
    func store(_ secret: String, for handle: CredentialHandle) async throws
    func resolve(_ handle: CredentialHandle) async throws -> String?
    func delete(_ handle: CredentialHandle) async throws
}

// Security's synchronous IPC is allowed to wait for securityd. These nonisolated
// async methods run on the generic executor, never the AppKit/MainActor executor.
struct SystemKeychainCredentialStorage: KeychainCredentialStorage {
    private let service = CorralAppIdentity.bundleIdentifier

    func store(_ secret: String, for handle: CredentialHandle) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: handle.rawValue
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(secret.utf8)]
        let context = LAContext()
        context.interactionNotAllowed = true
        let noUIQuery = query.merging([kSecUseAuthenticationContext as String: context]) { _, new in new }
        let status = SecItemAdd(noUIQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(noUIQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainCredentialError(status: updateStatus) }
        } else if status != errSecSuccess {
            throw KeychainCredentialError(status: status)
        }
    }

    func resolve(_ handle: CredentialHandle) async throws -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: handle.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            throw KeychainCredentialError(status: status)
        }
        return secret
    }

    func delete(_ handle: CredentialHandle) async throws {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: handle.rawValue,
            kSecUseAuthenticationContext as String: context
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialError(status: status)
        }
    }
}

@MainActor
final class AppDeviceCredentialVault: DeviceCredentialVault {
    private let keychain: any KeychainCredentialStorage
    private let fallback: PrivateFileCredentialVault

    init(
        keychain: any KeychainCredentialStorage = SystemKeychainCredentialStorage(),
        fallback: PrivateFileCredentialVault = PrivateFileCredentialVault()
    ) {
        self.keychain = keychain
        self.fallback = fallback
    }

    func store(_ secret: String, for handle: CredentialHandle) async throws {
        do {
            try await keychain.store(secret, for: handle)
            try await fallback.delete(handle)
        } catch {
            guard Self.requiresFileFallback(error) else { throw error }
            try await fallback.store(secret, for: handle)
        }
    }

    func resolve(_ handle: CredentialHandle) async throws -> String? {
        if let secret = try await fallback.resolve(handle) { return secret }
        do {
            return try await keychain.resolve(handle)
        } catch {
            guard Self.requiresFileFallback(error) else { throw error }
            return try await fallback.resolve(handle)
        }
    }

    func delete(_ handle: CredentialHandle) async throws {
        do {
            try await keychain.delete(handle)
        } catch {
            guard Self.requiresFileFallback(error) else { throw error }
        }
        try await fallback.delete(handle)
    }

    private static func requiresFileFallback(_ error: Error) -> Bool {
        guard let error = error as? KeychainCredentialError else { return false }
        return error.status == errSecMissingEntitlement || error.status == -60008 || error.status == errSecInteractionNotAllowed
    }
}

struct PrivateFileCredentialVault: DeviceCredentialVault {
    enum StoreError: Error { case unsafeDirectory, unsafeCredentialFile, fileOperationFailed, invalidCredential }

    let directoryURL: URL

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DeviceRepository.namespace, isDirectory: true)
            .appendingPathComponent(".credentials", isDirectory: true)
    }

    func store(_ secret: String, for handle: CredentialHandle) async throws {
        try ensurePrivateDirectory()
        let fileURL = credentialURL(for: handle)
        if FileManager.default.fileExists(atPath: fileURL.path) { try validatePrivateFile(fileURL) }
        do {
            try Data(secret.utf8).write(to: fileURL, options: .atomic)
            guard chmod(fileURL.path, mode_t(0o600)) == 0 else { throw StoreError.fileOperationFailed }
            try validatePrivateFile(fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw StoreError.fileOperationFailed
        }
    }

    func resolve(_ handle: CredentialHandle) async throws -> String? {
        try validateNamespaceDirectory()
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return nil }
        try validatePrivateDirectory()
        let fileURL = credentialURL(for: handle)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        try validatePrivateFile(fileURL)
        guard let secret = String(data: try Data(contentsOf: fileURL), encoding: .utf8) else {
            throw StoreError.invalidCredential
        }
        return secret
    }

    func delete(_ handle: CredentialHandle) async throws {
        try validateNamespaceDirectory()
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        try validatePrivateDirectory()
        let fileURL = credentialURL(for: handle)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try validatePrivateFile(fileURL)
        do { try FileManager.default.removeItem(at: fileURL) }
        catch { throw StoreError.fileOperationFailed }
    }

    private func ensurePrivateDirectory() throws {
        try validateNamespaceDirectory()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            } catch { throw StoreError.fileOperationFailed }
        }
        try validatePrivateDirectory()
        guard chmod(directoryURL.path, mode_t(0o700)) == 0 else { throw StoreError.fileOperationFailed }
        try validatePrivateDirectory()
    }

    private func validateNamespaceDirectory() throws {
        try validateDirectory(directoryURL.deletingLastPathComponent())
    }

    private func validatePrivateDirectory() throws {
        try validateDirectory(directoryURL)
    }

    private func validateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0 else { throw StoreError.unsafeDirectory }
    }

    private func validatePrivateFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o600 else { throw StoreError.unsafeCredentialFile }
    }

    private func credentialURL(for handle: CredentialHandle) -> URL {
        let digest = SHA256.hash(data: Data(handle.rawValue.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directoryURL.appendingPathComponent(digest, isDirectory: false)
    }
}
