import CorralContracts
import Foundation

/// Bounded display projection of one windowed conversation view (Core contract 11).
/// HTTP pages are immutable at H and only fill history; contiguous live commits alone advance `liveSeq`.
/// Neither path is allowed to overwrite a newer item revision or revive a removed item.
public struct ConversationTranscript: Equatable, Sendable {
    public static let maximumItems = 1_500
    public static let maximumBodyBytes = 8 << 20
    private static let maximumTombstones = 2_048
    private static let maximumParkedItems = 256

    public let viewID: String
    public let sourceEpoch: String
    public let snapshotSeq: UInt64
    public private(set) var items: [ConversationItem] = []
    public private(set) var initialAdopted = false
    public private(set) var liveSeq: UInt64
    public private(set) var beforeCursor: String?
    public private(set) var hasMoreBefore = false
    /// Older pages stop at the display bound instead of evicting the live tail.
    public private(set) var reachedDisplayLimit = false
    public private(set) var historySupport: String
    public private(set) var sourceOmitted: Bool
    private var indexByID: [String: Int] = [:]
    private var tombstones: [String] = []
    private var tombstoneSet = Set<String>()
    /// Live revisions of items older than the loaded window; applied when their page arrives.
    private var parked: [String: ConversationItem] = [:]
    private var bodies: [String: Body] = [:]
    private var bodyBytes = 0
    private var bodyClock: UInt64 = 0

    public struct Body: Equatable, Sendable {
        public let revision: UInt64
        public let text: String
        public let complete: Bool
        fileprivate var lastUse: UInt64
    }

    public init(ready: ConversationReady) {
        viewID = ready.viewID
        sourceEpoch = ready.sourceEpoch
        snapshotSeq = ready.snapshotSeq
        liveSeq = ready.snapshotSeq
        historySupport = ready.historySupport
        sourceOmitted = ready.sourceOmitted
    }

    public func item(id: String) -> ConversationItem? { indexByID[id].map { items[$0] } }

    /// The newest H items; buffered live commits are applied afterwards by the caller.
    public mutating func adoptInitial(_ page: ConversationHistoryPage) -> Bool {
        guard owns(page), !initialAdopted else { return false }
        items = []
        indexByID = [:]
        for item in page.items { insert(parked.removeValue(forKey: item.id) ?? item) }
        beforeCursor = page.beforeCursor
        hasMoreBefore = page.hasMoreBefore && page.beforeCursor != nil
        historySupport = page.historySupport
        sourceOmitted = page.sourceOmitted || sourceOmitted
        initialAdopted = true
        trimToBound()
        return true
    }

    /// Prepends one older page. Rows already present (with live revisions) win over the fixed H copy.
    public mutating func adoptOlder(_ page: ConversationHistoryPage, cursor: String) -> Bool {
        guard owns(page), initialAdopted, cursor == beforeCursor else { return false }
        let room = Self.maximumItems - items.count
        var accepted = page.items
        if accepted.count > room {
            // Keep the newest part of the page that still fits; the rest stays on the host.
            accepted = Array(accepted.suffix(max(0, room)))
            reachedDisplayLimit = true
        }
        for item in accepted where indexByID[item.id] == nil && !tombstoneSet.contains(item.id) {
            insert(parked.removeValue(forKey: item.id) ?? item)
        }
        beforeCursor = page.beforeCursor
        hasMoreBefore = page.hasMoreBefore && page.beforeCursor != nil && !reachedDisplayLimit
        sourceOmitted = page.sourceOmitted || sourceOmitted
        return true
    }

    public enum UpdateResult: Equatable, Sendable { case applied, notReady, gap, foreign }

    public mutating func apply(_ update: ConversationUpdate) -> UpdateResult {
        guard update.viewID == viewID, update.sourceEpoch == sourceEpoch else { return .foreign }
        guard initialAdopted else { return .notReady }
        guard update.baseSeq == liveSeq else { return .gap }
        for id in update.removes { remove(id) }
        for item in update.upserts { upsert(item) }
        liveSeq = update.commitSeq
        trimToBound()
        return .applied
    }

