import AppKit
import CorralContracts
import CorralServices
import CorralUI
@preconcurrency import SwiftTerm

/// Tabs carry layout identity; the shared stage owns their actual terminal views.
@MainActor
final class TerminalTabPlaceholderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class TerminalSessionRegistry {
    private var views: [SessionKey: CorralNativeTerminalView] = [:]
    private var keysByView: [ObjectIdentifier: SessionKey] = [:]

    var allViews: [(SessionKey, CorralNativeTerminalView)] { views.map { ($0.key, $0.value) } }
    var count: Int { views.count }

    func view(for key: SessionKey) -> CorralNativeTerminalView? { views[key] }
    func key(for view: TerminalView) -> SessionKey? { keysByView[ObjectIdentifier(view)] }

    func insert(_ view: CorralNativeTerminalView, for key: SessionKey) {
        if let previous = views[key] { keysByView.removeValue(forKey: ObjectIdentifier(previous)) }
        views[key] = view
        keysByView[ObjectIdentifier(view)] = key
    }

    func removeAll() {
        for key in Array(views.keys) { _ = remove(key) }
    }

    @discardableResult
    func remove(_ key: SessionKey) -> CorralNativeTerminalView? {
        guard let view = views.removeValue(forKey: key) else { return nil }
        keysByView.removeValue(forKey: ObjectIdentifier(view))
        view.finishRemoteANSI()
        view.terminalDelegate = nil
        view.setInputEnabled(false)
        view.removeFromSuperview()
        return view
    }
}

@MainActor
final class NativeTerminalStageView: NSView {
    private var layoutRoot: WorkspaceLayoutNode?
    private var focusedSessionID: SessionID?
    private var views: [SessionID: CorralNativeTerminalView] = [:]
    /// Structured panes share the same split projection; they never get a PTY grid or terminal input.
    private var conversationViews: [SessionID: CorralConversationPaneView] = [:]
    /// Viewport chrome of managed agent panes; the pane's content (GUI or terminal) sits below it.
    private var headers: [SessionID: CorralViewportHeaderView] = [:]
    private var backgroundRoots: [WorkspaceLayoutNode] = []
    private var pendingBackgroundFrames: [SessionID: CGRect] = [:]
    private var backgroundLayoutTask: Task<Void, Never>?
    private var lastBackgroundLayoutSize: NSSize?
    var maximumVisiblePanes = Int.max
    private(set) var visibleSessionIDs = Set<SessionID>()
    private(set) var visibleConversationIDs = Set<SessionID>()

    override var isFlipped: Bool { true }

