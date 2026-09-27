import CorralContracts
import Foundation

public enum WorkspaceStoreError: Error, Equatable, Sendable {
    case invalidState
    case invalidSessionID
    case invalidFavoriteKey
    case tabNotFound
}

public enum SessionOpenGesture: Equatable, Sendable {
    case singleClick
    case doubleClick
}

public enum WorkspaceDropZone: String, Codable, Sendable {
    case left
    case right
    case top
    case bottom
    case center
}

public struct WorkspaceTab: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public var isCustomTitle: Bool
    public var root: WorkspaceLayoutNode?
    public var activeSessionID: SessionID?
    public var pinned: Bool
    public var isImplicitBlank: Bool

    public var isBlank: Bool { root == nil && activeSessionID == nil }
    public var sessionIDs: [SessionID] { root?.leafIDs ?? [] }

    public init(
        id: UUID = UUID(),
        title: String = "",
        isCustomTitle: Bool = false,
        root: WorkspaceLayoutNode? = nil,
        activeSessionID: SessionID? = nil,
        pinned: Bool = false,
        isImplicitBlank: Bool = false
    ) {
        self.id = id
        self.title = title
        self.isCustomTitle = isCustomTitle
        self.root = root
        self.activeSessionID = activeSessionID
        self.pinned = pinned
        self.isImplicitBlank = isImplicitBlank
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title = "name"
        case isCustomTitle
        case root
        case activeSessionID = "activeUid"
        case pinned
        case isImplicitBlank
    }
}

public struct WorkspaceSessionIdentity: Codable, Hashable, Sendable {
    public let deviceID: DeviceID
    public let workingDirectory: String
    public let name: String

    public init(deviceID: DeviceID, workingDirectory: String, name: String) {
        self.deviceID = deviceID
        self.workingDirectory = workingDirectory
        self.name = name
    }

    public init(_ session: SessionDescriptor) {
        self.init(deviceID: session.key.deviceID, workingDirectory: session.workingDirectory, name: session.name)
    }
}

public struct WorkspaceSessionBinding: Codable, Equatable, Sendable {
    public let sessionID: SessionID
    public let identity: WorkspaceSessionIdentity

    public init(sessionID: SessionID, identity: WorkspaceSessionIdentity) {
        self.sessionID = sessionID
        self.identity = identity
    }
}

