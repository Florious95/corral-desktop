import AppKit
import XCTest
@testable import Shell

final class MainWindowControllerTests: XCTestCase {
    private var fixtureURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-shell-theme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: true)
        try Data("<html><body>theme fixture</body></html>".utf8)
            .write(to: fixtureURL.appendingPathComponent("index.html"))
    }

    override func tearDownWithError() throws {
        if let fixtureURL {
            try? FileManager.default.removeItem(at: fixtureURL)
        }
        fixtureURL = nil
        try super.tearDownWithError()
    }

    @MainActor func testC1UsesOpaqueWindowAndWebViewBackground() throws {
        let controller = try MainWindowController(distURL: fixtureURL, websiteDataStore: .nonPersistent())
        defer { controller.close() }
        controller.setTheme(isDark: true)

        XCTAssertTrue(controller.window?.isOpaque == true)
        XCTAssertEqual(controller.webView.value(forKey: "drawsBackground") as? Bool, true)
        assertColor(controller.window?.backgroundColor, equals: (15, 17, 21))
        assertColor(controller.webView.underPageBackgroundColor, equals: (15, 17, 21))
    }

    @MainActor func testThemeMappingUpdatesWindowAndWebViewTogether() throws {
        let controller = try MainWindowController(distURL: fixtureURL, websiteDataStore: .nonPersistent())
        defer { controller.close() }

        controller.setTheme(isDark: false)
        assertColor(controller.window?.backgroundColor, equals: (251, 250, 248))
        assertColor(controller.webView.underPageBackgroundColor, equals: (251, 250, 248))

        controller.setTheme(isDark: true)
        assertColor(controller.window?.backgroundColor, equals: (15, 17, 21))
        assertColor(controller.webView.underPageBackgroundColor, equals: (15, 17, 21))
    }

    @MainActor func testWebKitConfigurationDisablesUnusedFeatures() throws {
        let controller = try MainWindowController(distURL: fixtureURL, websiteDataStore: .nonPersistent())
        defer { controller.close() }

        let configuration = controller.webView.configuration
        XCTAssertFalse(configuration.allowsInlinePredictions)
        XCTAssertFalse(configuration.allowsAirPlayForMediaPlayback)
        XCTAssertEqual(configuration.mediaTypesRequiringUserActionForPlayback, .all)
        XCTAssertFalse(configuration.preferences.isElementFullscreenEnabled)
        XCTAssertEqual(configuration.preferences.inactiveSchedulingPolicy, .suspend)
    }

    private func assertColor(_ color: NSColor?, equals expected: (Int, Int, Int), file: StaticString = #filePath, line: UInt = #line) {
        guard let color = color?.usingColorSpace(.sRGB) else {
            XCTFail("expected sRGB color", file: file, line: line)
            return
        }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertEqual(red, CGFloat(expected.0) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(green, CGFloat(expected.1) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(blue, CGFloat(expected.2) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(alpha, 1, accuracy: 0.001, file: file, line: line)
    }
}
