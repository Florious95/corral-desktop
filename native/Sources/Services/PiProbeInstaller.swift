import Foundation

/// Installs only the AgentMirror-owned Pi probe files. Existing user plugins,
/// extensions, and parent directories are never removed.
public enum PiProbeInstaller {
    public static let resourceName = "agentmirror-probe.js"
    public static let probeDirectoryName = "agentmirror-probe"
    public static let extensionName = "agentmirror-probe.js"

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

        let agentDirectory = homeDirectory
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
        let pluginsDirectory = agentDirectory.appendingPathComponent("plugins", isDirectory: true)
        let probeDirectory = pluginsDirectory.appendingPathComponent(probeDirectoryName, isDirectory: true)
        let extensionsDirectory = agentDirectory.appendingPathComponent("extensions", isDirectory: true)

        try makeDirectory(pluginsDirectory, permissions: 0o755, fileManager: fileManager)
        try makeDirectory(probeDirectory, permissions: 0o755, fileManager: fileManager)
        try makeDirectory(extensionsDirectory, permissions: 0o755, fileManager: fileManager)
        try write(data, to: probeDirectory.appendingPathComponent("index.js"), permissions: 0o644,
                  fileManager: fileManager)
        try write(data, to: extensionsDirectory.appendingPathComponent(extensionName), permissions: 0o644,
                  fileManager: fileManager)
    }

    public static func remove(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws {
        let agentDirectory = homeDirectory
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
        let pluginsDirectory = agentDirectory.appendingPathComponent("plugins", isDirectory: true)
        let probeDirectory = pluginsDirectory.appendingPathComponent(probeDirectoryName, isDirectory: true)
        let extensionDirectory = agentDirectory.appendingPathComponent("extensions", isDirectory: true)

        if fileManager.fileExists(atPath: probeDirectory.path) {
            try fileManager.removeItem(at: probeDirectory)
        }
        for legacy in [pluginsDirectory.appendingPathComponent(extensionName),
                       extensionDirectory.appendingPathComponent(extensionName)] {
            if fileManager.fileExists(atPath: legacy.path) {
                try fileManager.removeItem(at: legacy)
            }
        }
        try removeTemporaryFiles(in: pluginsDirectory, fileManager: fileManager)
        try removeTemporaryFiles(in: extensionDirectory, fileManager: fileManager)
    }

    private static func makeDirectory(_ url: URL, permissions: NSNumber, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: permissions])
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private static func write(_ data: Data, to url: URL, permissions: NSNumber,
                              fileManager: FileManager) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".agentmirror-probe.tmp-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.moveItem(at: temporary, to: url)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
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
    }
}
