import AppKit
import CorralContracts
import CorralUI
@testable import CorralApp
@testable import SwiftTerm
import XCTest

@MainActor
final class Issue18TerminalTrailingMarginTests: XCTestCase {
    func testSinglePaneGridLeavesNoOversizedRightMargin() throws {
        _ = NSApplication.shared
        let id = SessionID("issue18-single")
        let stage = NativeTerminalStageView(frame: NSRect(x: 0, y: 0, width: 1200, height: 720))
        let view = makeTerminalView()
        stage.update(root: .session(id), focusedSessionID: id, views: [id: view])
        stage.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.frame.maxX, stage.bounds.maxX, accuracy: 0.1,
                       "The single terminal viewport should reach the stage's right edge")
        assertTightTrailingGap(in: view, scenario: "single pane")
    }

    func testSplitPaneGridsKeepTrailingMarginsAsTightAsTheirFivePointLeadingInset() throws {
        _ = NSApplication.shared
        let firstID = SessionID("issue18-split-first")
        let secondID = SessionID("issue18-split-second")
        let root = WorkspaceLayoutNode.split(
            direction: .horizontal,
            ratio: 0.5,
            first: .session(firstID),
            second: .session(secondID)
        )
        let stage = NativeTerminalStageView(frame: NSRect(x: 0, y: 0, width: 1200, height: 720))
        let firstView = makeTerminalView()
        let secondView = makeTerminalView()
        stage.update(root: root, focusedSessionID: firstID,
                     views: [firstID: firstView, secondID: secondView])
        stage.layoutSubtreeIfNeeded()

        let panes = SplitLayout.project(root, in: stage.bounds).panes
        for (id, view) in [(firstID, firstView), (secondID, secondView)] {
            let pane = try XCTUnwrap(panes.first { $0.sessionID == id })
            let leadingInset = view.frame.minX - pane.frame.minX
            XCTAssertEqual(leadingInset, CorralMVPWorkspaceView.terminalViewportLeadingInset, accuracy: 0.1)
            assertTightTrailingGap(in: view, scenario: "split pane \(id.rawValue)")
        }
    }

    func testTightTrailingMarginKeepsTheScrollerUsableWithoutCoveringTheLastCell() throws {
        _ = NSApplication.shared
        let id = SessionID("issue18-scroller")
        let stage = NativeTerminalStageView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        let view = makeTerminalView()
        stage.update(root: .session(id), focusedSessionID: id, views: [id: view])
        stage.layoutSubtreeIfNeeded()
        let output = (0..<(view.terminal.rows + 20)).map { "scrollback \($0)\r\n" }.joined()
        view.replaceSnapshot(Data(output.utf8))
        view.layoutSubtreeIfNeeded()

        let scroller = try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSScroller }.first)
        XCTAssertTrue(view.canScroll, "The test terminal must have real scrollback")
        XCTAssertTrue(scroller.isEnabled, "The right-side terminal scroller must remain interactive")
        let cellWidth = view.cellDimension.width
        let lastCell = NSRect(x: CGFloat(view.terminal.cols - 1) * cellWidth, y: 0,
                              width: cellWidth, height: view.bounds.height)
        XCTAssertFalse(scroller.frame.intersects(lastCell),
                       "The scroller must not cover the terminal's last character column")
        view.scroll(toPosition: 0)
        XCTAssertEqual(view.scrollPosition, 0, accuracy: 0.001,
                       "The scroller-backed terminal must still navigate its scrollback")
        assertTightTrailingGap(in: view, scenario: "scroller enabled")
    }

    private func makeTerminalView() -> CorralNativeTerminalView {
        CorralNativeTerminalView(
            frame: .zero,
            pasteboard: NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        )
    }

    private func assertTightTrailingGap(in view: CorralNativeTerminalView, scenario: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let gridWidth = CGFloat(view.terminal.cols) * view.cellDimension.width
        let trailingGap = view.bounds.maxX - gridWidth
        let allowance = max(6, view.cellDimension.width)
        XCTAssertGreaterThan(view.terminal.cols, 0, "\(scenario) must have a live terminal grid", file: file, line: line)
        XCTAssertLessThanOrEqual(trailingGap, allowance,
                                 "\(scenario) right trailing gap is \(trailingGap)pt (cell \(view.cellDimension.width)pt); must be at most one cell", file: file, line: line)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