/// Persistable workspace state. Preview content is separate from each Tab's durable pane tree.
public struct CorralWorkspaceState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var tabs: [WorkspaceTab]
    public var activeTabID: UUID
    public var favorites: Set<String>
    public var previewUID: SessionID?
    public var sessionBindings: [WorkspaceSessionBinding]

    public var activeTab: WorkspaceTab? { tabs.first { $0.id == activeTabID } }
    public var visibleRoot: WorkspaceLayoutNode? {
        previewUID.map(WorkspaceLayoutNode.session) ?? activeTab?.root
    }
    public var visibleSessionID: SessionID? { previewUID ?? activeTab?.activeSessionID }

    private init(uncheckedTabs: [WorkspaceTab], activeTabID: UUID, favorites: Set<String>, previewUID: SessionID?, sessionBindings: [WorkspaceSessionBinding]) {
        tabs = uncheckedTabs
        self.activeTabID = activeTabID
        self.favorites = favorites
        self.previewUID = previewUID
        self.sessionBindings = sessionBindings
    }

    public init(
        tabs: [WorkspaceTab],
        activeTabID: UUID,
        favorites: Set<String> = [],
        previewUID: SessionID? = nil,
        sessionBindings: [WorkspaceSessionBinding] = []
    ) throws {
        let candidate = Self(uncheckedTabs: tabs, activeTabID: activeTabID, favorites: favorites, previewUID: previewUID, sessionBindings: sessionBindings)
        guard candidate.isValid else { throw WorkspaceStoreError.invalidState }
        self = candidate
    }

    public static func initial() -> Self {
        let tab = WorkspaceTab(isImplicitBlank: true)
        return Self(uncheckedTabs: [tab], activeTabID: tab.id, favorites: [], previewUID: nil, sessionBindings: [])
    }

    public var isValid: Bool {
        guard !tabs.isEmpty,
              Set(tabs.map(\.id)).count == tabs.count,
              tabs.contains(where: { $0.id == activeTabID }),
              favorites.allSatisfy({ !$0.isEmpty }) else { return false }

        var foundUnpinned = false
        var displayedIDs = Set<SessionID>()
        for tab in tabs {
            if !tab.pinned { foundUnpinned = true }
            else if foundUnpinned { return false }
            if tab.isImplicitBlank && !tab.isBlank { return false }
            if let root = tab.root {
                var nodeCount = 0
                guard Self.collect(root, depth: 0, nodeCount: &nodeCount, into: &displayedIDs) else { return false }
                let leaves = Set(tab.sessionIDs)
                guard let active = tab.activeSessionID, leaves.contains(active) else { return false }
            } else if tab.activeSessionID != nil {
                return false
            }
        }
        if let previewUID, (previewUID.rawValue.isEmpty || displayedIDs.contains(previewUID)) { return false }
        let visibleIDs = displayedIDs.union(previewUID.map { [$0] } ?? [])
        guard Set(sessionBindings.map(\.sessionID)).count == sessionBindings.count,
              sessionBindings.allSatisfy({
                  visibleIDs.contains($0.sessionID) && !$0.identity.deviceID.rawValue.isEmpty && !$0.identity.workingDirectory.isEmpty
              }) else { return false }
        return true
    }

    private static func collect(_ node: WorkspaceLayoutNode, depth: Int, nodeCount: inout Int, into ids: inout Set<SessionID>) -> Bool {
        nodeCount += 1
        guard nodeCount <= 512, depth <= 128 else { return false }
        switch node {
        case let .session(id):
            guard !id.rawValue.isEmpty else { return false }
            return ids.insert(id).inserted
        case let .split(_, ratio, first, second):
            guard ratio.isFinite, ratio > 0, ratio < 1 else { return false }
            return collect(first, depth: depth + 1, nodeCount: &nodeCount, into: &ids)
                && collect(second, depth: depth + 1, nodeCount: &nodeCount, into: &ids)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, tabs, favorites, sessionBindings
        case activeTabID = "activeTabId"
        case previewUID = "previewUid"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        let tabs = try values.decode([WorkspaceTab].self, forKey: .tabs)
        let activeTabID = try values.decode(UUID.self, forKey: .activeTabID)
        let favorites = Set(try values.decode([String].self, forKey: .favorites))
        let previewUID = try values.decodeIfPresent(SessionID.self, forKey: .previewUID)
        let bindings = try values.decodeIfPresent([WorkspaceSessionBinding].self, forKey: .sessionBindings) ?? []
        guard version == Self.currentVersion,
              let candidate = try? Self(tabs: tabs, activeTabID: activeTabID, favorites: favorites, previewUID: previewUID, sessionBindings: bindings) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Invalid workspace snapshot")
        }
        self = candidate
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.currentVersion, forKey: .version)
        try values.encode(tabs, forKey: .tabs)
        try values.encode(activeTabID, forKey: .activeTabID)
        try values.encode(favorites.sorted(), forKey: .favorites)
        try values.encodeIfPresent(previewUID, forKey: .previewUID)
        try values.encode(sessionBindings.sorted { $0.sessionID.rawValue < $1.sessionID.rawValue }, forKey: .sessionBindings)
    }
}