    func update(
        root: WorkspaceLayoutNode?,
        focusedSessionID: SessionID?,
        views: [SessionID: CorralNativeTerminalView],
        backgroundRoots: [WorkspaceLayoutNode] = [],
        conversationViews: [SessionID: CorralConversationPaneView] = [:],
        headers: [SessionID: CorralViewportHeaderView] = [:]
    ) {
        layoutRoot = root
        for (id, header) in headers where self.headers[id] !== header {
            self.headers[id]?.removeFromSuperview()
            self.headers[id] = header
            header.translatesAutoresizingMaskIntoConstraints = true
            header.isHidden = true
            addSubview(header)
        }
        for id in self.headers.keys where headers[id] == nil {
            self.headers.removeValue(forKey: id)?.removeFromSuperview()
        }
        headerSessionIDs = Set(headers.keys)
        for (id, view) in conversationViews where self.conversationViews[id] !== view {
            self.conversationViews[id]?.removeFromSuperview()
            self.conversationViews[id] = view
            view.translatesAutoresizingMaskIntoConstraints = true
            view.isHidden = true
            addSubview(view)
        }
        for id in self.conversationViews.keys where conversationViews[id] == nil {
            self.conversationViews.removeValue(forKey: id)?.removeFromSuperview()
        }
        self.backgroundRoots = backgroundRoots
        self.focusedSessionID = focusedSessionID
        for (id, view) in views where self.views[id] !== view {
            self.views[id]?.setInputEnabled(false)
            self.views[id]?.removeFromSuperview()
            self.views[id] = view
            view.setInputEnabled(id == focusedSessionID)
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        for id in self.views.keys.filter({ views[$0] == nil }) {
            guard let view = self.views.removeValue(forKey: id) else { continue }
            pendingBackgroundFrames.removeValue(forKey: id)
            view.setInputEnabled(false)
            view.removeFromSuperview()
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let panes = Array(SplitLayout.project(layoutRoot, in: bounds).panes.prefix(maximumVisiblePanes))
        let visibleIDs = Set(panes.map(\.sessionID))
        visibleSessionIDs = visibleIDs
        visibleConversationIDs = []
        for (id, header) in headers {
            guard let pane = panes.first(where: { $0.sessionID == id }) else { header.isHidden = true; continue }
            // Keep the split pane's own close button (top-right, 22pt) clear of every header control.
            header.trailingInset = panes.count > 1 ? 34 : 0
            let frame = CGRect(x: pane.frame.minX, y: pane.frame.minY, width: pane.frame.width, height: min(pane.frame.height, CorralViewportHeaderView.height))
            if header.frame != frame { header.frame = frame }
            header.isHidden = false
        }
        for (id, view) in conversationViews {
            guard let pane = panes.first(where: { $0.sessionID == id }) else { view.isHidden = true; continue }
            let frame = contentFrame(pane.frame, id: id)
            if view.frame != frame { view.frame = frame }
            view.isHidden = false
            visibleConversationIDs.insert(id)
        }
        var backgroundFrames: [SessionID: CGRect] = [:]
        for root in backgroundRoots {
            let backgroundPanes = Array(SplitLayout.project(root, in: bounds).panes.prefix(maximumVisiblePanes))
            let inset = backgroundPanes.count > 1 ? CorralMVPWorkspaceView.terminalViewportLeadingInset : 0
            for pane in backgroundPanes {
                guard let view = views[pane.sessionID] else { continue }
                let content = contentFrame(pane.frame, id: pane.sessionID)
                backgroundFrames[pane.sessionID] = view.anchoredFrame(in: CGRect(
                    x: content.minX + inset, y: content.minY,
                    width: max(0, content.width - inset), height: content.height))
            }
        }
        for (id, view) in views {
            guard visibleIDs.contains(id), let pane = panes.first(where: { $0.sessionID == id }) else {
                view.isHidden = true
                view.setInputEnabled(false)
                if let frame = backgroundFrames[id], view.frame.size != frame.size {
                    pendingBackgroundFrames[id] = frame
                } else { pendingBackgroundFrames.removeValue(forKey: id) }
                continue
            }
            pendingBackgroundFrames.removeValue(forKey: id)
            let leadingInset = panes.count > 1 ? CorralMVPWorkspaceView.terminalViewportLeadingInset : 0
            let content = contentFrame(pane.frame, id: id)
            view.place(in: CGRect(
                x: content.minX + leadingInset,
                y: content.minY,
                width: max(0, content.width - leadingInset),
                height: content.height
            ))
            view.isHidden = false
            view.setInputEnabled(id == focusedSessionID)
        }
        // Do not turn a window resize into an all-tabs synchronous reflow storm.
        // Prewarm the largest backlog first, then yield between remaining views.
        if lastBackgroundLayoutSize != bounds.size {
            lastBackgroundLayoutSize = bounds.size
            layoutOneBackgroundViewport()
        }
        guard backgroundLayoutTask == nil, !pendingBackgroundFrames.isEmpty else { return }
        backgroundLayoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.pendingBackgroundFrames.isEmpty, !Task.isCancelled {
                await Task.yield()
                self.layoutOneBackgroundViewport()
            }
            self.backgroundLayoutTask = nil
        }
    }

    /// Managed panes reserve the viewport header strip; every other pane keeps its full frame.
    private func contentFrame(_ pane: CGRect, id: SessionID) -> CGRect {
        guard headerSessionIDs.contains(id) else { return pane }
        let header = min(pane.height, CorralViewportHeaderView.height)
        return CGRect(x: pane.minX, y: pane.minY + header, width: pane.width, height: max(0, pane.height - header))
    }

    /// All managed sessions, including those in background Tabs whose terminals are prewarmed at final size.
    private(set) var headerSessionIDs = Set<SessionID>()

    private func layoutOneBackgroundViewport() {
        guard let id = pendingBackgroundFrames.keys.max(by: {
            (views[$0]?.terminal.buffer.yDisp ?? 0) < (views[$1]?.terminal.buffer.yDisp ?? 0)
        }), let frame = pendingBackgroundFrames.removeValue(forKey: id),
              let view = views[id], view.isHidden, !visibleSessionIDs.contains(id) else { return }
        view.frame = frame
    }
}

