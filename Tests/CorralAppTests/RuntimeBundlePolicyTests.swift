import Foundation
import XCTest

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

    func testRuntimeLaunchEnvironmentUsesSystemTmuxSearchPath() throws {
        let runtimeSource = try source("Sources/CorralApp/BundledRuntime.swift")
        let prepareScript = try source("Scripts/prepare-runtime.py")
        let verifyScript = try source("Scripts/verify-runtime.py")

        XCTAssertFalse(
            runtimeSource.contains("\"tmux\""),
            "The runtime manifest contract must not require an embedded tmux"
        )
        XCTAssertFalse(
            runtimeSource.contains("\"PATH\": installed.path"),
            "launchd PATH must not prefer the content-addressed app runtime"
        )
        XCTAssertTrue(runtimeSource.contains("/opt/homebrew/bin"))
        XCTAssertTrue(runtimeSource.contains("/usr/local/bin"))

        XCTAssertFalse(prepareScript.contains("args.tmux"), "Packaging must not consume a tmux input")
        XCTAssertFalse(prepareScript.contains("stage / 'tmux'"), "Packaging must not stage tmux")
        XCTAssertFalse(prepareScript.contains("stage / 'lib'"), "Packaging must not stage a dylib closure")
        XCTAssertFalse(verifyScript.contains("'tmux'"), "Runtime verification must not require tmux")
        XCTAssertFalse(verifyScript.contains("root / 'lib'"), "Runtime verification must not require lib")
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

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func paths(_ urls: [URL]) -> String {
        urls.map(\.path).joined(separator: ", ")
    }
}