/// Owns the durable Tabs tree and ephemeral preview slot; listing absence never clears a pane.
public actor CorralWorkspaceStore {
    public static let storageFilename = "workspace.json"
    private static let maximumReadBytes = 256 * 1024

    private let storageURL: URL
    private var value: CorralWorkspaceState

    public init(applicationSupportDirectory: URL? = nil) throws {
        let directory = try CorralPrivateStorage.directoryURL(applicationSupportDirectory: applicationSupportDirectory)
        let storageURL = directory.appendingPathComponent(Self.storageFilename)
        self.storageURL = storageURL

        let data = try CorralPrivateStorage.readData(from: storageURL)
        if let data, data.count <= Self.maximumReadBytes,
           let restored = try? JSONDecoder().decode(CorralWorkspaceState.self, from: data), restored.isValid {
            value = restored
        } else {
            value = .initial()
            try Self.persist(value, to: storageURL)
        }
    }

    public func snapshot() -> CorralWorkspaceState { value }

    /// Single-click previews reuse one virtual slot; double-click commits to a pinned Tab.
    @discardableResult
    public func smartOpenSession(_ sessionID: SessionID, gesture: SessionOpenGesture = .singleClick) throws -> CorralWorkspaceState {
        guard !sessionID.rawValue.isEmpty else { throw WorkspaceStoreError.invalidSessionID }
        var next = Self.smartOpen(sessionID, gesture: gesture, in: value)
        next.sessionBindings = Self.bindingsForVisibleSessions(next)
        try commit(next)
        return value
    }

    @discardableResult
    public func smartOpenSession(_ session: SessionDescriptor, gesture: SessionOpenGesture = .singleClick) throws -> CorralWorkspaceState {
        guard !session.id.rawValue.isEmpty else { throw WorkspaceStoreError.invalidSessionID }
        var next = Self.smartOpen(session.id, gesture: gesture, in: value)
        next.sessionBindings = Self.bindingsForVisibleSessions(next)
        next = Self.upsertingBinding(sessionID: session.id, identity: WorkspaceSessionIdentity(session), in: next)
        try commit(next)
        return value
    }

    @discardableResult
    public func focusPane(_ sessionID: SessionID) throws -> CorralWorkspaceState {
        guard value.previewUID != sessionID,
              let index = value.tabs.firstIndex(where: { $0.id == value.activeTabID }),
              value.tabs[index].root?.contains(sessionID) == true,
              value.tabs[index].activeSessionID != sessionID else { return value }
        var next = value
        next.previewUID = nil
        next.tabs[index].activeSessionID = sessionID
        next.sessionBindings = Self.bindingsForVisibleSessions(next)
        try commit(next)
        return value
    }

    @discardableResult
    public func createTab() throws -> UUID {
        var next = value
        let tab = WorkspaceTab()
        next.tabs.append(tab)
        next.activeTabID = tab.id
        next.previewUID = nil
        next.sessionBindings = Self.bindingsForVisibleSessions(next)
        try commit(next)
        return tab.id
    }

    @discardableResult
    public func switchTab(_ id: UUID) throws -> CorralWorkspaceState {
        guard value.tabs.contains(where: { $0.id == id }) else { return value }
        var next = value
        next.activeTabID = id
        next.previewUID = nil
        next.sessionBindings = Self.bindingsForVisibleSessions(next)
        try commit(next)
        return value
    }

    @discardableResult
    public func closeTab(_ id: UUID) throws -> CorralWorkspaceState {
        guard let index = value.tabs.firstIndex(where: { $0.id == id }) else { return value }
        var next = value
        next.tabs.remove(at: index)
        next.previewUID = nil
        if next.tabs.isEmpty {
            let blank = WorkspaceTab(isImplicitBlank: true)
            next.tabs = [blank]
            next.activeTabID = blank.id
        } else if next.activeTabID == id {
            next.activeTabID = next.tabs[min(index, next.tabs.count - 1)].id
        }
        next.sessionBindings = Self.bindingsForVisibleSessions(next)
        try commit(next)
        return value
    }

    /// Closes client-side pane topology only; it never terminates the remote session. The sibling subtree is
    /// promoted intact, pure column rows are rebalanced 1:1, and focus survives unless the focused pane closed.
    @discardableResult
    public func closePane(_ sessionID: SessionID) throws -> CorralWorkspaceState {
        if value.previewUID == sessionID {
            var next = value
            next.previewUID = nil
            next.sessionBindings = Self.bindingsForVisibleSessions(next)
            try commit(next)
            return value
        }
        guard let index = value.tabs.firstIndex(where: { $0.id == value.activeTabID }),
              let root = value.tabs[index].root, root.contains(sessionID),
              let remaining = root.removing(sessionID) else { return value }
        var next = value
        let columns = remaining.topLevelColumns
        next.tabs[index].root = columns.allSatisfy({ if case .session = $0 { true } else { false } })
            ? WorkspaceLayoutNode.equalColumns(columns) : remaining
        let leaves = remaining.leafIDs
        next.tabs[index].activeSessionID = value.tabs[index].activeSessionID.flatMap { leaves.contains($0) ? $0 : nil } ?? leaves.first
        next.previewUID = nil
        next.sessionBindings = Self.bindingsForVisibleSessions(next)
        next = Self.pinning(next, tabID: next.tabs[index].id, pinned: true)
        try commit(next)
        return value
    }

    /// Explicit server close acknowledgement. Listing/reconnect updates must use `reconcileListing` instead.
    @discardableResult
    public func removeClosedSession(_ sessionID: SessionID) throws -> CorralWorkspaceState {
        var next = value
        var changed = next.previewUID == sessionID
        next.previewUID = next.previewUID == sessionID ? nil : next.previewUID
        for index in next.tabs.indices {
            guard let root = next.tabs[index].root, root.contains(sessionID) else { continue }
            changed = true
            let updatedRoot = root.removing(sessionID)
            let leaves = updatedRoot?.leafIDs ?? []
            let oldActive = next.tabs[index].activeSessionID
            next.tabs[index].root = updatedRoot
            next.tabs[index].activeSessionID = oldActive.flatMap { leaves.contains($0) ? $0 : nil } ?? leaves.first
        }
        guard changed else { return value }
        next.sessionBindings.removeAll { $0.sessionID == sessionID }
        try commit(next)
        return value
    }

    /// Tab-only rename; it does not mutate Agent/session names or remote state.
    @discardableResult
    public func renameTab(_ id: UUID, to title: String) throws -> CorralWorkspaceState {
        guard let index = value.tabs.firstIndex(where: { $0.id == id }) else { throw WorkspaceStoreError.tabNotFound }
        var next = value
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        next.tabs[index].title = title
        next.tabs[index].isCustomTitle = !title.isEmpty
        try commit(next)
        return value
    }

    @discardableResult
    public func resetTabTitle(_ id: UUID) throws -> CorralWorkspaceState {
        guard let index = value.tabs.firstIndex(where: { $0.id == id }) else { throw WorkspaceStoreError.tabNotFound }
        var next = value
        next.tabs[index].title = ""
        next.tabs[index].isCustomTitle = false
        try commit(next)
        return value
    }

    @discardableResult
    public func pinTab(_ id: UUID, pinned: Bool = true) throws -> CorralWorkspaceState {
        guard value.tabs.contains(where: { $0.id == id }) else { throw WorkspaceStoreError.tabNotFound }
        try commit(Self.pinning(value, tabID: id, pinned: pinned))
        return value
    }

    @discardableResult
    public func reorderTabs(from source: Int, to destination: Int) throws -> CorralWorkspaceState {
        guard value.tabs.indices.contains(source), value.tabs.indices.contains(destination), source != destination,
              value.tabs[source].pinned == value.tabs[destination].pinned else { return value }
        var next = value
        let tab = next.tabs.remove(at: source)
        next.tabs.insert(tab, at: destination)
        try commit(next)
        return value
    }

    @discardableResult
    public func closeOtherTabs(keeping id: UUID) throws -> CorralWorkspaceState {
        guard value.tabs.contains(where: { $0.id == id }) else { return value }
        var next = value
        next.tabs = next.tabs.filter { $0.id == id || $0.pinned }
        next.activeTabID = id
        next.sessionBindings = Self.bindingsForVisibleSessions(next)
        try commit(next)
        return value
    }

    @discardableResult
    public func closeRightTabs(of id: UUID) throws -> CorralWorkspaceState {
        guard let index = value.tabs.firstIndex(where: { $0.id == id }) else { return value }
        var next = value
        next.tabs = next.tabs.enumerated().compactMap { i, tab in i <= index || tab.pinned ? tab : nil }
        if !next.tabs.contains(where: { $0.id == next.activeTabID }) {
            next.activeTabID = next.tabs[0].id
        }
        next.sessionBindings = Self.bindingsForVisibleSessions(next)
        try commit(next)
        return value
    }

    /// Five-zone drop (`WorkspaceLayoutNode.dropping`): edges split, center replaces the target pane. A virtual
    /// preview becomes durable.
    @discardableResult
    public func splitSession(
        _ sessionID: SessionID,
        target targetID: SessionID? = nil,
        edge: WorkspaceDropZone
    ) throws -> CorralWorkspaceState {
        try applySplitSession(sessionID, target: targetID, edge: edge, identity: nil)
    }

    @discardableResult
    public func splitSession(
        _ session: SessionDescriptor,
        target targetID: SessionID? = nil,
        edge: WorkspaceDropZone
    ) throws -> CorralWorkspaceState {
        try applySplitSession(session.id, target: targetID, edge: edge, identity: WorkspaceSessionIdentity(session))
    }

    private func applySplitSession(
        _ sessionID: SessionID,
        target targetID: SessionID?,
        edge: WorkspaceDropZone,
        identity: WorkspaceSessionIdentity?
    ) throws -> CorralWorkspaceState {
        guard !sessionID.rawValue.isEmpty,
              let activeIndex = value.tabs.firstIndex(where: { $0.id == value.activeTabID }) else {
            throw WorkspaceStoreError.invalidSessionID
        }
        let activeTab = value.tabs[activeIndex]

        if let (ownerIndex, ownerTab) = Self.tabContaining(sessionID, in: value), ownerTab.id != activeTab.id {
            var next = value
            guard let ownerRoot = next.tabs[ownerIndex].root else { return value }
            let ownerActive = next.tabs[ownerIndex].activeSessionID
            let remainingOwnerRoot = ownerRoot.removing(sessionID)
            let ownerLeaves = remainingOwnerRoot?.leafIDs ?? []
            next.tabs[ownerIndex].root = remainingOwnerRoot
            next.tabs[ownerIndex].activeSessionID = ownerActive.flatMap { ownerLeaves.contains($0) ? $0 : nil } ?? ownerLeaves.first

            let destinationRoot = activeTab.root ?? value.previewUID.map(WorkspaceLayoutNode.session)
            if let destinationRoot {
                let leaves = destinationRoot.leafIDs
                if let target = targetID.flatMap({ leaves.contains($0) ? $0 : nil })
                    ?? activeTab.activeSessionID.flatMap({ leaves.contains($0) ? $0 : nil })
                    ?? leaves.first {
                    next.tabs[activeIndex].root = destinationRoot.dropping(sessionID, onto: target, edge: edge) ?? destinationRoot
                } else {
                    next.tabs[activeIndex].root = .session(sessionID)
                }
            } else {
                next.tabs[activeIndex].root = .session(sessionID)
            }
            next.tabs[activeIndex].activeSessionID = sessionID
            next.tabs[activeIndex].isImplicitBlank = false
            next.previewUID = nil
            next.sessionBindings = Self.bindingsForVisibleSessions(next)
            next = Self.pinning(next, tabID: ownerTab.id, pinned: true)
            next = Self.pinning(next, tabID: activeTab.id, pinned: true)
            if let identity { next = Self.upsertingBinding(sessionID: sessionID, identity: identity, in: next) }
            try commit(next)
            return value
        }

        let hasDurableSource = activeTab.root?.contains(sessionID) ?? false
        var next = value
        var base = activeTab.root
        if base == nil, let preview = value.previewUID { base = .session(preview) }

        if hasDurableSource, let root = activeTab.root {
            guard let resolvedTarget = targetID ?? activeTab.activeSessionID ?? activeTab.sessionIDs.first,
                  let dropped = root.dropping(sessionID, onto: resolvedTarget, edge: edge) else { return value }
            base = dropped
        } else if value.previewUID == sessionID, activeTab.root == nil {
            base = .session(sessionID)
        } else if let currentRoot = base {
            let leaves = currentRoot.leafIDs
            guard let resolvedTarget = targetID.flatMap({ leaves.contains($0) ? $0 : nil })
                    ?? activeTab.activeSessionID.flatMap({ leaves.contains($0) ? $0 : nil })
                    ?? leaves.first,
                  let dropped = currentRoot.dropping(sessionID, onto: resolvedTarget, edge: edge) else { return value }
            base = dropped
        } else {
            base = .session(sessionID)
        }

        next.tabs[activeIndex].root = base
        next.tabs[activeIndex].activeSessionID = sessionID
        next.tabs[activeIndex].isImplicitBlank = false
        next.previewUID = nil
        next.sessionBindings = Self.bindingsForVisibleSessions(next)
        if let identity { next = Self.upsertingBinding(sessionID: sessionID, identity: identity, in: next) }
        next = Self.pinning(next, tabID: activeTab.id, pinned: true)
        try commit(next)
        return value
    }

    @discardableResult
    public func updateSplitRatio(tabID: UUID? = nil, path: String, ratio: Double) throws -> CorralWorkspaceState {
        guard !path.isEmpty, ratio.isFinite, ratio > 0, ratio < 1 else { return value }
        let targetTabID = tabID ?? value.activeTabID
        guard let index = value.tabs.firstIndex(where: { $0.id == targetTabID }),
              let root = value.tabs[index].root else { return value }
        let roundedRatio = (ratio * 10_000).rounded() / 10_000
        guard roundedRatio > 0, roundedRatio < 1,
              let updated = root.settingRatio(roundedRatio, at: path) else { return value }
        var next = value
        next.tabs[index].root = updated
        next.previewUID = nil
        next.sessionBindings = Self.bindingsForVisibleSessions(next)
        next = Self.pinning(next, tabID: targetTabID, pinned: true)
        try commit(next)
        return value
    }

    public func toggleFavorite(_ key: String) throws -> CorralWorkspaceState {
        guard !key.isEmpty else { throw WorkspaceStoreError.invalidFavoriteKey }
        var next = value
        if !next.favorites.insert(key).inserted { next.favorites.remove(key) }
        try commit(next)
        return value
    }

    public func setFavorite(_ key: String, isFavorite: Bool) throws -> CorralWorkspaceState {
        guard !key.isEmpty else { throw WorkspaceStoreError.invalidFavoriteKey }
        var next = value
        if isFavorite { next.favorites.insert(key) } else { next.favorites.remove(key) }
        try commit(next)
        return value
    }

    public func favoriteFirst(_ agentKeys: [String]) -> [String] {
        agentKeys.filter(value.favorites.contains) + agentKeys.filter { !value.favorites.contains($0) }
    }

    /// Rebinds uniquely matching (device, directory, name) sessions after a live ref/UID drift.
    /// Missing listings are transient and never erase a saved pane; only explicit close ACK does that.
    @discardableResult
    public func reconcileListing(_ sessions: [SessionDescriptor]) throws -> CorralWorkspaceState {
        guard !sessions.isEmpty else { return value }
        var next = value
        let incomingIdentityCounts = Dictionary(grouping: sessions, by: { WorkspaceSessionIdentity($0) }).mapValues(\.count)
        for session in sessions {
            let identity = WorkspaceSessionIdentity(session)
            if Self.contains(session.id, in: next) {
                next = Self.upsertingBinding(sessionID: session.id, identity: identity, in: next)
                continue
            }
            guard incomingIdentityCounts[identity] == 1,
                  let old = next.sessionBindings.filter({ $0.identity == identity && Self.contains($0.sessionID, in: next) }).only,
                  !Self.contains(session.id, in: next) else { continue }
            next = Self.rebinding(old.sessionID, to: session.id, identity: identity, in: next)
        }
        try commit(next)
        return value
    }

    private func commit(_ next: CorralWorkspaceState) throws {
        guard next.isValid else { throw WorkspaceStoreError.invalidState }
        guard next != value else { return }
        try Self.persist(next, to: storageURL)
        value = next
    }

    private static func persist(_ state: CorralWorkspaceState, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try CorralPrivateStorage.atomicallyWrite(encoder.encode(state), to: url)
    }

    private static func smartOpen(_ sessionID: SessionID, gesture: SessionOpenGesture, in state: CorralWorkspaceState) -> CorralWorkspaceState {
        var next = state
        if let (index, tab) = tabContaining(sessionID, in: state) {
            next.activeTabID = tab.id
            next.tabs[index].activeSessionID = sessionID
            next.previewUID = nil
            if gesture == .doubleClick { next = pinning(next, tabID: tab.id, pinned: true) }
            return next
        }
        guard let index = state.tabs.firstIndex(where: { $0.id == state.activeTabID }) else { return state }
        if state.tabs[index].isBlank {
            next.tabs[index].root = .session(sessionID)
            next.tabs[index].activeSessionID = sessionID
            next.tabs[index].isImplicitBlank = false
            next.previewUID = nil
            return pinning(next, tabID: state.tabs[index].id, pinned: true)
        }
        if gesture == .singleClick {
            next.previewUID = sessionID
            return next
        }
        let tab = WorkspaceTab(root: .session(sessionID), activeSessionID: sessionID, pinned: true)
        let insertIndex = next.tabs.prefix(while: \.pinned).count
        next.tabs.insert(tab, at: insertIndex)
        next.activeTabID = tab.id
        next.previewUID = nil
        return next
    }

    private static func pinning(_ state: CorralWorkspaceState, tabID: UUID, pinned: Bool) -> CorralWorkspaceState {
        guard let tab = state.tabs.first(where: { $0.id == tabID }), tab.pinned != pinned else { return state }
        var next = state
        next.tabs.removeAll { $0.id == tabID }
        var updatedTab = tab
        updatedTab.pinned = pinned
        let index = pinned ? next.tabs.prefix(while: \.pinned).count : next.tabs.count
        next.tabs.insert(updatedTab, at: index)
        return next
    }

    private static func tabContaining(_ sessionID: SessionID, in state: CorralWorkspaceState) -> (Int, WorkspaceTab)? {
        guard let index = state.tabs.firstIndex(where: { $0.root?.contains(sessionID) == true }) else { return nil }
        return (index, state.tabs[index])
    }

    private static func contains(_ sessionID: SessionID, in state: CorralWorkspaceState) -> Bool {
        sessionID == state.previewUID || state.tabs.contains { $0.root?.contains(sessionID) == true }
    }

    private static func upsertingBinding(sessionID: SessionID, identity: WorkspaceSessionIdentity, in state: CorralWorkspaceState) -> CorralWorkspaceState {
        guard contains(sessionID, in: state) else { return state }
        var next = state
        next.sessionBindings.removeAll { $0.sessionID == sessionID }
        next.sessionBindings.append(WorkspaceSessionBinding(sessionID: sessionID, identity: identity))
        return next
    }

    private static func rebinding(_ oldID: SessionID, to newID: SessionID, identity: WorkspaceSessionIdentity, in state: CorralWorkspaceState) -> CorralWorkspaceState {
        var next = state
        for index in next.tabs.indices {
            if let root = next.tabs[index].root {
                next.tabs[index].root = root.replacing(oldID, with: newID)
            }
            if next.tabs[index].activeSessionID == oldID { next.tabs[index].activeSessionID = newID }
        }
        if next.previewUID == oldID { next.previewUID = newID }
        next.sessionBindings.removeAll { $0.sessionID == oldID || $0.sessionID == newID }
        next.sessionBindings.append(WorkspaceSessionBinding(sessionID: newID, identity: identity))
        return next
    }

    private static func bindingsForVisibleSessions(_ state: CorralWorkspaceState) -> [WorkspaceSessionBinding] {
        let visible = Set(state.tabs.flatMap(\.sessionIDs) + (state.previewUID.map { [$0] } ?? []))
        return state.sessionBindings.filter { visible.contains($0.sessionID) }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
