import AppKit
import CorralContracts
import CorralServices
import CorralUI
@preconcurrency import SwiftTerm

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
    var maximumVisiblePanes = Int.max
    private(set) var visibleSessionIDs = Set<SessionID>()

    override var isFlipped: Bool { true }

    func update(
        root: WorkspaceLayoutNode?,
        focusedSessionID: SessionID?,
        views: [SessionID: CorralNativeTerminalView]
    ) {
        layoutRoot = root
        self.focusedSessionID = focusedSessionID
        for (id, view) in views where self.views[id] !== view {
            self.views[id]?.setInputEnabled(false)
            self.views[id]?.removeFromSuperview()
            self.views[id] = view
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        for id in self.views.keys.filter({ views[$0] == nil }) {
            guard let view = self.views.removeValue(forKey: id) else { continue }
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
        for (id, view) in views {
            guard visibleIDs.contains(id), let pane = panes.first(where: { $0.sessionID == id }) else {
                view.isHidden = true
                view.setInputEnabled(false)
                continue
            }
            view.frame = pane.frame
            view.isHidden = false
            view.setInputEnabled(id == focusedSessionID)
        }
    }
}

