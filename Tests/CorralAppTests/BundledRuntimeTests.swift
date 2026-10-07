import Foundation
import XCTest
@testable import CorralApp

final class BundledRuntimeTests: XCTestCase {
    func testInstallIsVersionedAndIdempotentAndPreservesUserExtensions() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = try fixture(root.appendingPathComponent("resources"), version: "one")
        let home = root.appendingPathComponent("home")
        let extensions = home.appendingPathComponent(".pi/agent/extensions")
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("USER_CODE".utf8).write(to: extensions.appendingPathComponent("user.js"))
        try Data("old AgentMirror duplicate".utf8).write(to: extensions.appendingPathComponent("agentmirror-probe.js"))
        let configuration = BundledRuntime.Configuration(resources: resources, home: home,
            support: root.appendingPathComponent("support"), port: 12345, label: "com.corral.native.test.install")
        let runtime = BundledRuntime()
        let installed = try await runtime.install(configuration)
        let plugin = extensions.appendingPathComponent("nodeprobe-pi-activity.js")
        let modified = try FileManager.default.attributesOfItem(atPath: plugin.path)[.modificationDate] as? Date
        let again = try await runtime.install(configuration)
        XCTAssertEqual(installed, again)
        XCTAssertEqual(modified, try FileManager.default.attributesOfItem(atPath: plugin.path)[.modificationDate] as? Date)
        XCTAssertEqual(try Data(contentsOf: plugin), Data("plugin-one".utf8))
        XCTAssertEqual(try Data(contentsOf: extensions.appendingPathComponent("user.js")), Data("USER_CODE".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: extensions.appendingPathComponent("agentmirror-probe.js").path))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: extensions.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        _ = try fixture(resources, version: "two")
        let updated = try await runtime.install(configuration)
        XCTAssertNotEqual(updated, installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path), "Do not mutate/delete an older running version")
    }

    func testCorruptAssetAndBlessedButIncompatiblePluginBothFailClosed() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = try fixture(root.appendingPathComponent("resources"), version: "one")
        try Data("corrupt".utf8).write(to: resources.appendingPathComponent("nodeprobe"))
        XCTAssertThrowsError(try BundledRuntime.verify(resources))
        _ = try fixture(resources, version: "one")
        let plugin = Data("incompatible plugin".utf8)
        try plugin.write(to: resources.appendingPathComponent("nodeprobe-pi-activity.js"))
        let url = resources.appendingPathComponent(BundledRuntime.manifestName)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var files = try XCTUnwrap(manifest["files"] as? [String: Any])
        files["nodeprobe-pi-activity.js"] = ["sha256": BundledRuntime.hash(plugin), "size": plugin.count, "executable": false]
        manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        XCTAssertThrowsError(try BundledRuntime.verify(resources), "Updating only the outer manifest cannot bypass Core's capability")
    }

    func testSymlinkAssetCannotEscapeTheBundle() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = try fixture(root.appendingPathComponent("resources"), version: "one")
        let plugin = resources.appendingPathComponent("nodeprobe-pi-activity.js")
        let outside = root.appendingPathComponent("outside.js")
        try FileManager.default.moveItem(at: plugin, to: outside)
        try FileManager.default.createSymbolicLink(at: plugin, withDestinationURL: outside)
        XCTAssertThrowsError(try BundledRuntime.verify(resources))
    }

    func testBootstrapRejectsStateDirectorySymlinkBeforeAnyServiceOperation() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = try fixture(root.appendingPathComponent("resources"), version: "one")
        let home = root.appendingPathComponent("home")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Library"), withDestinationURL: outside)
        let configuration = BundledRuntime.Configuration(resources: resources, home: home,
            support: root.appendingPathComponent("support"), port: 12345, label: "com.corral.native.test.symlink")
        do {
            _ = try await BundledRuntime().prepare(configuration)
            XCTFail("A private HOME must not escape to another Library")
        } catch BundledRuntime.Failure.unsafePath {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("corral-runtime-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fixture(_ directory: URL, version: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [String: Data] = ["nodeprobe": Data("probe".utf8), "tmux": Data("tmux".utf8),
            "nodeprobe-pi-activity.js": Data("plugin-\(version)".utf8), "nodeprobe-titles.tsv": Data("titles".utf8), "nodeprobe-providers.tsv": Data("providers".utf8)]
        func coordinate(_ name: String) -> [String: Any] { ["sha256": BundledRuntime.hash(files[name]!), "size": files[name]!.count] }
        let capability: [String: Any] = ["platform": "darwin/arm64", "binary": coordinate("nodeprobe"), "pi_extension": coordinate("nodeprobe-pi-activity.js"),
            "corpora": [["path": "tools/nodeprobe/fixtures/titles.tsv", "sha256": BundledRuntime.hash(files["nodeprobe-titles.tsv"]!)],
                        ["path": "tools/nodeprobe/fixtures/providers.tsv", "sha256": BundledRuntime.hash(files["nodeprobe-providers.tsv"]!)]]]
        let cap = try JSONSerialization.data(withJSONObject: capability, options: .sortedKeys)
        files["core-capability.json"] = cap
        files["agentmirrord"] = Data("TEST-ONLY-NOT-EXECUTED\n".utf8) + cap
        let assets = files.mapValues { data in ["sha256": BundledRuntime.hash(data), "size": data.count, "executable": false] as [String: Any] }
        var manifest: [String: Any] = ["formatVersion": 1, "platform": "darwin/arm64", "coreCommit": "test", "coreTree": "test", "windowsCommit": "test"]
        var marked = assets
        for name in ["agentmirrord", "nodeprobe", "tmux"] { marked[name]?["executable"] = true }
        manifest["files"] = marked
        for (name, data) in files { try data.write(to: directory.appendingPathComponent(name)) }
        try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys).write(to: directory.appendingPathComponent(BundledRuntime.manifestName))
        return directory
    }
}
