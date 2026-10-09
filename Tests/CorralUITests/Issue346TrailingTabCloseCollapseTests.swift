import AppKit
import XCTest
@testable import CorralUI

/// Issue #346 red gate.  This uses the real CorralTabBarView/AppKit layout and
/// close-button actions in an offscreen private window; it never contacts Core.
@MainActor
final class Issue346TrailingTabCloseCollapseTests: XCTestCase {
    private struct FrameRecord: Codable {
        let step: Int
        let sample: String
        let remaining: Int
        let tabs: [TabRecord]
    }

    private struct TabRecord: Codable {
        let title: String
        let frame: CGRect
        let childFrames: [String: CGRect]
    }

    func testClosingTrailingTabsKeepsEqualSafeWidthsAndDisjointChildren() throws {
        _ = NSApplication.shared
        let evidence = try evidenceDirectory()
        let tabs = makeTabs(6)
        let bar = CorralTabBarView(frame: NSRect(x: 0, y: 0, width: 512, height: 38))
        let window = NSWindow(contentRect: NSRect(x: -12_000, y: -12_000, width: 512, height: 38),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = bar
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }

        bar.setTabs(tabs, selectedTabID: tabs[0].id)
        settle(bar, window)
        bar.rename(tabs[0].id)
        settle(bar, window)

        var liveTabs = tabs
        bar.onCloseTab = { id in
            liveTabs.removeAll { $0.id == id }
            bar.setTabs(liveTabs, selectedTabID: liveTabs.first?.id)
            bar.layoutSubtreeIfNeeded()
        }

        var records: [FrameRecord] = []
        for step in 1...5 {
            let trailing = try XCTUnwrap(liveTabs.last, "missing trailing Tab at close step \(step)")
            let item = try XCTUnwrap(tabItem(for: trailing, in: bar), "missing trailing Tab view at close step \(step)")
            let close = try XCTUnwrap(closeButton(in: item), "missing trailing close button at close step \(step)")
            let windowPoint = item.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
            bar.mouseEntered(with: try event(.mouseEntered, at: windowPoint, in: window))
            item.mouseEntered(with: try event(.mouseEntered, at: windowPoint, in: window))
            close.performClick(nil)

            for sample in ["immediate", "005ms", "050ms", "200ms"] {
                if sample != "immediate" {
                    let milliseconds = sample == "005ms" ? 5 : sample == "050ms" ? 50 : 200
                    RunLoop.main.run(until: Date().addingTimeInterval(Double(milliseconds) / 1_000))
                }
                settle(bar, window)
                let record = record(step: step, sample: sample, liveTabs: liveTabs, bar: bar)
                records.append(record)
                try write(record, to: evidence.appendingPathComponent("frames-\(step)-\(sample).json"))
                if sample == "200ms" {
                    try capture(bar, to: evidence.appendingPathComponent("tabbar-after-trailing-close-\(step).png"))
                }
            }

            let widths = tabItems(in: bar).map(\.frame.width)
            XCTAssertEqual(widths.count, liveTabs.count, "close step \(step) must remove only the trailing Tab")
            XCTAssertTrue(widths.allSatisfy { (44.0...160.0).contains($0) },
                          "Issue #346: trailing close step \(step) produced unsafe widths: \(widths)")
            XCTAssertLessThanOrEqual((widths.max() ?? 0) - (widths.min() ?? 0), 0.5,
                                     "Issue #346: trailing close step \(step) produced unequal widths: \(widths)")
            for item in tabItems(in: bar) {
                XCTAssertTrue(childOverlaps(in: item).isEmpty,
                              "Issue #346: trailing close step \(step) has child overlap: \(childOverlaps(in: item))")
            }
        }

        try write(records, to: evidence.appendingPathComponent("frames.json"))
        let insideWidths = tabItems(in: bar).map(\.frame.width)
        XCTAssertTrue(insideWidths.allSatisfy { (44.0...160.0).contains($0) },
                      "Issue #346: final trailing-close state has unsafe widths: \(insideWidths)")

        bar.mouseExited(with: try event(.mouseExited, at: NSPoint(x: -12_001, y: 19), in: window))
        settle(bar, window)
        let expandedWidths = tabItems(in: bar).map(\.frame.width)
        XCTAssertLessThanOrEqual((expandedWidths.max() ?? 0) - (expandedWidths.min() ?? 0), 0.5,
                                 "After leaving the TabBar, trailing-close survivors must remain equal-width: \(expandedWidths)")
    }

