import AppKit

/// Stable identities of viewport actions. Titles are presentation; these IDs are what menus, the mode
/// switcher and shortcuts invoke, so every entry point runs the same action.
public enum CorralActionID: String, CaseIterable, Sendable {
    case history, newSession, rename, fork, clone, compact, usage, export, terminal
}

/// Which independent UI an action opens. An action is only offered when its UI exists in this build.
public enum CorralActionPresentation: String, Sendable {
    case historyDrawer, newSessionConfirm, inlineRename, forkPicker, cloneConfirm, compactSheet, metricsPanel, exportFlow, modeSwitch
}

public enum CorralActionGroup: Int, Sendable, Comparable {
    case session, context, display
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    var title: String {
        switch self {
        case .session: "会话"
        case .context: "上下文与用量"
        case .display: "显示"
        }
    }
}

/// What running the action can change; drives consent and "unknown outcome" handling.
public enum CorralActionEffect: Sendable { case query, nativeMutation, localFile, presentation }

/// Static description of an action: identity, menu placement and the UI it opens. It never holds a
/// session, connection or provider; those are captured when the action is invoked.
public struct CorralActionSpec: Equatable, Sendable {
    public let id: CorralActionID
    public let title: String
    public let icon: CorralLegacyIcon
    public let group: CorralActionGroup
    public let presentation: CorralActionPresentation
    public let effect: CorralActionEffect

    public static func spec(_ id: CorralActionID) -> CorralActionSpec {
        switch id {
        case .history: .init(id: id, title: "历史会话", icon: .layers, group: .session, presentation: .historyDrawer, effect: .nativeMutation)
        case .newSession: .init(id: id, title: "开始新会话", icon: .plus, group: .session, presentation: .newSessionConfirm, effect: .nativeMutation)
        case .rename: .init(id: id, title: "重命名会话", icon: .edit, group: .session, presentation: .inlineRename, effect: .nativeMutation)
        case .fork: .init(id: id, title: "从消息分叉", icon: .gitBranch, group: .session, presentation: .forkPicker, effect: .nativeMutation)
        case .clone: .init(id: id, title: "克隆当前会话", icon: .copy, group: .session, presentation: .cloneConfirm, effect: .nativeMutation)
        case .compact: .init(id: id, title: "压缩上下文", icon: .reflow, group: .context, presentation: .compactSheet, effect: .nativeMutation)
        case .usage: .init(id: id, title: "用量与额度", icon: .grid, group: .context, presentation: .metricsPanel, effect: .query)
        case .export: .init(id: id, title: "导出会话", icon: .download, group: .context, presentation: .exportFlow, effect: .localFile)
        case .terminal: .init(id: id, title: "切换到终端", icon: .terminal, group: .display, presentation: .modeSwitch, effect: .nativeMutation)
        }
    }
}

public enum CorralActionAvailability: Equatable, Sendable {
    /// Not supported by this provider or build: never shown as a grey placeholder.
    case hidden
    case enabled
    /// Supported, but not right now; the reason is shown to the user.
    case disabled(String)
}

/// The facts an availability decision may use, captured from the viewport at menu-open and submit time.
public struct CorralActionContext: Equatable, Sendable {
    public enum Mode: Sendable { case gui, tui }
    public var ready: Bool
    public var mode: Mode
    public var running: Bool?
    public var switching: Bool
    public var operationPending: Bool
    public var implemented: Set<CorralActionPresentation>

    public init(ready: Bool, mode: Mode, running: Bool?, switching: Bool, implemented: Set<CorralActionPresentation>, operationPending: Bool = false) {
        self.ready = ready
        self.mode = mode
        self.running = running
        self.switching = switching
        self.implemented = implemented
        self.operationPending = operationPending
    }
}

/// One atomic, provider-neutral viewport action. Providers only choose which actions they offer and with
/// which capabilities (for example usage scopes); the UI never branches on a provider name.
@MainActor
public protocol CorralAtomicAction {
    var spec: CorralActionSpec { get }
    func availability(in context: CorralActionContext) -> CorralActionAvailability
    @discardableResult
    func perform(in context: CorralActionContext, present: (CorralActionPresentation) -> Void) -> Bool
}

public extension CorralAtomicAction {
    /// Re-evaluate at invocation: a menu opened before a disconnect or mode change is not authority.
    @discardableResult
    func perform(in context: CorralActionContext, present: (CorralActionPresentation) -> Void) -> Bool {
        guard availability(in: context) == .enabled else { return false }
        present(spec.presentation)
        return true
    }

