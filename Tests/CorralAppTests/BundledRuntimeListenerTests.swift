import Darwin
import Foundation
import XCTest
@testable import CorralApp

/// Actual packaged Core on a private port/HOME/job. Never contacts production9900.
final class BundledRuntimeListenerTests: XCTestCase {
    func testDefaultInstallationAcceptsPhysicalInterfaceAndReusesHealthyJob() async throws {
        guard let path = ProcessInfo.processInfo.environment["CORRAL_TEST_RUNTIME_RESOURCES"] else {
            throw XCTSkip("Set CORRAL_TEST_RUNTIME_RESOURCES to the verified packaged runtime")
        }
        let root = URL(fileURLWithPath: "/tmp/corral-listen-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let home = root.appendingPathComponent("h")
        let support = root.appendingPathComponent("support")
        let label = "com.corral.native.test.listen.\(UUID().uuidString)"
        let target = "gui/\(getuid())/\(label)"
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootout", target]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run(); process.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        let port = try unusedPort()
        XCTAssertNotEqual(port, 9900)
        let socketDirectory = root.appendingPathComponent("tmux-\(getuid())")
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
        let configuration = BundledRuntime.Configuration(resources: URL(fileURLWithPath: path), home: home,
            support: support, port: port, label: label, discoveryDirectory: socketDirectory)
        let runtime = BundledRuntime()
        var isolated = configuration
        isolated.listenScope = .loopback
        _ = try await runtime.prepare(isolated)
        let initialPlist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let initialJob = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: initialPlist), format: nil) as? [String: Any])
        let initialArguments = try XCTUnwrap(initialJob["ProgramArguments"] as? [String])
        XCTAssertTrue(initialArguments.contains("127.0.0.1:\(port)"), "Isolated configuration must remain loopback-only")
        // Simulate the previous installer: same executable and a receipt with no listener field.
        let marker = support.appendingPathComponent("runtime/service-owner.json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
        legacy.removeValue(forKey: "listenAddress")
        try JSONSerialization.data(withJSONObject: legacy).write(to: marker, options: .atomic)
        let migrated = try await runtime.prepare(configuration)
        XCTAssertFalse(migrated.reusedExistingService, "An owned old loopback job must upgrade even when daemon bytes are unchanged")
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let dictionary = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        let arguments = try XCTUnwrap(dictionary["ProgramArguments"] as? [String])
        let listen = try XCTUnwrap(arguments.firstIndex(of: "-listen"))
        XCTAssertEqual(arguments[listen + 1], ":\(port)", "Normal installs must not lock the advertised LAN/Tailscale addresses out")
        let addresses = try interfaceAddresses()
        XCTAssertFalse(addresses.isEmpty)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        for address in ["127.0.0.1"] + addresses {
            var request = URLRequest(url: URL(string: "http://\(address):\(port)/pair/whoami")!)
            request.timeoutInterval = 3
            let (_, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "The actual listener must answer on \(address)")
        }
        let repeated = try await runtime.prepare(configuration)
        XCTAssertTrue(repeated.reusedExistingService)
        print("BUNDLED_LISTEN_NETWORK port=\(port) addresses=\(addresses) HTTP=200 localEndpointUnchanged=true")
    }

    private func unusedPort() throws -> Int {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
        } }
        guard ok else { throw POSIXError(.EIO) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func interfaceAddresses() throws -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { throw POSIXError(.EIO) }
        defer { freeifaddrs(head) }
        var result = Set<String>()
        var cursor = head
        while let node = cursor {
            defer { cursor = node.pointee.ifa_next }
            guard let address = node.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_INET,
                  node.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  node.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.insert(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
        }
        return result.sorted()
    }
}