    public func body(for id: String) -> Body? { bodies[id] }

    /// Records a fully assembled body for exactly the item revision that was requested.
    public mutating func storeBody(id: String, revision: UInt64, text: String, complete: Bool) -> Bool {
        guard let current = item(id: id), current.revision >= revision else { return false }
        if let existing = bodies[id], existing.revision > revision { return false }
        let size = text.utf8.count
        guard size <= Self.maximumBodyBytes else { return false }
        if let old = bodies.removeValue(forKey: id) { bodyBytes -= old.text.utf8.count }
        bodyClock += 1
        bodies[id] = Body(revision: revision, text: text, complete: complete, lastUse: bodyClock)
        bodyBytes += size
        evictBodies(keeping: id)
        return true
    }

    public mutating func touchBodies(_ ids: [String]) {
        for id in ids where bodies[id] != nil {
            bodyClock += 1
            bodies[id]?.lastUse = bodyClock
        }
    }

    private func owns(_ page: ConversationHistoryPage) -> Bool {
        page.viewID == viewID && page.sourceEpoch == sourceEpoch && page.snapshotSeq == snapshotSeq
    }

    private mutating func upsert(_ item: ConversationItem) {
        if let index = indexByID[item.id] {
            guard item.revision >= items[index].revision else { return }
            if items[index].orderKey == item.orderKey {
                items[index] = item
                return
            }
            remove(item.id, tombstone: false)
            insert(item)
            return
        }
        tombstoneSet.remove(item.id)
        if hasMoreBefore, let first = items.first, item.orderKey < first.orderKey {
            // Never place an isolated live row next to the cached H suffix.
            if parked[item.id].map({ $0.revision <= item.revision }) ?? true, parked.count < Self.maximumParkedItems || parked[item.id] != nil {
                parked[item.id] = item
            }
            return
        }
        insert(item)
    }

    private mutating func remove(_ id: String, tombstone: Bool = true) {
        parked.removeValue(forKey: id)
        if tombstone, tombstoneSet.insert(id).inserted {
            tombstones.append(id)
            if tombstones.count > Self.maximumTombstones { tombstoneSet.remove(tombstones.removeFirst()) }
        }
        if let body = bodies.removeValue(forKey: id) { bodyBytes -= body.text.utf8.count }
        guard let index = indexByID.removeValue(forKey: id) else { return }
        items.remove(at: index)
        for position in index..<items.count { indexByID[items[position].id] = position }
    }

    private mutating func insert(_ item: ConversationItem) {
        var low = 0
        var high = items.count
        while low < high {
            let middle = (low + high) / 2
            let other = items[middle]
            if other.orderKey < item.orderKey || (other.orderKey == item.orderKey && other.id < item.id) { low = middle + 1 }
            else { high = middle }
        }
        items.insert(item, at: low)
        for position in low..<items.count { indexByID[items[position].id] = position }
    }

    /// Live growth past the display bound drops the oldest rows; they remain reachable on the host.
    private mutating func trimToBound() {
        let excess = items.count - Self.maximumItems
        guard excess > 0 else { return }
        for item in items.prefix(excess) {
            indexByID.removeValue(forKey: item.id)
            if let body = bodies.removeValue(forKey: item.id) { bodyBytes -= body.text.utf8.count }
        }
        items.removeFirst(excess)
        for (position, item) in items.enumerated() { indexByID[item.id] = position }
        reachedDisplayLimit = true
        hasMoreBefore = false
    }

    private mutating func evictBodies(keeping id: String) {
        while bodyBytes > Self.maximumBodyBytes,
              let victim = bodies.filter({ $0.key != id }).min(by: { $0.value.lastUse < $1.value.lastUse })?.key,
              let body = bodies.removeValue(forKey: victim) {
            bodyBytes -= body.text.utf8.count
        }
    }
}
