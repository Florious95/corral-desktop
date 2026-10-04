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
    private var backgroundRoots: [WorkspaceLayoutNode] = []
    private var pendingBackgroundFrames: [SessionID: CGRect] = [:]
    private var backgroundLayoutTask: Task<Void, Never>?
    private var lastBackgroundLayoutSize: NSSize?
    var maximumVisiblePanes = Int.max
    private(set) var visibleSessionIDs = Set<SessionID>()

    override var isFlipped: Bool { true }

    func update(
        root: WorkspaceLayoutNode?,
        focusedSessionID: SessionID?,
        views: [SessionID: CorralNativeTerminalView],
        backgroundRoots: [WorkspaceLayoutNode] = []
    ) {
        layoutRoot = root
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
        var backgroundFrames: [SessionID: CGRect] = [:]
        for root in backgroundRoots {
            let backgroundPanes = Array(SplitLayout.project(root, in: bounds).panes.prefix(maximumVisiblePanes))
            let inset = backgroundPanes.count > 1 ? CorralMVPWorkspaceView.terminalViewportLeadingInset : 0
            for pane in backgroundPanes {
                guard let view = views[pane.sessionID] else { continue }
                backgroundFrames[pane.sessionID] = view.anchoredFrame(in: CGRect(
                    x: pane.frame.minX + inset, y: pane.frame.minY,
                    width: max(0, pane.frame.width - inset), height: pane.frame.height))
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
            view.place(in: CGRect(
                x: pane.frame.minX + leadingInset,
                y: pane.frame.minY,
                width: max(0, pane.frame.width - leadingInset),
                height: pane.frame.height
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

    private func layoutOneBackgroundViewport() {
        guard let id = pendingBackgroundFrames.keys.max(by: {
            (views[$0]?.terminal.buffer.yDisp ?? 0) < (views[$1]?.terminal.buffer.yDisp ?? 0)
        }), let frame = pendingBackgroundFrames.removeValue(forKey: id),
              let view = views[id], view.isHidden, !visibleSessionIDs.contains(id) else { return }
        view.frame = frame
    }
}

