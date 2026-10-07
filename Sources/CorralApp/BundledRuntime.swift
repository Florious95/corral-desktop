import CorralContracts
import CorralServices
import CryptoKit
import Darwin
import Foundation

/// macOS counterpart of the Windows WSL install/start pipeline. All blocking
/// filesystem/process work stays on this actor, not the AppKit executor.
actor BundledRuntime {
    static let shared = BundledRuntime()
    static let folderName = "Runtime"
    static let manifestName = "runtime-manifest.json"
    enum Failure: Error { case invalidManifest, unsafePath, corruptResource(String), commandFailed(String), notReady, missingToken, foreignJob }

    struct Manifest: Codable {
        struct File: Codable { let sha256: String; let size: Int; let executable: Bool }
        let formatVersion: Int
        let platform: String
        let coreCommit: String
        let coreTree: String
        let windowsCommit: String
        let files: [String: File]
    }

    private struct Capability: Decodable {
        struct Coordinate: Decodable { let sha256: String; let size: Int? }
        struct Corpus: Decodable { let path: String; let sha256: String }
        let platform: String
        let binary: Coordinate
        let piExtension: Coordinate
        let corpora: [Corpus]
        enum CodingKeys: String, CodingKey { case platform, binary, corpora; case piExtension = "pi_extension" }
    }

    enum ListenScope: Sendable { case allInterfaces, loopback }

    struct Configuration: Sendable {
        let resources: URL
        let home: URL
        let support: URL
        let port: Int
        let label: String
        var listenScope: ListenScope = .allInterfaces
        var listenAddress: String { listenScope == .loopback ? "127.0.0.1:\(port)" : ":\(port)" }
        /// Nil in normal launches. Acceptance restricts discovery to its own socket tree.
        var discoveryDirectory: URL? = nil
        var activityDirectory: URL? = nil
    }

    struct Ready: Sendable {
        let token: String?
        let installedDirectory: URL
        let reusedExistingService: Bool
    }

    private struct Ownership: Codable {
        let label: String
        let executable: String
        // Optional so older owned jobs are upgraded once even with the same daemon bytes.
        let listenAddress: String?
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ directory: URL) throws -> (Manifest, Data) {
        let data = try Data(contentsOf: directory.appendingPathComponent(manifestName))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.formatVersion == 1, manifest.platform == "darwin/arm64",
              Set(["agentmirrord", "nodeprobe", "tmux", "nodeprobe-pi-activity.js", "nodeprobe-titles.tsv", "nodeprobe-providers.tsv", "core-capability.json"]).isSubset(of: Set(manifest.files.keys)),
              ["agentmirrord", "nodeprobe", "tmux"].allSatisfy({ manifest.files[$0]?.executable == true }) else {
            throw Failure.invalidManifest
        }
        for (name, expected) in manifest.files {
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.hasPrefix("/"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw Failure.invalidManifest }
            let url = directory.appendingPathComponent(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { throw Failure.unsafePath }
            let contents = try Data(contentsOf: url, options: .mappedIfSafe)
            guard contents.count == expected.size, hash(contents) == expected.sha256 else { throw Failure.corruptResource(name) }
        }
        let capabilityData = try Data(contentsOf: directory.appendingPathComponent("core-capability.json"))
        let capability = try JSONDecoder().decode(Capability.self, from: capabilityData)
        guard capability.platform == manifest.platform,
              manifest.files["nodeprobe"]?.sha256 == capability.binary.sha256,
              manifest.files["nodeprobe"]?.size == capability.binary.size,
              manifest.files["nodeprobe-pi-activity.js"]?.sha256 == capability.piExtension.sha256,
              manifest.files["nodeprobe-pi-activity.js"]?.size == capability.piExtension.size,
              capability.corpora.count == 2 else { throw Failure.invalidManifest }
        for corpus in capability.corpora {
            guard ["tools/nodeprobe/fixtures/titles.tsv", "tools/nodeprobe/fixtures/providers.tsv"].contains(corpus.path),
                  manifest.files["nodeprobe-" + URL(fileURLWithPath: corpus.path).lastPathComponent]?.sha256 == corpus.sha256 else { throw Failure.invalidManifest }
        }
        let daemon = try Data(contentsOf: directory.appendingPathComponent("agentmirrord"), options: .mappedIfSafe)
        guard daemon.range(of: capabilityData) != nil else { throw Failure.corruptResource("embedded Core capability") }
        return (manifest, data)
    }

    private static func privateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw Failure.unsafePath }
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard chmod(url.path, 0o700) == 0 else { throw Failure.unsafePath }
    }

    func install(_ configuration: Configuration) throws -> URL {
        let source = configuration.resources.resolvingSymlinksInPath()
        let (manifest, data) = try Self.verify(source)
        let root = configuration.support.resolvingSymlinksInPath().appendingPathComponent("runtime", isDirectory: true)
        try Self.privateDirectory(root)
        let installed = root.appendingPathComponent(Self.hash(data), isDirectory: true)
        if FileManager.default.fileExists(atPath: installed.path) {
            _ = try Self.verify(installed)
        } else {
            let staging = root.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
            try Self.privateDirectory(staging)
            defer { try? FileManager.default.removeItem(at: staging) }
            for (name, asset) in manifest.files {
                let target = staging.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: target)
                guard chmod(target.path, asset.executable ? 0o755 : 0o644) == 0 else { throw Failure.unsafePath }
            }
            try data.write(to: staging.appendingPathComponent(Self.manifestName), options: .atomic)
            _ = try Self.verify(staging)
            do { try FileManager.default.moveItem(at: staging, to: installed) }
            catch {
                // A second instance may have finished the same content-addressed install.
                guard FileManager.default.fileExists(atPath: installed.path) else { throw error }
                _ = try Self.verify(installed)
            }
        }
        try PiProbeInstaller.install(resourceDirectory: installed, homeDirectory: configuration.home)
        return installed
    }

    /// Adopt a listening service without stopping/replacing it. Only a job with
    /// our private ownership record and exact program path can be upgraded.
    func prepare(_ configuration: Configuration) async throws -> Ready {
        guard (1...65535).contains(configuration.port), configuration.label.hasPrefix("com.corral.native."),
              configuration.label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { throw Failure.unsafePath }
        let installed = try install(configuration)
        let fm = FileManager.default
        let home = configuration.home.resolvingSymlinksInPath()
        let state = home.appendingPathComponent("Library/Application Support/agentmirror", isDirectory: true)
        try Self.rejectSymlinks(below: home, through: state)
        let root = configuration.support.resolvingSymlinksInPath().appendingPathComponent("runtime", isDirectory: true)
        let marker = root.appendingPathComponent("service-owner.json")
        try Self.validateOwnedFileIfPresent(marker)
        let domain = "gui/\(getuid())"
        let service = domain + "/" + configuration.label
        let executable = installed.appendingPathComponent("agentmirrord").path
        let oldOwner = try? JSONDecoder().decode(Ownership.self, from: Data(contentsOf: marker))
        let inspection = try Self.run("/bin/launchctl", ["print", service])
        let registered = inspection.status == 0
        let ownsRegistered = registered && oldOwner.map {
            $0.label == configuration.label && $0.executable.hasPrefix(root.path + "/")
                && URL(fileURLWithPath: $0.executable).standardizedFileURL.path == $0.executable
                && inspection.output.contains($0.executable)
        } == true
        let shouldUpgrade = ownsRegistered && (oldOwner?.executable != executable
            || oldOwner?.listenAddress != configuration.listenAddress)
        if LocalDaemonSupervisor.portIsListening(port: configuration.port), !shouldUpgrade {
            // An externally managed service may use an existing stored credential;
            // let the Coordinator's normal fallback resolve it, without replacing it.
            let token = LocalDaemonTokenDiscovery.fileToken(environment: ["HOME": home.path])
            return Ready(token: token, installedDirectory: installed, reusedExistingService: true)
        }
        guard !registered || ownsRegistered else { throw Failure.foreignJob }
        try Self.privateDirectory(state)
        if shouldUpgrade {
            let stopped = try Self.run("/bin/launchctl", ["bootout", service])
            guard stopped.status == 0 else { throw Failure.commandFailed("launchctl bootout") }
            // bootout may return while launchd still owns the old service name.
            // Re-bootstrap only after that owned job is actually unregistered.
            for _ in 0..<200 {
                if try Self.run("/bin/launchctl", ["print", service]).status != 0 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard try Self.run("/bin/launchctl", ["print", service]).status != 0 else { throw Failure.notReady }
        }
        if !registered || shouldUpgrade {
            let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            try Self.rejectSymlinks(below: home, through: agents)
            // Preserve existing directory permissions; only our plist is private.
            try fm.createDirectory(at: agents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let plist = agents.appendingPathComponent(configuration.label + ".plist")
            try Self.validateOwnedFileIfPresent(plist)
            if fm.fileExists(atPath: plist.path), oldOwner?.label != configuration.label { throw Failure.foreignJob }
            let logs = configuration.support.appendingPathComponent("runtime-logs", isDirectory: true)
            try Self.privateDirectory(logs)
            let log = logs.appendingPathComponent("agentmirrord.log")
            try Self.validateOwnedFileIfPresent(log)
            if !fm.fileExists(atPath: log.path) { _ = fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let extensionPath = home.appendingPathComponent(".pi/agent/extensions/nodeprobe-pi-activity.js").path
            var environment = [
                "HOME": home.path,
                // A GUI/launchd C locale makes tmux replace Unicode and the inventory
                // unit separator with '_'. WSL's login shell supplied UTF-8 implicitly.
                "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
                "PATH": installed.path + ":/usr/bin:/bin:/usr/sbin:/sbin:" + home.appendingPathComponent(".local/bin").path + ":/opt/homebrew/bin:/usr/local/bin",
                "TERMINFO_DIRS": installed.appendingPathComponent("terminfo").path + ":/usr/share/terminfo",
                "AGENTMIRROR_NODEPROBE_BIN": installed.appendingPathComponent("nodeprobe").path,
                "NODEPROBE_FIXTURES": installed.appendingPathComponent("nodeprobe-titles.tsv").path,
                "NODEPROBE_PROVIDERS": installed.appendingPathComponent("nodeprobe-providers.tsv").path,
                "AGENTMIRROR_NODEPROBE_PI_EXTENSION": extensionPath
            ]
            if let dir = configuration.discoveryDirectory { environment["AGENTMIRROR_E2E_DISCOVERY_SOCKET_DIRS"] = dir.path }
            if let dir = configuration.activityDirectory { environment["NODEPROBE_PI_ACTIVITY_DIR"] = dir.path }
            let job: [String: Any] = [
                "Label": configuration.label,
                "ProgramArguments": ["/usr/bin/env", "-u", "AGENTMIRROR_TOKEN", executable,
                                     "-listen", configuration.listenAddress, "-state-dir", state.path],
                "EnvironmentVariables": environment, "WorkingDirectory": home.path,
                "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 10,
                "StandardOutPath": log.path, "StandardErrorPath": log.path, "Umask": 0o077
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
            try data.write(to: plist, options: .atomic)
            guard chmod(plist.path, 0o600) == 0 else { throw Failure.unsafePath }
            try JSONEncoder().encode(Ownership(label: configuration.label, executable: executable,
                                               listenAddress: configuration.listenAddress)).write(to: marker, options: .atomic)
            let result = try Self.run("/bin/launchctl", ["bootstrap", domain, plist.path])
            guard result.status == 0 else { throw Failure.commandFailed("launchctl bootstrap: \(result.output)") }
        } else {
            let result = try Self.run("/bin/launchctl", ["kickstart", service])
            guard result.status == 0 else { throw Failure.commandFailed("launchctl kickstart") }
        }
        // Bounded readiness; authentication/listing remains the Coordinator's real gate.
        for _ in 0..<200 {
            if LocalDaemonSupervisor.portIsListening(port: configuration.port),
               let token = LocalDaemonTokenDiscovery.fileToken(environment: ["HOME": home.path]) {
                return Ready(token: token, installedDirectory: installed, reusedExistingService: false)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try? Self.run("/bin/launchctl", ["bootout", service])
        throw Failure.notReady
    }

    private static func rejectSymlinks(below root: URL, through url: URL) throws {
        guard url.path.hasPrefix(root.path + "/") else { throw Failure.unsafePath }
        var current = url
        while current.path != root.path {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw Failure.unsafePath }
            current.deleteLastPathComponent()
        }
    }

    private static func validateOwnedFileIfPresent(_ url: URL) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw Failure.unsafePath }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        defer { timeout.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
