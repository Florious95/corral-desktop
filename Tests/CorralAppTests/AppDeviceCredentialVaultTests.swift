import CorralContracts
import CorralServices
import Darwin
import Foundation
import Security
import XCTest
@testable import CorralApp

@MainActor
final class AppDeviceCredentialVaultTests: XCTestCase {
    func testFallsBackToPrivateFileForKeychainAuthorizationFailures() async throws {
        for status in [errSecMissingEntitlement, OSStatus(-60008), errSecInteractionNotAllowed] {
            let support = FileManager.default.temporaryDirectory
                .appendingPathComponent("corral-credentials-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: support) }
            let namespace = support.appendingPathComponent(DeviceRepository.namespace, isDirectory: true)
            try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let credentialDirectory = namespace.appendingPathComponent(".credentials", isDirectory: true)
            let vault = AppDeviceCredentialVault(
                keychain: FailingKeychainCredentialStorage(status: status),
                fallback: PrivateFileCredentialVault(directoryURL: credentialDirectory)
            )
            let handle = CredentialHandle("keychain-item:\(UUID().uuidString)")
            let secret = "fixture-secret-\(status)"

            try await vault.store(secret, for: handle)
            let resolvedSecret = try await vault.resolve(handle)
            XCTAssertEqual(resolvedSecret, secret)
            let directoryAttributes = try FileManager.default.attributesOfItem(atPath: credentialDirectory.path)
            let directoryMode = try XCTUnwrap(directoryAttributes[.posixPermissions] as? NSNumber).intValue
            XCTAssertEqual(directoryMode & 0o777, 0o700)
            let files = try FileManager.default.contentsOfDirectory(atPath: credentialDirectory.path)
            XCTAssertEqual(files.count, 1)
            let fileURL = credentialDirectory.appendingPathComponent(try XCTUnwrap(files.first))
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let fileMode = try XCTUnwrap(fileAttributes[.posixPermissions] as? NSNumber).intValue
            XCTAssertEqual(fileMode & 0o777, 0o600)
            XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), secret)

            try await vault.delete(handle)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: credentialDirectory.path).isEmpty)
        }
    }
}

private struct FailingKeychainCredentialStorage: KeychainCredentialStorage {
    let status: OSStatus

    func store(_ secret: String, for handle: CredentialHandle) async throws {
        throw KeychainCredentialError(status: status)
    }

    func resolve(_ handle: CredentialHandle) async throws -> String? {
        throw KeychainCredentialError(status: status)
    }

    func delete(_ handle: CredentialHandle) async throws {
        throw KeychainCredentialError(status: status)
    }
}
