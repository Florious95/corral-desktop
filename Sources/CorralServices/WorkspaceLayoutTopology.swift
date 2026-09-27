import CorralContracts

/// Pure split-tree algebra shared by the workspace store and the UI drop preview (legacy `workspaceLayout.js`).
public extension WorkspaceLayoutNode {
    /// Leaves in pre-order: a split's first subtree before its second.
    var leafIDs: [SessionID] {
        switch self {
        case let .session(id): [id]
        case let .split(_, _, first, second): first.leafIDs + second.leafIDs
        }
    }

    func contains(_ sessionID: SessionID) -> Bool {
        switch self {
        case let .session(id): id == sessionID
        case let .split(_, _, first, second): first.contains(sessionID) || second.contains(sessionID)
        }
    }

    /// Removes a leaf; its sibling subtree is promoted into the parent's slot with every inner ratio intact.
    func removing(_ sessionID: SessionID) -> WorkspaceLayoutNode? {
        switch self {
        case let .session(id): return id == sessionID ? nil : self
        case let .split(direction, ratio, first, second):
            let a = first.removing(sessionID), b = second.removing(sessionID)
            guard let a else { return b }
            guard let b else { return a }
            return .split(direction: direction, ratio: ratio, first: a, second: b)
        }
    }

    func replacing(_ targetID: SessionID, with sessionID: SessionID) -> WorkspaceLayoutNode {
        switch self {
        case let .session(id): id == targetID ? .session(sessionID) : self
        case let .split(direction, ratio, first, second):
            .split(direction: direction, ratio: ratio, first: first.replacing(targetID, with: sessionID), second: second.replacing(targetID, with: sessionID))
        }
    }

    /// Horizontal splits flattened left to right; any other subtree is one compound column.
    var topLevelColumns: [WorkspaceLayoutNode] {
        if case let .split(.horizontal, _, first, second) = self { return first.topLevelColumns + second.topLevelColumns }
        return [self]
    }

    /// A right-leaning 1:1:…:1 column chain.
    static func equalColumns(_ columns: [WorkspaceLayoutNode]) -> WorkspaceLayoutNode? {
        guard let head = columns.first else { return nil }
        guard let tail = equalColumns(Array(columns.dropFirst())) else { return head }
        return .split(direction: .horizontal, ratio: 1 / Double(columns.count), first: head, second: tail)
    }

    /// Five-zone drop of `source` onto leaf `target`: the source first vacates its old slot; `center` replaces the
    /// target; left/right beside a single-leaf column rebalance all top-level columns; other edges split the target
    /// 1:1 in place. Nil when the drop is a no-op (self drop, or the target vanished).
    func dropping(_ source: SessionID, onto target: SessionID, edge: WorkspaceDropZone) -> WorkspaceLayoutNode? {
        guard source != target, let clean = removing(source), clean.contains(target) else { return nil }
        if edge == .center { return clean.replacing(target, with: source) }
        var columns = clean.topLevelColumns
        if edge == .left || edge == .right, let index = columns.firstIndex(where: { $0.contains(target) }),
           case .session = columns[index] {
            columns.insert(.session(source), at: edge == .right ? index + 1 : index)
            return Self.equalColumns(columns)
        }
        return clean.splitting(target, adding: source, edge: edge)
    }

    /// Sets the ratio of the split named by a legacy resizer path ("root", "root.first.second", or "first.second").
    /// Nil when the path does not name a split.
    func settingRatio(_ ratio: Double, at path: String) -> WorkspaceLayoutNode? {
        let steps = path == "root" ? [] : (path.hasPrefix("root.") ? String(path.dropFirst(5)) : path).split(separator: ".").map(String.init)
        return settingRatio(ratio, steps: steps[...])
    }

    private func settingRatio(_ ratio: Double, steps: ArraySlice<String>) -> WorkspaceLayoutNode? {
        guard case let .split(direction, oldRatio, first, second) = self else { return nil }
        switch steps.first {
        case nil: return .split(direction: direction, ratio: ratio, first: first, second: second)
        case "first": return first.settingRatio(ratio, steps: steps.dropFirst()).map { .split(direction: direction, ratio: oldRatio, first: $0, second: second) }
        case "second": return second.settingRatio(ratio, steps: steps.dropFirst()).map { .split(direction: direction, ratio: oldRatio, first: first, second: $0) }
        default: return nil
        }
    }

    private func splitting(_ target: SessionID, adding newID: SessionID, edge: WorkspaceDropZone) -> WorkspaceLayoutNode {
        switch self {
        case let .session(id):
            guard id == target else { return self }
            let direction: SplitDirection = edge == .left || edge == .right ? .horizontal : .vertical
            let insertFirst = edge == .left || edge == .top
            return .split(direction: direction, ratio: 0.5, first: insertFirst ? .session(newID) : self, second: insertFirst ? self : .session(newID))
        case let .split(direction, ratio, first, second):
            return .split(direction: direction, ratio: ratio, first: first.splitting(target, adding: newID, edge: edge), second: second.splitting(target, adding: newID, edge: edge))
        }
    }
}
