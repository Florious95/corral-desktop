import CorralContracts
import Darwin
import Foundation

/// Resolves the workstation daemon credential without exposing it in device metadata.
enum LocalDaemonTokenDiscovery {
    static let endpoint = try! ApprovedEndpoint(scheme: "ws", host: "127.0.0.1", port: 9900)
    static let deviceID = DeviceID("corral-local-host")
    static let deviceName = "本机"
    static let credentialHandle = CredentialHandle("local-daemon-token-v1")

    static func token(environment: [String: String], credentialVault: any DeviceCredentialVault) async -> String? {
        if let token = valid(environment["CORRAL_NATIVE_TOKEN"]) { return token }

        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        for relativePath in [
            ".corral/token", ".config/corral/token", ".config/agentmirror/token",
            "Library/Application Support/agentmirror/token", "Library/Application Support/corral/token"
        ] {
            if let token = readToken(at: URL(fileURLWithPath: home).appendingPathComponent(relativePath)) {
                return token
            }
        }

        if let token = valid(environment["AGENTMIRROR_TOKEN"] ?? environment["CORRAL_TOKEN"]) { return token }
        return valid(try? await credentialVault.resolve(credentialHandle))
    }

    static func valid(_ value: String?) -> String? {
        guard let value else { return nil }
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.utf8.count <= 256,
              !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return token
    }

    private static func readToken(at url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_size > 0, info.st_size <= 4096,
              let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) else { return nil }
        return valid(contents)
    }
}

/// App-launch-only daemon guard. Coordinator tests use an injected SessionLink and never probe host port 9900.
enum LocalDaemonSupervisor {
    static func ensureLocalDaemonRunning(token: String?, environment: [String: String]) async {
        guard environment["CORRAL_NATIVE_ENDPOINT"].flatMap({ $0.isEmpty ? nil : $0 }) == nil,
              !isUnitTestProcess(environment),
              !portIsListening() else { return }

        for executable in executableCandidates(environment: environment) {
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { continue }
            let process = Process()
            process.executableURL = executable
            var arguments = ["-listen", "127.0.0.1:9900"]
            if let token = LocalDaemonTokenDiscovery.valid(token) {
                arguments += ["-token", token]
            }
            process.arguments = arguments
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { continue }

            for _ in 0..<20 {
                if portIsListening() { return }
                guard process.isRunning else { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if process.isRunning { return }
        }
    }

    private static func isUnitTestProcess(_ environment: [String: String]) -> Bool {
        environment["CORRAL_NATIVE_TEST_MODE"] == "1"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["SWIFT_TESTING_ENABLED"] == "1"
    }

    private static func executableCandidates(environment: [String: String]) -> [URL] {
        var paths = [environment["CORRAL_NATIVE_DAEMON_PATH"], environment["AGENTMIRRORD_PATH"]].compactMap { $0 }
        if let bundled = Bundle.main.url(forResource: "agentmirrord", withExtension: nil) {
            paths.append(bundled.path)
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? FileManager.default.homeDirectoryForCurrentUser.path
        paths.append(contentsOf: [
            URL(fileURLWithPath: home).appendingPathComponent(".local/bin/agentmirrord").path,
            "/opt/homebrew/bin/agentmirrord",
            "/usr/local/bin/agentmirrord"
        ])
        var seen = Set<String>()
        return paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { seen.insert($0.path).inserted }
    }

    private static func portIsListening() -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(9900).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
