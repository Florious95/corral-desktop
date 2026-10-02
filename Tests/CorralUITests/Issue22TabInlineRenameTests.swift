import AppKit
@testable import CorralUI
import XCTest

@MainActor
final class Issue22TabInlineRenameTests: XCTestCase {
    func testOffscreenTitleDoubleClickOpensInlineEditorAndEnterCommits() throws {
        let fixture = makeFixture()
        let (window, bar, tab, workspace) = (fixture.window, fixture.bar, fixture.tab, fixture.workspace)
        defer { window.close() }
        let title = try titleField(for: tab, in: bar)
        let titlePoint = title.convert(NSPoint(x: title.bounds.midX, y: title.bounds.midY), to: nil)
        let titleCenter = NSPoint(x: title.bounds.midX, y: title.bounds.midY)
        let item = try XCTUnwrap(tabItem(tab, in: bar))
        let pointInItem = title.convert(titleCenter, to: item)
        XCTAssertTrue(title.bounds.contains(titleCenter) && item.bounds.contains(pointInItem),
                      "The synthetic click must be geometrically inside the title and its TabItem")
        XCTAssertLessThan(window.frame.minX, -1_000)
        XCTAssertLessThan(window.frame.minY, -1_000)
        XCTAssertFalse(window.isKeyWindow, "The offscreen test window must never take keyboard focus")

        sendDoubleClick(at: titlePoint, in: window)
        let editor = try XCTUnwrap(descendants(of: bar).compactMap { $0 as? CorralInlineRenameField }.first,
                                   "A title-area double-click must create an inline editor")
        XCTAssertEqual(editor.stringValue, tab.title)
        XCTAssertTrue(window.firstResponder === editor || editor.currentEditor() === window.firstResponder,
                      "The inline editor must own the offscreen test window's first responder")
        XCTAssertEqual(editor.currentEditor()?.selectedRange, NSRange(location: 0, length: editor.stringValue.utf16.count),
                       "The title text should be selected for replacement")

        editor.stringValue = "Renamed tab"
        window.sendEvent(try keyEvent(keyCode: 36, characters: "\r", in: window))
        XCTAssertEqual(tab.title, "Renamed tab")
        XCTAssertTrue(tab.isCustomTitle, "The workspace rename handler must persist a custom title")
        XCTAssertTrue(workspace.tabs.contains { $0.id == tab.id && $0.title == "Renamed tab" })
        XCTAssertFalse(editor.isDescendant(of: bar), "Enter must close the editor")
        XCTAssertEqual(try titleField(for: tab, in: bar).stringValue, "Renamed tab")
    }

    func testOffscreenTitleDoubleClickThenEscapeCancels() throws {
        let fixture = makeFixture(title: "Keep this name")
        let (window, bar, tab) = (fixture.window, fixture.bar, fixture.tab)
        defer { window.close() }
        let title = try titleField(for: tab, in: bar)
        let point = title.convert(NSPoint(x: title.bounds.midX, y: title.bounds.midY), to: nil)
        sendDoubleClick(at: point, in: window)
        let editor = try XCTUnwrap(descendants(of: bar).compactMap { $0 as? CorralInlineRenameField }.first,
                                   "A title-area double-click must create an inline editor")
        editor.stringValue = "Discard this name"
        window.sendEvent(try keyEvent(keyCode: 53, characters: "\u{1b}", in: window))
        XCTAssertEqual(tab.title, "Keep this name")
        XCTAssertFalse(editor.isDescendant(of: bar), "Escape must close the editor without committing")
        XCTAssertEqual(try titleField(for: tab, in: bar).stringValue, "Keep this name")
    }

    func testResetNameActionRestoresDefaultTitle() throws {
        _ = NSApplication.shared
        let tab = CorralTab(title: "Session default")
        let workspace = CorralWorkspaceView(tabs: [tab])
        workspace.frame = NSRect(x: 0, y: 0, width: 1400, height: 860)
        let window = offscreenWindow(contentView: workspace)
        defer { window.close() }
        tab.title = "Custom title"
        tab.isCustomTitle = true
        workspace.tabBar.setTabs([tab], selectedTabID: tab.id)
        let item = try XCTUnwrap(tabItem(tab, in: workspace.tabBar))
        let reset = try XCTUnwrap(item.accessibilityCustomActions()?.first { $0.name == "恢复自动标题" })
        XCTAssertTrue(reset.handler?() ?? false)
        XCTAssertEqual(tab.title, "Session default")
        XCTAssertFalse(tab.isCustomTitle)
    }

    private func makeFixture(title: String = "Default title") -> (window: NSWindow, bar: CorralTabBarView, tab: CorralTab, workspace: CorralWorkspaceView) {
        _ = NSApplication.shared
        let selected = CorralTab(title: "Selected")
        let tab = CorralTab(title: title)
        let workspace = CorralWorkspaceView(tabs: [selected, tab])
        workspace.frame = NSRect(x: 0, y: 0, width: 1400, height: 860)
        let window = offscreenWindow(contentView: workspace)
        window.contentView?.layoutSubtreeIfNeeded()
        workspace.layoutSubtreeIfNeeded()
        workspace.tabBar.layoutSubtreeIfNeeded()
        return (window, workspace.tabBar, tab, workspace)
    }

    private func offscreenWindow(contentView: NSView) -> NSWindow {
        let size = contentView.frame.size == .zero ? NSSize(width: 720, height: 80) : contentView.frame.size
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        contentView.frame = window.contentView?.bounds ?? NSRect(origin: .zero, size: size)
        window.orderBack(nil)
        contentView.layoutSubtreeIfNeeded()
        return window
    }

    private func sendDoubleClick(at point: NSPoint, in window: NSWindow) {
        let start = ProcessInfo.processInfo.systemUptime
        let events: [(NSEvent.EventType, Int, TimeInterval)] = [
            (.leftMouseDown, 1, start), (.leftMouseUp, 1, start + 0.05),
            (.leftMouseDown, 2, start + 0.15), (.leftMouseUp, 2, start + 0.20)
        ]
        for (index, event) in events.enumerated() {
            if let event = NSEvent.mouseEvent(with: event.0, location: point, modifierFlags: [], timestamp: event.2,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: index,
                                              clickCount: event.1, pressure: event.0 == .leftMouseUp ? 0 : 1) {
                window.sendEvent(event)
            }
        }
    }

    private func keyEvent(keyCode: UInt16, characters: String, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil,
                                       characters: characters, charactersIgnoringModifiers: characters,
                                       isARepeat: false, keyCode: keyCode))
    }

    private func titleField(for tab: CorralTab, in bar: NSView) throws -> NSTextField {
        try XCTUnwrap(descendants(of: try XCTUnwrap(tabItem(tab, in: bar)))
            .compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "corral.tab.title" })
    }

    private func tabItem(_ tab: CorralTab, in bar: NSView) -> NSView? {
        descendants(of: bar).first { $0.accessibilityIdentifier() == "corral.tab" && $0.accessibilityLabel() == tab.title }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
