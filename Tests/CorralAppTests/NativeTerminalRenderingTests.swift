import AppKit
@testable import CorralApp
@testable import SwiftTerm
import XCTest

@MainActor
final class NativeTerminalRenderingTests: XCTestCase {
    func testHiddenTerminalParsesInOrderWithoutSchedulingPaintAndRefreshesOnReveal() async throws {
        let view = CorralNativeTerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400),
            pasteboard: NSPasteboard(name: NSPasteboard.Name(UUID().uuidString)))
        view.isHidden = true
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(view.pendingDisplay)
        view.replaceSnapshot(Data("HIDDEN-FIRST".utf8))
        view.feedRemoteANSI(Array("\r\nHIDDEN-SECOND".utf8)[...])
        XCTAssertTrue(view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true).contains("HIDDEN-FIRST") == true)
        XCTAssertTrue(view.getTerminal().getLine(row: 1)?.translateToString(trimRight: true).contains("HIDDEN-SECOND") == true)
        XCTAssertFalse(view.pendingDisplay, "background streams must update their engine without scheduling a hidden paint/blink scan")
        view.isHidden = false
        XCTAssertTrue(view.pendingDisplay, "revealing the same terminal must refresh the accumulated screen")
        try await Task.sleep(for: .milliseconds(40))
    }
}