    func testOverflowTrailingCloseThenMouseExitKeepsSurvivorsAtOneSafeWidth() throws {
        _ = NSApplication.shared
        let evidence = try evidenceDirectory()
        let tabs = makeTabs(15)
        let bar = CorralTabBarView(frame: NSRect(x: 0, y: 0, width: 512, height: 38))
        let window = NSWindow(contentRect: NSRect(x: -12_000, y: -12_000, width: 512, height: 38), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = bar
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }

        bar.setTabs(tabs, selectedTabID: tabs[0].id)
        settle(bar, window)
        // Keep the first Tab in the same rename-overlay state as the reported user path.
        bar.rename(tabs[0].id)
        settle(bar, window)

        var liveTabs = tabs
        bar.onCloseTab = { id in
            liveTabs.removeAll { $0.id == id }
            bar.setTabs(liveTabs, selectedTabID: liveTabs.first?.id)
            bar.layoutSubtreeIfNeeded()
        }

        // The pointer remains in the TabBar while the trailing close buttons are activated.
        bar.mouseEntered(with: try event(.mouseEntered, at: NSPoint(x: 450, y: 19), in: window))
        var closeRecords: [FrameRecord] = []
        for step in 1...12 {
            let trailing = try XCTUnwrap(liveTabs.last, "missing trailing Tab at close step \(step)")
            let item = try XCTUnwrap(tabItem(for: trailing, in: bar), "missing trailing Tab view at close step \(step)")
            let close = try XCTUnwrap(closeButton(in: item), "missing trailing close button at close step \(step)")
            let point = item.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
            item.mouseEntered(with: try event(.mouseEntered, at: point, in: window))
            close.performClick(nil)
            settle(bar, window)
            let record = record(step: step, sample: "inside", liveTabs: liveTabs, bar: bar)
            closeRecords.append(record)
            try write(record, to: evidence.appendingPathComponent("close-\(step)-inside.json"))
            try capture(bar, to: evidence.appendingPathComponent("tabbar-close-\(step)-inside.png"))

            let widths = tabItems(in: bar).map(\.frame.width)
            XCTAssertTrue(widths.allSatisfy { (44.0...160.0).contains($0) },
                          "Issue #346: trailing close step \(step) produced unsafe widths: \(widths)")
            XCTAssertLessThanOrEqual((widths.max() ?? 0) - (widths.min() ?? 0), 0.5,
                                     "Issue #346: trailing close step \(step) produced unequal widths: \(widths)")
            XCTAssertTrue(crossTabOverlaps(in: tabItems(in: bar)).isEmpty,
                          "Issue #346: trailing close step \(step) has overlapping Tab frames: \(crossTabOverlaps(in: tabItems(in: bar)))")
            for survivor in tabItems(in: bar) {
                XCTAssertTrue(childOverlaps(in: survivor).isEmpty,
                              "Issue #346: trailing close step \(step) has child overlap: \(childOverlaps(in: survivor))")
            }
        }
        XCTAssertEqual(liveTabs.count, 3)
        try write(closeRecords, to: evidence.appendingPathComponent("close-frames.json"))

        // Moving the pointer out releases the width lock.  Sample the real AppKit
        // transition, including the settled frame, instead of checking only a final
        // model constant.
        bar.mouseExited(with: try event(.mouseExited, at: NSPoint(x: -1, y: 19), in: window))
        let started = Date()
        let samples: [(String, TimeInterval)] = [("immediate", 0), ("005ms", 0.005), ("020ms", 0.020),
                                                   ("050ms", 0.050), ("100ms", 0.100), ("180ms", 0.180), ("250ms", 0.250)]
        var unlockRecords: [FrameRecord] = []
        for (sample, delay) in samples {
            let target = started.addingTimeInterval(delay)
            if target > Date() { RunLoop.main.run(until: target) }
            settle(bar, window)
            let record = record(step: 13, sample: sample, liveTabs: liveTabs, bar: bar)
            unlockRecords.append(record)
            try write(record, to: evidence.appendingPathComponent("unlock-\(sample).json"))
            try capture(bar, to: evidence.appendingPathComponent("tabbar-unlock-\(sample).png"))

            let items = tabItems(in: bar)
            let widths = items.map { $0.layer?.presentation()?.frame.width ?? $0.frame.width }
            XCTAssertTrue(widths.allSatisfy { (44.0...160.0).contains($0) },
                          "Issue #346 RED: unlock sample \(sample) rendered unsafe widths: \(widths)")
            XCTAssertLessThanOrEqual((widths.max() ?? 0) - (widths.min() ?? 0), 0.5,
                                     "Issue #346 RED: unlock sample \(sample) rendered unequal widths: \(widths)")
            for survivor in items {
                XCTAssertTrue(childOverlaps(in: survivor).isEmpty,
                              "Issue #346 RED: unlock sample \(sample) has child overlap: \(childOverlaps(in: survivor))")
            }
        }
        try write(unlockRecords, to: evidence.appendingPathComponent("unlock-frames.json"))
    }

