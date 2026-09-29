import AppKit
import CorralContracts
import CorralServices
import CorralUI
import XCTest
@testable import CorralApp

@MainActor
final class Issue13SplitLayoutPaddingTests: XCTestCase {
    func testSplitTerminalViewportsKeepFivePointLeadingInsetWithoutRightGap() throws {
        let containerFrame = CGRect(x: 0, y: 0, width: 900, height: 560)
        let firstID = SessionID("issue13-left-pane")
        let secondID = SessionID("issue13-right-pane")
        let layout = WorkspaceLayoutNode.split(
            direction: .horizontal,
            ratio: 0.5,
            first: .session(firstID),
            second: .session(secondID)
        )

        let stage = NativeTerminalStageView(frame: containerFrame)
        let firstTerminal = CorralNativeTerminalView(frame: .zero)
        let secondTerminal = CorralNativeTerminalView(frame: .zero)
        stage.update(root: layout, focusedSessionID: firstID, views: [firstID: firstTerminal, secondID: secondTerminal])
        stage.layoutSubtreeIfNeeded()

        let splitChrome = SplitWorkspaceView(root: layout)
        splitChrome.frame = stage.bounds
        stage.addSubview(splitChrome)
        splitChrome.update(root: layout, focusedSessionID: firstID)
        stage.layoutSubtreeIfNeeded()

        let firstPane = try XCTUnwrap(splitChrome.projection.frame(of: firstID))
        let secondPane = try XCTUnwrap(splitChrome.projection.frame(of: secondID))
        let leadingInset = firstTerminal.frame.minX - firstPane.minX
        let trailingInset = secondPane.maxX - secondTerminal.frame.maxX
        XCTAssertGreaterThanOrEqual(leadingInset, 5, "The left split terminal must gain at least 5pt of breathing room")
        XCTAssertLessThanOrEqual(trailingInset, 2, "The rightmost terminal must not leave an oversized unused gap")
    }
}