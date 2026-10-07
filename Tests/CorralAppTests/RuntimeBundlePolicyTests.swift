import Foundation
import XCTest
@testable import CorralApp

/// Release gate for the native app's runtime distribution boundary.
///
/// The application may use tmux installed on the host, but the app bundle
/// must never carry a second tmux or its Homebrew dylib closure.  The bundle
/// scan is intentionally bound to the candidate path supplied by the caller;
/// it must not silently inspect a different build.
final class RuntimeBundlePolicyTests: XCTestCase {
    func testAppBundleContainsNoEmbeddedTmuxOrExternalDylibs() throws {
        let bundle = appBundleURL()
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        guard FileManager.default.fileExists(atPath: contents.path) else {
            XCTFail("Candidate app bundle is missing Contents: \(bundle.path)")
            return
        }

        let entries = try XCTUnwrap(
            FileManager.default.enumerator(
                at: contents,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants]
            )?.compactMap { $0 as? URL },
            "Unable to enumerate candidate app bundle"
        )
        let embeddedTmux = entries.filter { $0.lastPathComponent == "tmux" }
        let libDirectories = entries.filter {
            $0.lastPathComponent == "lib" && isDirectory($0)
        }
        let externalDylibs = entries.filter {
            $0.pathExtension.lowercased() == "dylib" && !isDirectory($0)
        }

        XCTAssertTrue(
            embeddedTmux.isEmpty,
            "The app bundle must not embed tmux: \(paths(embeddedTmux))"
        )
        XCTAssertTrue(
            libDirectories.isEmpty,
            "The app bundle must not embed a lib directory: \(paths(libDirectories))"
        )
        XCTAssertTrue(
            externalDylibs.isEmpty,
            "The app bundle must not embed external dylibs: \(paths(externalDylibs))"
        )
    }

    func testRuntimeManifestDoesNotRequireTheRemovedTmuxClosure() throws {
        let runtime = appBundleURL()
            .appendingPathComponent("Contents/Resources/Runtime", isDirectory: true)
        guard FileManager.default.fileExists(atPath: runtime.path) else {
            XCTFail("Candidate keeps no verifiable runtime manifest: \(runtime.path)")
            return
        }

        let manifestURL = runtime.appendingPathComponent("runtime-manifest.json")
        var manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        let files = try XCTUnwrap(manifest["files"] as? [String: Any])
        let forbidden = files.keys.filter { name in
            name == "tmux" || name == "lib" || name.hasPrefix("lib/") || name.hasSuffix(".dylib")
        }
        XCTAssertTrue(
            forbidden.isEmpty,
            "The runtime manifest must not advertise removed tmux/lib assets: \(forbidden.sorted())"
        )

        // Exercise the actual verifier against the expected no-tmux manifest.
        // This catches a verifier that still treats tmux as required while
        // allowing a defensive blacklist to mention and reject it.
        let fixture = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        var cleanFiles: [String: Any] = [:]
        for (name, metadata) in files where !forbidden.contains(name) {
            let source = runtime.appendingPathComponent(name)
            let target = fixture.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: target)
            cleanFiles[name] = metadata
        }
        manifest["files"] = cleanFiles
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: fixture.appendingPathComponent("runtime-manifest.json"))

        XCTAssertNoThrow(
            try BundledRuntime.verify(fixture),
            "A valid manifest with the optional tmux/dylib closure removed must remain acceptable"
        )
    }

    func testRuntimeLaunchEnvironmentUsesSystemTmuxSearchPath() throws {
        let runtimeSource = try source("Sources/CorralApp/BundledRuntime.swift")

        let pathLine = runtimeSource.split(separator: "\n").first { $0.contains("\"PATH\"") }
        XCTAssertNotNil(pathLine, "The daemon launch environment must define PATH")
        XCTAssertFalse(
            pathLine?.contains("installed.path") == true,
            "launchd PATH must not prefer the content-addressed app runtime"
        )
        XCTAssertTrue(pathLine?.contains("/opt/homebrew/bin") == true)
        XCTAssertTrue(pathLine?.contains("/usr/local/bin") == true)
    }

    private func appBundleURL() -> URL {
        if let raw = ProcessInfo.processInfo.environment["CORRAL_NATIVE_APP_BUNDLE"], !raw.isEmpty {
            return URL(fileURLWithPath: raw).standardizedFileURL
        }
        return sourceRoot.appendingPathComponent(".build/CorralNativeDev.app", isDirectory: true)
    }

    private var sourceRoot: URL {
        if let raw = ProcessInfo.processInfo.environment["CORRAL_NATIVE_SOURCE_ROOT"], !raw.isEmpty {
            return URL(fileURLWithPath: raw).standardizedFileURL
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-runtime-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func paths(_ urls: [URL]) -> String {
        urls.map(\.path).joined(separator: ", ")
    }
}