    private func makeTabs(_ count: Int) -> [CorralTab] {
        (0..<count).map { CorralTab(title: "Agent-\($0)-long", provider: "codex") }
    }

    private func tabItems(in bar: CorralTabBarView) -> [NSView] {
        bar.tabs.compactMap { tabItem(for: $0, in: bar) }
    }

    private func tabItem(for tab: CorralTab, in bar: NSView) -> NSView? {
        descendants(of: bar).first {
            $0.accessibilityIdentifier() == "corral.tab" && $0.accessibilityLabel() == tab.title
        }
    }

    private func closeButton(in item: NSView) -> NSButton? {
        descendants(of: item).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "corral.tab.close" }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func crossTabOverlaps(in items: [NSView]) -> [String] {
        var overlaps: [String] = []
        for first in items.indices {
            for second in items.indices where second > first {
                let intersection = items[first].frame.intersection(items[second].frame)
                if intersection.width > 0.01, intersection.height > 0.01 {
                    overlaps.append("tab[\(first)]×tab[\(second)] area=\(intersection.width * intersection.height) frames=\(NSStringFromRect(items[first].frame))/\(NSStringFromRect(items[second].frame))")
                }
            }
        }
        return overlaps
    }

    private func childOverlaps(in item: NSView) -> [String] {
        let children = descendants(of: item).filter { view in
            guard !view.isHidden, view.frame.width > 0, view.frame.height > 0 else { return false }
            return view.accessibilityIdentifier() == "corral.tab.title"
                || view.accessibilityIdentifier() == "corral.tab.close"
                || view.accessibilityIdentifier() == "corral.tab.rename"
                || view is CorralStatusIndicatorView
                || view is NSImageView
                || (view is NSTextField && view.accessibilityIdentifier().isEmpty)
        }
        var overlaps: [String] = []
        for first in children.indices {
            for second in children.indices where second > first {
                let a = children[first].frame
                let b = children[second].frame
                let intersection = a.intersection(b)
                if intersection.width > 0.01, intersection.height > 0.01 {
                    overlaps.append("\(role(children[first]))×\(role(children[second])) area=\(intersection.width * intersection.height) frames=\(NSStringFromRect(a))/\(NSStringFromRect(b))")
                }
            }
        }
        return overlaps
    }

    private func role(_ view: NSView) -> String {
        if view.accessibilityIdentifier() == "corral.tab.title" { return "title" }
        if view.accessibilityIdentifier() == "corral.tab.close" { return "close" }
        if view.accessibilityIdentifier() == "corral.tab.rename" { return "rename" }
        if view is NSTextField { return "rename" }
        if view is CorralStatusIndicatorView { return "status" }
        return "provider"
    }

    private func record(step: Int, sample: String, liveTabs: [CorralTab], bar: CorralTabBarView) -> FrameRecord {
        let tabs = liveTabs.compactMap { tab -> TabRecord? in
            guard let item = tabItem(for: tab, in: bar) else { return nil }
            let children = descendants(of: item).reduce(into: [String: CGRect]()) { result, view in
                let id = view.accessibilityIdentifier()
                guard !id.isEmpty, view.frame.width > 0, view.frame.height > 0 else { return }
                result["\(id)#\(result.count)"] = view.frame
            }
            return TabRecord(title: tab.title, frame: item.frame, childFrames: children)
        }
        return FrameRecord(step: step, sample: sample, remaining: liveTabs.count, tabs: tabs)
    }

    private func evidenceDirectory() throws -> URL {
        let path = ProcessInfo.processInfo.environment["CORRAL_ISSUE346_EVIDENCE_DIR"] ?? "/private/tmp/corral-native-trailing-tab-close-repro"
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url)
    }

    private func capture(_ view: NSView, to url: URL) throws {
        let size = view.bounds.size
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        view.displayIfNeeded()
        try XCTUnwrap(view.layer).render(in: context.cgContext)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    private func settle(_ bar: CorralTabBarView, _ window: NSWindow) {
        window.layoutIfNeeded()
        bar.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             trackingNumber: 0, userData: nil))
    }
}
