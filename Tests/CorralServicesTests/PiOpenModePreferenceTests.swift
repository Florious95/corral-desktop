import CorralContracts
@testable import CorralServices
import Foundation
import XCTest

final class PiOpenModePreferenceTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pi-open-mode-\(UUID().uuidString)", isDirectory: true)
    }

    func testAPreviousPreferencesFileKeepsEveryValueAndGetsTheGUIDefault() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let namespace = support.appendingPathComponent("com.corral.native.dev", isDirectory: true)
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
        let previous = #"{"theme":"dark","fontFamily":"Menlo, monospace","fontSize":17,"followDirectory":true,"sidebarCollapsed":true}"#
        try Data(previous.utf8).write(to: namespace.appendingPathComponent(UserPreferencesStore.storageFilename))
        let store = try UserPreferencesStore(applicationSupportDirectory: support)
        let restored = await store.snapshot()
        XCTAssertEqual(restored, UserPreferences(theme: .dark, fontFamily: "Menlo, monospace", fontSize: 17, followDirectory: true,
                                                 sidebarCollapsed: true, piOpenMode: .gui))
    }

    func testTheChoicePersistsWithoutTouchingOtherSettings() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try UserPreferencesStore(applicationSupportDirectory: support)
        var preferences = await store.snapshot()
        preferences.fontSize = 18
        preferences.piOpenMode = .tui
        _ = try await store.update(preferences)
        let reopened = await (try UserPreferencesStore(applicationSupportDirectory: support)).snapshot()
        XCTAssertEqual(reopened.piOpenMode, .tui)
        XCTAssertEqual(reopened.fontSize, 18)
        let json = try String(contentsOf: support.appendingPathComponent("com.corral.native.dev/preferences.json"), encoding: .utf8)
        XCTAssertTrue(json.contains(#""piOpenMode":"tui""#))
        let garbage = try JSONDecoder().decode(UserPreferences.self, from: Data(#"{"piOpenMode":"web"}"#.utf8))
        XCTAssertEqual(garbage.piOpenMode, .gui, "an unknown stored mode falls back to the product default")
    }
}
