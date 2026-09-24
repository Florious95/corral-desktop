import Foundation
import Darwin

public enum UISnapshotError: Error, Equatable, Sendable {
    case invalidSnapshot
    case sensitiveField
    case tooLarge
    case io
}

/// Persists the non-sensitive UI state needed when the WebView origin changes.
/// The on-disk representation is a versioned envelope; callers exchange only
/// the whitelisted local-storage values in `values`.
public final class UISnapshotStore: @unchecked Sendable {
    public static let fileName = "ui-snapshot-v1.json"
    public static let maxBytes = 256 * 1024

    public static let allowedKeys: Set<String> = [
        "am.workspace.v2", "am.workspace.v1",
        "am.panes", "am.activePane",
        "am.fav", "am.selected",
        "am.collapsed", "am.spacesOpen", "am.agentsOpen",
    ]

    private static let sensitiveFragments = [
        "token", "secret", "password", "credential", "authorization",
        "apikey", "accesskey", "privatekey", "publickey", "keychain",
    ]

    public let fileURL: URL
    private let legacyFileURL: URL?
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL.standardizedFileURL
        self.legacyFileURL = nil
        self.fileManager = fileManager
    }

    private init(fileURL: URL, legacyFileURL: URL?, fileManager: FileManager) {
        self.fileURL = fileURL.standardizedFileURL
        self.legacyFileURL = legacyFileURL?.standardizedFileURL
        self.fileManager = fileManager
    }

    public convenience init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
        let directory = appSupport.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "com.corral.desktop.test",
            isDirectory: true
        )
        let legacyDirectory = appSupport.appendingPathComponent(
            "com.agentmirror.desktop",
            isDirectory: true
        )
        self.init(
            fileURL: directory.appendingPathComponent(Self.fileName, isDirectory: false),
            legacyFileURL: legacyDirectory.appendingPathComponent(Self.fileName, isDirectory: false),
            fileManager: fileManager
        )
    }

    /// Save either a direct map of whitelisted keys or an envelope containing
    /// `values`. Unknown and sensitive fields are rejected rather than dropped.
    public func save(_ snapshot: Any) throws {
        let values = try Self.normalizedValues(snapshot)
        let envelope: [String: Any] = ["version": 1, "values": values]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        } catch {
            throw UISnapshotError.invalidSnapshot
        }
        guard data.count <= Self.maxBytes else { throw UISnapshotError.tooLarge }

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
                throw UISnapshotError.io
            }
            do {
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)],
                    ofItemAtPath: temporaryURL.path
                )
                if fileManager.fileExists(atPath: fileURL.path) {
                    _ = try fileManager.replaceItemAt(
                        fileURL,
                        withItemAt: temporaryURL,
                        backupItemName: nil,
                        options: .usingNewMetadataOnly
                    )
                } else {
                    try fileManager.moveItem(at: temporaryURL, to: fileURL)
                }
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                throw UISnapshotError.io
            }
        } catch let error as UISnapshotError {
            throw error
        } catch {
            throw UISnapshotError.io
        }
    }

    /// Invalid, missing, non-0600, symlinked, or oversized snapshots fail
    /// closed as nil. The returned value is the whitelisted values map.
    public func load() -> [String: Any]? {
        let targetURL: URL
        if Self.isPrivateRegularFile(fileURL.path) {
            targetURL = fileURL
        } else if let legacyFileURL, Self.isPrivateRegularFile(legacyFileURL.path) {
            targetURL = legacyFileURL
        } else {
            let legacyURL = fileURL.deletingLastPathComponent().appendingPathComponent("ui-snapshot.json")
            guard Self.isPrivateRegularFile(legacyURL.path) else { return nil }
            targetURL = legacyURL
        }
        do {
            let data = try Data(contentsOf: targetURL, options: [.mappedIfSafe])
            guard data.count <= Self.maxBytes,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            if Set(object.keys) == ["values"], let values = object["values"] {
                return try Self.normalizedValues(values)
            }
            guard Set(object.keys) == ["version", "values"],
                  let version = object["version"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(),
                  version.intValue == 1,
                  let values = object["values"] else {
                return nil
            }
            return try Self.normalizedValues(values)
        } catch {
            return nil
        }
    }

    private static func normalizedValues(_ value: Any) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw UISnapshotError.invalidSnapshot
        }

        let values: [String: Any]
        if object["values"] != nil {
            guard Set(object.keys).isSubset(of: ["version", "values"]),
                  object["version"] == nil || isVersionOne(object["version"]),
                  let nested = object["values"] as? [String: Any] else {
                throw UISnapshotError.invalidSnapshot
            }
            values = nested
        } else {
            values = object
        }

        for (key, value) in values {
            if isSensitiveKey(key) || containsSensitiveField(value) {
                throw UISnapshotError.sensitiveField
            }
            guard allowedKeys.contains(key), isJSONValue(value) else {
                throw UISnapshotError.invalidSnapshot
            }
        }
        return values
    }

    private static func isVersionOne(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.intValue == 1
    }

    private static func containsSensitiveField(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            return object.contains { key, nested in
                isSensitiveKey(key) || containsSensitiveField(nested)
            }
        }
        if let array = value as? [Any] {
            return array.contains(where: containsSensitiveField)
        }
        return false
    }

    private static func isJSONValue(_ value: Any) -> Bool {
        if value is NSNull || value is String || value is Bool { return true }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) != CFBooleanGetTypeID()
        }
        if let object = value as? [String: Any] {
            return object.allSatisfy { key, nested in
                !isSensitiveKey(key) && isJSONValue(nested)
            }
        }
        if let array = value as? [Any] {
            return array.allSatisfy(isJSONValue)
        }
        return false
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        return normalized == "key"
            || sensitiveFragments.contains(where: normalized.contains)
    }

    private static func isPrivateRegularFile(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return (info.st_mode & 0o777) == 0o600
    }
}
