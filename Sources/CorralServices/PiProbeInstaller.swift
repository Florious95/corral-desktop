import Foundation
import Darwin

// Ported from the existing macOS shell's Services/PiProbeInstaller.swift;
// paths/payload are shared with src-tauri/src/wsl.rs, not a new Pi protocol.

/// Installs only the AgentMirror-owned Pi probe files. Existing user plugins,
/// extensions, and parent directories are never removed.
public enum PiProbeInstaller {
    public static let resourceName = "nodeprobe-pi-activity.js"
    public static let probeDirectoryName = "agentmirror-probe"
    public static let extensionName = "nodeprobe-pi-activity.js"

    public static func install(
        resourceDirectory: URL?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws {
        guard let resourceDirectory else { return }
        let source = resourceDirectory.appendingPathComponent(resourceName, isDirectory: false)
        guard fileManager.fileExists(atPath: source.path) else { return }
        let data = try Data(contentsOf: source)
        guard !data.isEmpty else { throw PiProbeError.invalidSource }

        let agentDirectory = homeDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
        let pluginsDirectory = agentDirectory.appendingPathComponent("plugins", isDirectory: true)
        let probeDirectory = pluginsDirectory.appendingPathComponent(probeDirectoryName, isDirectory: true)
        let extensionsDirectory = agentDirectory.appendingPathComponent("extensions", isDirectory: true)

        let home = homeDirectory.resolvingSymlinksInPath()
        try makeDirectory(pluginsDirectory, below: home, permissions: 0o755, fileManager: fileManager)
        try makeDirectory(probeDirectory, below: home, permissions: 0o755, fileManager: fileManager)
        try makeDirectory(extensionsDirectory, below: home, permissions: 0o755, fileManager: fileManager)
        try write(data, to: probeDirectory.appendingPathComponent("index.js"), permissions: 0o644,
                  fileManager: fileManager)
        try write(data, to: extensionsDirectory.appendingPathComponent(extensionName), permissions: 0o644,
                  fileManager: fileManager)
        // Same migration as the Windows installer: do not load the old duplicate.
        let legacy = extensionsDirectory.appendingPathComponent("agentmirror-probe.js")
        if fileManager.fileExists(atPath: legacy.path) { try fileManager.removeItem(at: legacy) }
    }

    public static func remove(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws {
        let agentDirectory = homeDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
        let pluginsDirectory = agentDirectory.appendingPathComponent("plugins", isDirectory: true)
        let probeDirectory = pluginsDirectory.appendingPathComponent(probeDirectoryName, isDirectory: true)
        let extensionDirectory = agentDirectory.appendingPathComponent("extensions", isDirectory: true)

        if fileManager.fileExists(atPath: probeDirectory.path) {
            try fileManager.removeItem(at: probeDirectory)
        }
        for legacy in [pluginsDirectory.appendingPathComponent(extensionName),
                       extensionDirectory.appendingPathComponent(extensionName),
                       extensionDirectory.appendingPathComponent("agentmirror-probe.js")] {
            if fileManager.fileExists(atPath: legacy.path) {
                try fileManager.removeItem(at: legacy)
            }
        }
        try removeTemporaryFiles(in: pluginsDirectory, fileManager: fileManager)
        try removeTemporaryFiles(in: extensionDirectory, fileManager: fileManager)
    }

    private static func makeDirectory(_ url: URL, below root: URL, permissions: NSNumber, fileManager: FileManager) throws {
        // Do not relax an existing user's private directories from 0700 to 0755.
        // Reject symlink parents instead of writing through them into another tree.
        guard url.path.hasPrefix(root.path + "/") else { throw PiProbeError.unsafePath(url.path) }
        var ancestor = url
        while ancestor.path != root.path {
            if let attributes = try? fileManager.attributesOfItem(atPath: ancestor.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw PiProbeError.unsafePath(ancestor.path) }
            ancestor.deleteLastPathComponent()
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: permissions])
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw PiProbeError.unsafePath(url.path) }
    }

    private static func write(_ data: Data, to url: URL, permissions: NSNumber,
                              fileManager: FileManager) throws {
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path) {
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw PiProbeError.unsafePath(url.path) }
            if try Data(contentsOf: url) == data { return }
        }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".agentmirror-probe.tmp-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func removeTemporaryFiles(in directory: URL, fileManager: FileManager) throws {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory,
                                                                   includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(".agentmirror-probe.tmp-") {
            try fileManager.removeItem(at: entry)
        }
    }

    public enum PiProbeError: Error {
        case invalidSource
        case unsafePath(String)
    }
}
