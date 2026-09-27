import CorralContracts
import CorralServices
import CoreGraphics

/// Pure split-tree geometry shared by the pane chrome and the Metal viewports (legacy `workspaceLayout.js`
/// `projectLayout` / `getSubtreeMinSize` and `tabDrag.js` `hitTestLeafPanes`, Issue #271/#272, PR #274).
/// Coordinates are top-left-origin points, the same space as `StageViewportRect`.
public enum SplitLayout {
    public static let gap: CGFloat = 6
    public static let minimumPaneWidth: CGFloat = 120
    public static let minimumPaneHeight: CGFloat = 60
    static let hysteresis: CGFloat = 3
    /// A drop whose nearest normalized edge is at least this far away replaces the pane instead of splitting it.
    static let centerCore: CGFloat = 0.25

    public struct Pane: Equatable, Sendable {
        public let sessionID: SessionID
        public let frame: CGRect
    }

    public struct Divider: Equatable, Sendable {
        /// Legacy resizer path accepted by `CorralWorkspaceStore.updateSplitRatio`: "root", "root.first.second", …
        public let path: String
        public let direction: SplitDirection
        public let ratio: Double
        /// The 6pt gap between the two children; it is also the drag handle.
        public let frame: CGRect
        public let parentFrame: CGRect
        public let minimumFirst: CGFloat
        public let minimumSecond: CGFloat
        public var firstExtent: CGFloat { direction == .horizontal ? frame.minX - parentFrame.minX : frame.minY - parentFrame.minY }
    }

    public struct Projection: Equatable, Sendable {
        public var panes: [Pane] = []
        public var dividers: [Divider] = []
        public func frame(of sessionID: SessionID) -> CGRect? { panes.first { $0.sessionID == sessionID }?.frame }
    }

    public struct DropTarget: Equatable, Sendable {
        /// Nil on an empty stage: the source becomes the whole layout.
        public let target: SessionID?
        public let edge: WorkspaceDropZone
        /// The source's slot in the candidate layout (the target pane itself for `center`).
        public let previewFrame: CGRect
    }

    /// Smallest extent along an axis that keeps every leaf of the subtree at its minimum under its current ratios.
    public static func minimumExtent(of node: WorkspaceLayoutNode, along direction: SplitDirection) -> CGFloat {
        switch node {
        case .session: return direction == .horizontal ? minimumPaneWidth : minimumPaneHeight
        case let .split(splitDirection, ratio, first, second):
            let minimumFirst = minimumExtent(of: first, along: direction), minimumSecond = minimumExtent(of: second, along: direction)
            guard splitDirection == direction else { return max(minimumFirst, minimumSecond) }
            let share = CGFloat(validRatio(ratio))
            return max(minimumFirst + gap + minimumSecond, max((minimumFirst / share).rounded(.up), (minimumSecond / (1 - share)).rounded(.up)) + gap)
        }
    }

