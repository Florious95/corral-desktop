import Foundation
import Darwin

enum CorralPrivateStorageError: Error {
    case unsafePath
}

enum CorralPrivateStorage {
    static let namespace = "com.corral.native.dev"

    static func directoryURL(applicationSupportDirectory: URL?) throws -> URL {
        let supportDirectory: URL
        if let applicationSupportDirectory {
            supportDirectory = applicationSupportDirectory
        } else {
            supportDirectory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        let directory = supportDirectory.appendingPathComponent(namespace, isDirectory: true)
        try ensurePrivateDirectory(directory)
        return directory
    }

    static func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        guard result == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw CorralPrivateStorageError.unsafePath
        }
        guard url.path.withCString({ Darwin.chmod($0, mode_t(0o700)) }) == 0 else {
            throw posixError()
        }
    }

    static func readData(from url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        guard result == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw CorralPrivateStorageError.unsafePath
        }
        guard url.path.withCString({ Darwin.chmod($0, mode_t(0o600)) }) == 0 else {
            throw posixError()
        }
        return try Data(contentsOf: url)
    }

    static func atomicallyWrite(_ data: Data, to url: URL) throws {
        let directoryURL = url.deletingLastPathComponent()
        try ensurePrivateDirectory(directoryURL)
        let temporaryURL = directoryURL.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        }
        guard fd >= 0 else { throw posixError() }
        var shouldRemoveTemporary = true
        defer {
            _ = Darwin.close(fd)
            if shouldRemoveTemporary { _ = temporaryURL.path.withCString { unlink($0) } }
        }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, baseAddress.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
        guard Darwin.fsync(fd) == 0,
              temporaryURL.path.withCString({ Darwin.chmod($0, mode_t(0o600)) }) == 0 else {
            throw posixError()
        }
        let renameResult = temporaryURL.path.withCString { source in
            url.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard renameResult == 0 else { throw posixError() }
        shouldRemoveTemporary = false

        let directoryFD = directoryURL.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY) }
        if directoryFD >= 0 {
            _ = Darwin.fsync(directoryFD)
            _ = Darwin.close(directoryFD)
        }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
