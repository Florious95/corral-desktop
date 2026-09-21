import Foundation
import XCTest
@testable import Services

final class PiProbeInstallerTests: XCTestCase {
    func testInstallWritesProbeToCompatibilityAndPiDiscoveryPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmirror-probe-\(UUID().uuidString)", isDirectory: true)
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = resources.appendingPathComponent(PiProbeInstaller.resourceName)
        try Data("export default function (pi) {}\n".utf8).write(to: source)
        try PiProbeInstaller.install(resourceDirectory: resources, homeDirectory: home)

        let compatibility = home.appendingPathComponent(".pi/agent/plugins/agentmirror-probe/index.js")
        let discovered = home.appendingPathComponent(".pi/agent/extensions/agentmirror-probe.js")
        XCTAssertEqual(try Data(contentsOf: compatibility), try Data(contentsOf: source))
        XCTAssertEqual(try Data(contentsOf: discovered), try Data(contentsOf: source))
        XCTAssertEqual(try permissions(compatibility), 0o644)
        XCTAssertEqual(try permissions(discovered), 0o644)
        XCTAssertEqual(try permissions(compatibility.deletingLastPathComponent()), 0o755)
    }

    func testRemoveDeletesOnlyAgentMirrorProbePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmirror-probe-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let userExtension = home.appendingPathComponent(".pi/agent/extensions/user.js")
        let probe = home.appendingPathComponent(".pi/agent/plugins/agentmirror-probe/index.js")
        try FileManager.default.createDirectory(at: userExtension.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: probe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user".utf8).write(to: userExtension)
        try Data("probe".utf8).write(to: probe)
        defer { try? FileManager.default.removeItem(at: root) }

        try PiProbeInstaller.remove(homeDirectory: home)

        XCTAssertFalse(FileManager.default.fileExists(atPath: probe.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: userExtension.path))
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