    /// `usable = extent − gap`, `first = ⌊usable × ratio⌋`, remainder to the second child; when both subtree
    /// minimums fit, the split is nudged so rounding never leaves a leaf below 120×60.
    public static func project(_ root: WorkspaceLayoutNode?, in bounds: CGRect) -> Projection {
        var projection = Projection()
        func visit(_ node: WorkspaceLayoutNode, _ rect: CGRect, _ path: String) {
            guard rect.width > 0, rect.height > 0 else { return }
            switch node {
            case let .session(id):
                projection.panes.append(Pane(sessionID: id, frame: rect))
            case let .split(direction, ratio, first, second):
                let horizontal = direction == .horizontal
                let usable = max(0, (horizontal ? rect.width : rect.height) - gap)
                let minimumFirst = minimumExtent(of: first, along: direction), minimumSecond = minimumExtent(of: second, along: direction)
                var firstExtent = (usable * CGFloat(validRatio(ratio))).rounded(.down)
                if usable >= minimumFirst + minimumSecond {
                    firstExtent = min(max(firstExtent, minimumFirst), usable - minimumSecond)
                }
                let secondExtent = usable - firstExtent
                let (firstRect, gapRect, secondRect) = horizontal
                    ? (CGRect(x: rect.minX, y: rect.minY, width: firstExtent, height: rect.height),
                       CGRect(x: rect.minX + firstExtent, y: rect.minY, width: gap, height: rect.height),
                       CGRect(x: rect.minX + firstExtent + gap, y: rect.minY, width: secondExtent, height: rect.height))
                    : (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstExtent),
                       CGRect(x: rect.minX, y: rect.minY + firstExtent, width: rect.width, height: gap),
                       CGRect(x: rect.minX, y: rect.minY + firstExtent + gap, width: rect.width, height: secondExtent))
                projection.dividers.append(Divider(path: path, direction: direction, ratio: validRatio(ratio), frame: gapRect, parentFrame: rect, minimumFirst: minimumFirst, minimumSecond: minimumSecond))
                visit(first, firstRect, path + ".first")
                visit(second, secondRect, path + ".second")
            }
        }
        if let root { visit(root, bounds, "root") }
        return projection
    }

    /// Ratio for dragging `divider` by `delta` points from where the drag began (legacy
    /// `computeSplitRatioFromDelta`): clamped to both subtree minimums, four decimals within 0.01…0.99, and
    /// rounded so the projection lands exactly on the dragged pixel. Nil when nothing would change.
    public static func ratio(dragging divider: Divider, by delta: CGFloat) -> Double? {
        let usable = (divider.direction == .horizontal ? divider.parentFrame.width : divider.parentFrame.height) - gap
        let minimumFirst = divider.minimumFirst, maximumFirst = usable - divider.minimumSecond
        guard usable > 0, maximumFirst >= minimumFirst else { return nil }
        let first = min(max((divider.firstExtent + delta).rounded(), minimumFirst), maximumFirst)
        guard first != divider.firstExtent else { return nil }
        let size = Double(usable), target = Double(first)
        var ratio: Double
        if first <= minimumFirst {
            ratio = (target / size * 10_000).rounded(.up) / 10_000
        } else if first >= maximumFirst {
            ratio = (target / size * 10_000).rounded(.down) / 10_000
        } else {
            ratio = ((target + 0.5) / size * 10_000).rounded() / 10_000
            let projected = (size * ratio).rounded(.down)
            if projected < target { ratio = (target / size * 10_000).rounded(.up) / 10_000 }
            else if projected > target { ratio = (target / size * 10_000).rounded(.down) / 10_000 }
        }
        ratio = min(0.99, max(0.01, ratio))
        return ratio == divider.ratio ? nil : ratio
    }

    /// Five-zone hit test for dropping `source` at `point` (legacy `hitTestLeafPanes`). A lone pane splits only
    /// left/right at its vertical midline; with several panes the nearest normalized edge wins (ties: left, right,
    /// top, bottom), the central core replaces, and a 3pt hysteresis keeps the previous edge. The candidate layout
    /// is projected first: any leaf below 120×60 rejects the drop (nil), as do self drops and the 6pt gaps.
    public static func dropTarget(at point: CGPoint, source: SessionID, root: WorkspaceLayoutNode?, in bounds: CGRect, previous: DropTarget? = nil) -> DropTarget? {
        guard bounds.contains(point) else { return nil }
        guard let root else { return DropTarget(target: nil, edge: .center, previewFrame: bounds) }
        let layout = project(root, in: bounds)
        guard let pane = layout.panes.first(where: { $0.frame.contains(point) }), pane.sessionID != source else { return nil }
        let rect = pane.frame
        let previousEdge = previous?.target == pane.sessionID ? previous?.edge : nil
        let edge: WorkspaceDropZone
        if layout.panes.count == 1 {
            if previousEdge == .left, point.x < rect.midX + hysteresis { edge = .left }
            else if previousEdge == .right, point.x >= rect.midX - hysteresis { edge = .right }
            else { edge = point.x - rect.minX < rect.width / 2 ? .left : .right }
        } else {
            edge = nearestEdge(u: (point.x - rect.minX) / rect.width, v: (point.y - rect.minY) / rect.height, in: rect.size, previous: previousEdge)
        }
        guard let candidate = root.dropping(source, onto: pane.sessionID, edge: edge) else { return nil }
        let projected = project(candidate, in: bounds)
        guard projected.panes.count == candidate.leafIDs.count,
              projected.panes.allSatisfy({ $0.frame.width >= minimumPaneWidth && $0.frame.height >= minimumPaneHeight }),
              let preview = edge == .center ? rect : projected.frame(of: source) else { return nil }
        return DropTarget(target: pane.sessionID, edge: edge, previewFrame: preview)
    }

    static func nearestEdge(u: CGFloat, v: CGFloat, in size: CGSize, previous: WorkspaceDropZone?) -> WorkspaceDropZone {
        let distances: [(edge: WorkspaceDropZone, distance: CGFloat)] = [(.left, u), (.right, 1 - u), (.top, v), (.bottom, 1 - v)]
        let best = distances.min { $0.distance < $1.distance }!
        guard best.distance < centerCore else { return .center }
        if let previous, previous != best.edge, let held = distances.first(where: { $0.edge == previous }) {
            let axis = previous == .left || previous == .right ? size.width : size.height
            if best.distance >= held.distance - hysteresis / axis { return previous }
        }
        return best.edge
    }

    private static func validRatio(_ ratio: Double) -> Double { ratio.isFinite && ratio > 0 && ratio < 1 ? ratio : 0.5 }
}
