import CorralContracts
import Foundation

public enum SessionTreeError: Error, Equatable, Sendable {
    case invalidLayout
    case duplicateSession(SessionID)
    case sessionNotFound(SessionID)
}

/// Pure workspace topology for terminal panes. Split ratios represent the first child's share.
public struct SessionTree: Codable, Equatable, Sendable {
    public private(set) var root: WorkspaceLayoutNode?

    public init(root: WorkspaceLayoutNode? = nil) throws {
        guard Self.isValid(root) else { throw SessionTreeError.invalidLayout }
        self.root = root
    }

    public var sessionIDs: [SessionID] {
        guard let root else { return [] }
        return Self.collect(from: root)
    }

    public func contains(_ sessionID: SessionID) -> Bool {
        sessionIDs.contains(sessionID)
    }

    public mutating func setInitialSession(_ sessionID: SessionID) throws {
        guard !sessionID.rawValue.isEmpty else { throw SessionTreeError.invalidLayout }
        guard root == nil else { throw SessionTreeError.duplicateSession(sessionID) }
        root = .session(sessionID)
    }

    /// Replaces a pane with a split containing that pane and a new pane.
    public mutating func split(
        _ sessionID: SessionID,
        adding newSessionID: SessionID,
        direction: SplitDirection,
        ratio: Double = 0.5
    ) throws {
        guard ratio.isFinite, ratio > 0, ratio < 1, !newSessionID.rawValue.isEmpty else {
            throw SessionTreeError.invalidLayout
        }
        guard !sessionIDs.contains(newSessionID) else { throw SessionTreeError.duplicateSession(newSessionID) }
        guard let root else { throw SessionTreeError.sessionNotFound(sessionID) }
        let (updated, replaced) = Self.replacing(sessionID, in: root) { node in
            .split(direction: direction, ratio: ratio, first: node, second: .session(newSessionID))
        }
        guard replaced else { throw SessionTreeError.sessionNotFound(sessionID) }
        self.root = updated
    }

    /// Removes a pane and collapses any split left with a single child.
    @discardableResult
    public mutating func remove(_ sessionID: SessionID) -> Bool {
        guard let root else { return false }
        let (updated, removed) = Self.removing(sessionID, from: root)
        self.root = updated
        return removed
    }

    private static func isValid(_ root: WorkspaceLayoutNode?) -> Bool {
        guard let root else { return true }
        guard root.isValid else { return false }
        let ids = collect(from: root)
        return Set(ids).count == ids.count
    }

    private static func collect(from node: WorkspaceLayoutNode) -> [SessionID] {
        switch node {
        case let .session(sessionID): [sessionID]
        case let .split(_, _, first, second): collect(from: first) + collect(from: second)
        }
    }

    private static func replacing(
        _ sessionID: SessionID,
        in node: WorkspaceLayoutNode,
        with replacement: (WorkspaceLayoutNode) -> WorkspaceLayoutNode
    ) -> (WorkspaceLayoutNode, Bool) {
        switch node {
        case let .session(candidate):
            return candidate == sessionID ? (replacement(node), true) : (node, false)
        case let .split(direction, ratio, first, second):
            let (updatedFirst, replacedFirst) = replacing(sessionID, in: first, with: replacement)
            if replacedFirst {
                return (.split(direction: direction, ratio: ratio, first: updatedFirst, second: second), true)
            }
            let (updatedSecond, replacedSecond) = replacing(sessionID, in: second, with: replacement)
            return (.split(direction: direction, ratio: ratio, first: first, second: updatedSecond), replacedSecond)
        }
    }

    private static func removing(
        _ sessionID: SessionID,
        from node: WorkspaceLayoutNode
    ) -> (WorkspaceLayoutNode?, Bool) {
        switch node {
        case let .session(candidate):
            return candidate == sessionID ? (nil, true) : (node, false)
        case let .split(direction, ratio, first, second):
            let (updatedFirst, removedFirst) = removing(sessionID, from: first)
            if removedFirst {
                guard let updatedFirst else { return (second, true) }
                return (.split(direction: direction, ratio: ratio, first: updatedFirst, second: second), true)
            }
            let (updatedSecond, removedSecond) = removing(sessionID, from: second)
            if removedSecond {
                guard let updatedSecond else { return (first, true) }
                return (.split(direction: direction, ratio: ratio, first: first, second: updatedSecond), true)
            }
            return (node, false)
        }
    }

    private enum CodingKeys: String, CodingKey { case root }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(root: values.decodeIfPresent(WorkspaceLayoutNode.self, forKey: .root))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(root, forKey: .root)
    }
}