    /// Shared gates: unimplemented UI hides; a pending mode change or a missing structured view disables.
    func baseAvailability(in context: CorralActionContext, needsStructuredView: Bool = true) -> CorralActionAvailability? {
        guard context.implemented.contains(spec.presentation) else { return .hidden }
        if context.switching { return .disabled("正在切换显示模式") }
        if context.operationPending { return .disabled("另一个会话操作尚未完成") }
        if needsStructuredView, context.mode == .tui { return .disabled("终端模式下不可用，请先切换到原生 GUI") }
        if needsStructuredView, !context.ready { return .disabled("会话尚未就绪") }
        return nil
    }
}

/// Session operations share identity and gates; native provider-specific commands live in the adapter.
public struct CorralSessionAction: CorralAtomicAction {
    public let spec: CorralActionSpec
    public init(_ id: CorralActionID) { spec = .spec(id) }
    public func availability(in context: CorralActionContext) -> CorralActionAvailability {
        if let base = baseAvailability(in: context) { return base }
        if spec.id == .compact, context.running != false { return .disabled("请先停止当前任务，再压缩上下文") }
        return .enabled
    }
}

/// Session usage and, where a provider reports it, account quota. Scopes are data, not provider checks.
public struct CorralUsageAction: CorralAtomicAction {
    public enum Scope: Sendable { case session, account }
    public let scopes: Set<Scope>
    public init(scopes: Set<Scope>) { self.scopes = scopes }
    public var spec: CorralActionSpec { .spec(.usage) }
    public func availability(in context: CorralActionContext) -> CorralActionAvailability {
        guard !scopes.isEmpty else { return .hidden }
        return baseAvailability(in: context) ?? .enabled
    }
}

/// The same native mode change the viewport switcher performs, offered from the menu.
public struct CorralModeSwitchAction: CorralAtomicAction {
    public init() {}
    public var spec: CorralActionSpec { .spec(.terminal) }
    public func availability(in context: CorralActionContext) -> CorralActionAvailability {
        if let base = baseAvailability(in: context, needsStructuredView: false) { return base }
        return context.ready ? .enabled : .disabled("会话尚未就绪")
    }
}

/// A resolved menu row: the action's spec plus what it can do right now.
public struct CorralActionMenuEntry: Equatable, Sendable {
    public let spec: CorralActionSpec
    public let availability: CorralActionAvailability
    /// Presentation-specific title override (e.g. the mode action in a terminal viewport).
    public let title: String
    public init(spec: CorralActionSpec, availability: CorralActionAvailability, title: String? = nil) {
        self.spec = spec
        self.availability = availability
        self.title = title ?? spec.title
    }
}

/// Builds the native ⋯ menu: grouped sections, icons, disabled rows with their reason, hidden rows absent.
@MainActor
public final class CorralActionMenu: NSMenu {
    public private(set) var entries: [CorralActionMenuEntry]
    private let onSelect: (CorralActionID) -> Void

    public init(entries: [CorralActionMenuEntry], onSelect: @escaping (CorralActionID) -> Void) {
        self.entries = entries.filter { $0.availability != .hidden }
        self.onSelect = onSelect
        super.init(title: "会话操作")
        autoenablesItems = false
        var lastGroup: CorralActionGroup?
        for entry in self.entries.sorted(by: { $0.spec.group < $1.spec.group }) {
            if entry.spec.group != lastGroup {
                if lastGroup != nil { addItem(.separator()) }
                addItem(NSMenuItem.sectionHeader(title: entry.spec.group.title))
                lastGroup = entry.spec.group
            }
            let item = NSMenuItem(title: entry.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier("corral.action.\(entry.spec.id.rawValue)")
            item.representedObject = entry.spec.id.rawValue
            item.image = CorralLegacyIcon.image(entry.spec.icon, size: 14)
            if case let .disabled(reason) = entry.availability {
                item.isEnabled = false
                item.toolTip = reason
                let attributed = NSMutableAttributedString(string: entry.title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
                attributed.append(NSAttributedString(string: "  \(reason)", attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
                item.attributedTitle = attributed
            }
            item.setAccessibilityLabel(entry.title)
            addItem(item)
        }
    }

    public required init(coder: NSCoder) { fatalError("CorralActionMenu is created programmatically") }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = CorralActionID(rawValue: raw) else { return }
        onSelect(id)
    }

    /// The exact path a pointer selection takes, for acceptance without a modal menu-tracking loop.
    public func performAction(_ id: CorralActionID) -> Bool {
        guard let index = items.firstIndex(where: { $0.representedObject as? String == id.rawValue }), items[index].isEnabled else { return false }
        performActionForItem(at: index)
        return true
    }
}
