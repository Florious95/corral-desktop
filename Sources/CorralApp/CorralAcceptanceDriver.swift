#if DEBUG
import AppKit
import CorralContracts
import CorralUI
import CorralServices

/// Opt-in, process-local acceptance driver for the packaged development app.
/// It cannot start without a private test directory and an explicit non-production endpoint.
/// No HID events, general clipboard, production stores or production connections are used.
@MainActor
final class CorralAcceptanceDriver {
    enum Failure: Error { case unsafeConfiguration, invalidCommand, missingView }
    let directory: URL
    let coordinator: CorralApplicationCoordinator
    private var task: Task<Void, Never>?
    private var drag: AcceptanceDraggingInfo?

    static func directory(environment: [String: String]) throws -> URL? {
        guard let path = environment["CORRAL_NATIVE_ACCEPTANCE_DIRECTORY"] else { return nil }
        let directory = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard directory.deletingLastPathComponent() == URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath(),
              directory.lastPathComponent.hasPrefix("corral-native-acceptance-"),
              environment["CORRAL_NATIVE_BACKGROUND"] == "1",
              let rawEndpoint = environment["CORRAL_NATIVE_ENDPOINT"], let url = URL(string: rawEndpoint),
              let endpoint = try? ApprovedEndpoint(url: url), endpoint.port != 9900,
              environment["CORRAL_NATIVE_TOKEN"]?.isEmpty == false else { throw Failure.unsafeConfiguration }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw Failure.unsafeConfiguration }
        return directory
    }

    static func pasteboard(directory: URL) -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("corral.acceptance." + directory.lastPathComponent))
    }

    init(directory: URL, coordinator: CorralApplicationCoordinator) {
        self.directory = directory
        self.coordinator = coordinator
    }

    func start() {
        task = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                let commandURL = directory.appendingPathComponent("command.json")
                if FileManager.default.fileExists(atPath: commandURL.path) {
                    do {
                        let data = try Data(contentsOf: commandURL)
                        try FileManager.default.removeItem(at: commandURL)
                        let command = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                        let origin = ["scroll": "hit-tested-scroll-handler", "ime": "NSTextInputClient",
                                      "hover": "drag-destination-handler", "drop": "drag-destination-handler"][command["op"] as? String ?? ""] ?? "appkit-synthetic"
                        var reply: [String: Any] = ["id": command["id"] ?? "", "origin": origin]
                        do {
                            try await perform(command)
                            try await Task.sleep(for: .milliseconds(150))
                            reply["ok"] = true
                        } catch {
                            reply["ok"] = false
                            reply["error"] = String(describing: error)
                        }
                        reply["state"] = try snapshot()
                        let output = try JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys])
                        try output.write(to: directory.appendingPathComponent("result.json"), options: .atomic)
                    } catch {
                        try? Data(String(describing: error).utf8).write(to: directory.appendingPathComponent("driver-error.txt"), options: .atomic)
                    }
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    private func terminal(_ command: [String: Any]) throws -> CorralNativeTerminalView {
        guard let ref = command["ref"] as? String,
              let view = coordinator.terminalView(for: try SessionReference(ref)) else { throw Failure.missingView }
        return view
    }

    private func perform(_ command: [String: Any]) async throws {
        guard let window = coordinator.windowController.window else { throw Failure.missingView }
        let workspace = coordinator.workspaceView
        window.contentView?.layoutSubtreeIfNeeded()
        switch command["op"] as? String {
        case "state": break
        case "sidebar":
            guard let session = command["session"] as? String,
                  let row = workspace.sidebar.agents.firstIndex(where: { $0.sessionID?.rawValue == session }) else { throw Failure.missingView }
            let table = workspace.sidebar.agentsTable
            table.scrollRowToVisible(row)
            let rect = table.rect(ofRow: row)
            let point = CGPoint(x: rect.midX, y: rect.midY)
            if command["count"] as? Int == 2 {
                try click(table, point: point)
                try await Task.sleep(for: .milliseconds(60))
                try click(table, point: point, count: 2)
            } else {
                try click(table, point: point, jitter: command["jitter"] as? CGFloat ?? 0)
            }
        case "new-tab": try click(workspace.tabBar.createButton)
        case "exit-preview": try click(workspace.previewExitButton)
        case "tab":
            guard let id = command["tab"] as? String, let uuid = UUID(uuidString: id),
                  let index = workspace.tabBar.tabs.firstIndex(where: { $0.id == uuid }) else { throw Failure.invalidCommand }
            let items = descendants(workspace.tabBar).filter { $0.accessibilityIdentifier() == "corral.tab" }
            guard items.indices.contains(index) else { throw Failure.missingView }
            items[index].scrollToVisible(items[index].bounds)
            try click(items[index])
        case "close-tab":
            guard let id = command["tab"] as? String, let uuid = UUID(uuidString: id),
                  let index = workspace.tabBar.tabs.firstIndex(where: { $0.id == uuid }) else { throw Failure.invalidCommand }
            let items = descendants(workspace.tabBar).filter { $0.accessibilityIdentifier() == "corral.tab" }
            guard items.indices.contains(index), let button = descendants(items[index]).first(where: { $0.accessibilityIdentifier() == "corral.tab.close" }) as? NSButton else { throw Failure.missingView }
            button.performClick(nil)
        case "terminal-click":
            let view = try terminal(command)
            try click(view, point: CGPoint(x: command["x"] as? CGFloat ?? 60, y: command["y"] as? CGFloat ?? 80))
        case "scroll":
            let view = try terminal(command)
            // NSEvent has no public scroll constructor without CGEvent. Exercise
            // the hit-tested responder's scroll handler; this is not OS wheel evidence.
            let event = AcceptanceScrollEvent(window: window, location: view.convert(CGPoint(x: 60, y: 80), to: nil),
                delta: command["delta"] as? CGFloat ?? 0, precise: command["precise"] as? Bool ?? true)
            guard let content = window.contentView,
                  content.hitTest(content.convert(event.locationInWindow, from: nil)) === view else { throw Failure.missingView }
            view.scrollWheel(with: event)
        case "key":
            let flags = NSEvent.ModifierFlags(rawValue: command["modifiers"] as? UInt ?? 0)
            let text = command["text"] as? String ?? ""
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: command["plain"] as? String ?? text,
                isARepeat: false, keyCode: command["code"] as? UInt16 ?? 0) else { throw Failure.invalidCommand }
            // A background test window is intentionally not the app's key window.
            // Route exactly to its shortcut chain and first responder, without activation.
            if !flags.contains(.command) || !window.performKeyEquivalent(with: event) {
                window.sendEvent(event)
            }
        case "ime":
            let view = try terminal(command)
            view.setMarkedText(command["marked"] as? String ?? "", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            if let committed = command["commit"] as? String { view.insertText(committed, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        case "clipboard":
            let pasteboard = Self.pasteboard(directory: directory)
            pasteboard.clearContents()
            if let text = command["text"] as? String { pasteboard.setString(text, forType: .string) }
            if let path = command["file"] as? String { pasteboard.writeObjects([URL(fileURLWithPath: path) as NSURL]) }
            if let path = command["image"] as? String { pasteboard.setData(try Data(contentsOf: URL(fileURLWithPath: path)), forType: .png) }
        case "hover", "drop":
            let stage = workspace.stageContainer
            let point = CGPoint(x: command["x"] as? CGFloat ?? 0, y: command["y"] as? CGFloat ?? 0)
            guard let session = command["session"] as? String,
                  let source = workspace.sidebar.agents.first(where: { $0.sessionID?.rawValue == session })?.sessionID else { throw Failure.invalidCommand }
            let drag = AcceptanceDraggingInfo(window: window, location: stage.splitView.convert(point, to: nil), source: source)
            self.drag = drag
            guard stage.draggingUpdated(drag) == .move else { throw Failure.invalidCommand }
            if command["op"] as? String == "drop", !stage.performDragOperation(drag) { throw Failure.invalidCommand }
        case "cancel-drop": workspace.stageContainer.draggingExited(drag); drag = nil
        case "close-pane":
            guard let session = command["session"] as? String,
                  let button = workspace.stageContainer.splitView.closeButtons[SessionID(session)] else { throw Failure.missingView }
            button.performClick(nil)
        case "splitter":
            let overlay = workspace.stageContainer.splitView
            guard let path = command["path"] as? String,
                  let divider = overlay.projection.dividers.first(where: { $0.path == path }) else { throw Failure.invalidCommand }
            let point = CGPoint(x: divider.frame.midX, y: divider.frame.midY)
            let offset = command["delta"] as? CGFloat ?? 0
            let final = CGPoint(x: point.x + (divider.direction == .horizontal ? offset : 0), y: point.y + (divider.direction == .vertical ? offset : 0))
            try events(in: overlay, points: [(.leftMouseDown, point), (.leftMouseDragged, final), (.leftMouseUp, final)])
        case "preferences":
            var preferences = coordinator.userPreferences
            if let family = command["font"] as? String { preferences.fontFamily = family }
            if let size = command["size"] as? Int { preferences.fontSize = size }
            try await coordinator.updateUserPreferences(preferences)
        case "quit":
            await coordinator.stop()
            NSApp.terminate(nil)
        default: throw Failure.invalidCommand
        }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func click(_ view: NSView, point: CGPoint? = nil, jitter: CGFloat = 0, count: Int = 1) throws {
        let point = point ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let end = CGPoint(x: point.x + jitter, y: point.y)
        var points: [(NSEvent.EventType, CGPoint)] = [(.leftMouseDown, point)]
        if jitter != 0 { points.append((.leftMouseDragged, end)) }
        points.append((.leftMouseUp, end))
        try events(in: view, points: points, count: count)
    }

    private func events(in view: NSView, points: [(NSEvent.EventType, CGPoint)], count: Int = 1) throws {
        guard let window = view.window else { throw Failure.missingView }
        let events = try points.map { type, point in
            guard let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: count, pressure: type == .leftMouseUp ? 0 : 1) else { throw Failure.invalidCommand }
            return event
        }
        for event in events.dropFirst() { NSApp.postEvent(event, atStart: false) }
        window.sendEvent(events[0])
        while let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantPast, inMode: .default, dequeue: true) { window.sendEvent(event) }
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func rect(_ frame: CGRect) -> [CGFloat] { [frame.minX, frame.minY, frame.width, frame.height] }

    private func snapshot() throws -> [String: Any] {
        guard let window = coordinator.windowController.window else { throw Failure.missingView }
        let workspace = coordinator.workspaceView
        let state = coordinator.workspaceState
        let views = descendants(workspace).compactMap { $0 as? CorralNativeTerminalView }
        var panes: [[String: Any]] = []
        for view in views {
            let terminal = view.getTerminal()
            let frame = view.convert(view.bounds, to: nil)
            let rows = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            panes.append([
                "hidden": view.isHidden, "focused": window.firstResponder === view,
                "ref": coordinator.terminalKey(for: view)?.reference.rawValue ?? "",
                "viewIdentity": String(describing: ObjectIdentifier(view)),
                "frame": rect(frame), "pixelROI": rect(CGRect(x: frame.minX * window.backingScaleFactor,
                    y: (window.frame.height - frame.maxY) * window.backingScaleFactor,
                    width: frame.width * window.backingScaleFactor, height: frame.height * window.backingScaleFactor)),
                "rows": rows, "cols": terminal.cols, "font": view.font.fontName,
                "pointSize": view.font.pointSize, "contentsScale": view.layer?.contentsScale ?? 0,
                "markedText": view.hasMarkedText(), "scrollPosition": view.scrollPosition,
                "mouseMode": String(describing: terminal.mouseMode)
            ])
        }
        return [
            "pid": ProcessInfo.processInfo.processIdentifier, "windowID": window.windowNumber,
            "windowFrame": rect(window.frame), "backingScale": window.backingScaleFactor,
            "connected": coordinator.connected, "lastError": coordinator.lastConnectionError ?? "",
            "workspace": try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)),
            "subscribed": coordinator.subscribedSessionIDs, "panes": panes,
            "previewUID": state.previewUID?.rawValue ?? "",
            "visibleSessionID": state.visibleSessionID?.rawValue ?? "",
            "agents": workspace.sidebar.agents.map { ["name": $0.name, "id": $0.sessionID?.rawValue ?? ""] },
            "stageSize": [workspace.stageContainer.bounds.width, workspace.stageContainer.bounds.height],
            "dropVisible": !workspace.stageContainer.dropZone.isHidden,
            "dropFrame": rect(workspace.stageContainer.splitView.convert(workspace.stageContainer.dropZone.frame, from: workspace.stageContainer)),
            "dropZone": workspace.stageContainer.dropTarget?.edge.rawValue ?? "",
            "projection": workspace.stageContainer.splitView.projection.panes.map { ["id": $0.sessionID.rawValue, "frame": rect($0.frame)] }
        ]
    }
}

@MainActor
private final class AcceptanceScrollEvent: NSEvent {
    private let target: NSWindow
    private let location: NSPoint
    private let amount: CGFloat
    private let precise: Bool
    private let number: Int
    init(window: NSWindow, location: NSPoint, delta: CGFloat, precise: Bool) {
        target = window; number = window.windowNumber
        self.location = location; amount = delta; self.precise = precise
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("app-local event") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { target }
    override var windowNumber: Int { number }
    override var locationInWindow: NSPoint { location }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
    override var deltaY: CGFloat { amount }
    override var scrollingDeltaY: CGFloat { amount }
    override var hasPreciseScrollingDeltas: Bool { precise }
}

/// App-local destination events. This is explicitly not evidence of OS drag tracking/HID.
@MainActor
private final class AcceptanceDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    let draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("corral.acceptance.drag." + UUID().uuidString))
    init(window: NSWindow, location: NSPoint, source: SessionID) {
        draggingDestinationWindow = window
        draggingLocation = location
        super.init()
        draggingPasteboard.setString(source.rawValue, forType: CorralWorkspaceStageView.sessionPasteboardType)
    }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
#endif
