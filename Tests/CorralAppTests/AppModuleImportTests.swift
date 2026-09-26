import XCTest
@testable import CorralApp

final class AppModuleImportTests: XCTestCase {
    func testDevelopmentIdentity() {
        XCTAssertEqual(CorralAppIdentity.bundleIdentifier, "com.corral.native.dev")
    }
}
