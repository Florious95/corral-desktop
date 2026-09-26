import AppKit
import CorralContracts

@MainActor
public final class CorralTab: Identifiable {
    public let id: UUID
    public var title: String
    public var badge: String?
    public var provider: String?
    public var status: CorralStatusIndicatorView.Status
    public var isPinned: Bool
    public var isCustomTitle: Bool
    public let defaultTitle: String
    public var sessionIDs: Set<UUID>
    public var activeSessionID: UUID?
    public var isBlankWorkspace: Bool
    public let contentView: NSView
    public var terminalSnapshot: TerminalGridSnapshot?

    public init(id: UUID = UUID(), title: String, badge: String? = nil, contentView: NSView = NSView(), terminalSnapshot: TerminalGridSnapshot? = nil, status: CorralStatusIndicatorView.Status = .idle, isPinned: Bool = false, isCustomTitle: Bool = false, sessionIDs: Set<UUID> = [], activeSessionID: UUID? = nil, isBlankWorkspace: Bool = true, provider: String? = nil) {
        self.id = id
        self.title = title
        self.badge = badge
        self.provider = provider
        self.contentView = contentView
        self.terminalSnapshot = terminalSnapshot
        self.status = status
        self.isPinned = isPinned
        self.isCustomTitle = isCustomTitle
        self.defaultTitle = title
        self.sessionIDs = sessionIDs
        self.activeSessionID = activeSessionID
        self.isBlankWorkspace = isBlankWorkspace
    }
}

@MainActor
public final class CorralTabBarView: NSView {
    public private(set) var tabs: [CorralTab] = []
    public private(set) var selectedTabID: UUID?
    public var onSelectTab: ((UUID) -> Void)?
    public var onCreateTab: (() -> Void)?
    public var onCloseTab: ((UUID) -> Void)?
    public var onRenameTab: ((UUID, String) -> Void)?
    public var onToggleSidebar: (() -> Void)?
    public var onReorderTabs: ((UUID, Int) -> Void)?
    public var onContextAction: ((UUID, String) -> Void)?

    private let itemsStack = NSStackView()
    /// Clips overflowing tabs like `.tb-tabs-scroll`, so tab count can never widen the window.
    private let tabsLane = NSView()
    private let bottomBorder = NSView()
    private let activeCapsule = NSView()
    private let trafficLightsSpacer = NSView()
    private let expandSidebarButton = NSButton(title: "▤", target: nil, action: nil)
    private let dragRegion = CorralWindowDragRegion()
    private var itemsLeadingConstraint: NSLayoutConstraint!
    public private(set) var activeCapsuleFrame: NSRect?
    public private(set) var isSidebarCollapsed = false
    public private(set) var sidebarToggleButton = NSButton(title: "▤", target: nil, action: nil)
    public private(set) var devicesButton = NSButton(title: "设备", target: nil, action: nil)
    public let createButton = NSButton(title: "+", target: nil, action: nil)

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = CorralAestheticTokens.surface0.cgColor
        itemsStack.orientation = .horizontal
        itemsStack.alignment = .centerY
        itemsStack.spacing = 4
        itemsStack.translatesAutoresizingMaskIntoConstraints = false
        activeCapsule.wantsLayer = true
        activeCapsule.layer?.cornerRadius = 6
        activeCapsule.layer?.backgroundColor = CorralAestheticTokens.tabActiveBackground.cgColor
        activeCapsule.layer?.borderColor = CorralAestheticTokens.tabActiveBorder.cgColor
        activeCapsule.layer?.borderWidth = 1
        activeCapsule.layer?.shadowColor = NSColor.black.cgColor
        activeCapsule.layer?.shadowOpacity = 0.06
        activeCapsule.layer?.shadowRadius = 1
        activeCapsule.layer?.shadowOffset = NSSize(width: 0, height: -1)
        activeCapsule.isHidden = true
        itemsStack.addSubview(activeCapsule, positioned: .below, relativeTo: nil)
        tabsLane.clipsToBounds = true
        tabsLane.translatesAutoresizingMaskIntoConstraints = false
        tabsLane.addSubview(itemsStack)
        bottomBorder.wantsLayer = true
        bottomBorder.layer?.backgroundColor = CorralAestheticTokens.borderSubtle.cgColor
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dragRegion)
        addSubview(trafficLightsSpacer)
        addSubview(expandSidebarButton)
        addSubview(tabsLane)
        addSubview(createButton)
        addSubview(bottomBorder)

        trafficLightsSpacer.translatesAutoresizingMaskIntoConstraints = false
        expandSidebarButton.translatesAutoresizingMaskIntoConstraints = false
        expandSidebarButton.isBordered = false
        expandSidebarButton.image = CorralLegacyIcon.image(.sidebar, size: 16)
        expandSidebarButton.imagePosition = .imageOnly
        expandSidebarButton.imageScaling = .scaleProportionallyDown
        expandSidebarButton.contentTintColor = CorralAestheticTokens.icon
        expandSidebarButton.toolTip = "展开侧栏"
        expandSidebarButton.setAccessibilityLabel("展开侧栏"); expandSidebarButton.setAccessibilityIdentifier("corral.sidebar.expand")
        expandSidebarButton.target = self; expandSidebarButton.action = #selector(toggleSidebar)
        expandSidebarButton.isHidden = true

        createButton.isBordered = false
        createButton.title = ""
        createButton.image = CorralLegacyIcon.image(.plus, size: 14)
        createButton.imagePosition = .imageOnly
        createButton.imageScaling = .scaleProportionallyDown
        createButton.contentTintColor = CorralAestheticTokens.icon
        createButton.toolTip = "新建工作台标签页 (⌘T)"
        createButton.setAccessibilityLabel("新建工作台标签页"); createButton.setAccessibilityIdentifier("corral.tab.new")
        createButton.target = self; createButton.action = #selector(createTab)
        createButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([createButton.widthAnchor.constraint(equalToConstant: 26), createButton.heightAnchor.constraint(equalToConstant: 26)])

        trafficLightsSpacer.isHidden = true
        dragRegion.translatesAutoresizingMaskIntoConstraints = false
        itemsLeadingConstraint = tabsLane.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.expandedTabsLeading)
        let laneHugsTabs = tabsLane.widthAnchor.constraint(equalTo: itemsStack.widthAnchor, constant: 2)
        laneHugsTabs.priority = NSLayoutConstraint.Priority(490)
        NSLayoutConstraint.activate([
            trafficLightsSpacer.leadingAnchor.constraint(equalTo: leadingAnchor), trafficLightsSpacer.topAnchor.constraint(equalTo: topAnchor), trafficLightsSpacer.bottomAnchor.constraint(equalTo: bottomAnchor), trafficLightsSpacer.widthAnchor.constraint(equalToConstant: 80),
            expandSidebarButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 88), expandSidebarButton.centerYAnchor.constraint(equalTo: centerYAnchor), expandSidebarButton.widthAnchor.constraint(equalToConstant: 28), expandSidebarButton.heightAnchor.constraint(equalToConstant: 26),
            itemsLeadingConstraint, tabsLane.centerYAnchor.constraint(equalTo: centerYAnchor), tabsLane.heightAnchor.constraint(equalToConstant: 28), laneHugsTabs,
            itemsStack.leadingAnchor.constraint(equalTo: tabsLane.leadingAnchor, constant: 1), itemsStack.centerYAnchor.constraint(equalTo: tabsLane.centerYAnchor),
            createButton.leadingAnchor.constraint(equalTo: tabsLane.trailingAnchor, constant: 8), createButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            createButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            dragRegion.leadingAnchor.constraint(equalTo: createButton.trailingAnchor, constant: 8), dragRegion.trailingAnchor.constraint(equalTo: trailingAnchor), dragRegion.topAnchor.constraint(equalTo: topAnchor), dragRegion.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor), bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor), bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor), bottomBorder.heightAnchor.constraint(equalToConstant: 1)
        ])
        registerForDraggedTypes([.string])
    }

    public required init?(coder: NSCoder) { fatalError("CorralTabBarView is created programmatically") }
    /// `.tb-session-header` padding-left 8px + `.tb-tabs-scroll` padding 1px; collapsed adds the 80px lights lane and 28px toggle.
    static let expandedTabsLeading: CGFloat = 8
    static let collapsedTabsLeading: CGFloat = 124

    public func setTabs(_ tabs: [CorralTab], selectedTabID: UUID?) {
        self.tabs = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
        self.selectedTabID = selectedTabID
        for view in itemsStack.arrangedSubviews {
            itemsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for tab in self.tabs {
            itemsStack.addArrangedSubview(CorralTabItemView(tab: tab, selected: tab.id == selectedTabID, owner: self))
        }
        itemsStack.needsLayout = true
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        itemsStack.layoutSubtreeIfNeeded()
        guard let selectedTabID, let item = itemsStack.arrangedSubviews.compactMap({ $0 as? CorralTabItemView }).first(where: { $0.tab.id == selectedTabID }), !item.tab.isPinned else {
            activeCapsule.isHidden = true; activeCapsuleFrame = nil; return
        }
        activeCapsule.frame = item.frame
        activeCapsule.isHidden = false
        activeCapsuleFrame = item.frame
    }
    public func bindSidebarToggleButton(_ button: NSButton) { sidebarToggleButton = button }
    public func bindDevicesButton(_ button: NSButton) { devicesButton = button }
    public func setSidebarCollapsed(_ collapsed: Bool) {
        isSidebarCollapsed = collapsed
        trafficLightsSpacer.isHidden = !collapsed
        expandSidebarButton.isHidden = !collapsed
        expandSidebarButton.toolTip = collapsed ? "展开侧栏" : nil
        itemsLeadingConstraint.constant = collapsed ? Self.collapsedTabsLeading : Self.expandedTabsLeading
        needsLayout = true
    }
    public func refreshTheme() {
        layer?.backgroundColor = CorralAestheticTokens.surface0.cgColor
        activeCapsule.layer?.backgroundColor = CorralAestheticTokens.tabActiveBackground.cgColor
        activeCapsule.layer?.borderColor = CorralAestheticTokens.tabActiveBorder.cgColor
        bottomBorder.layer?.backgroundColor = CorralAestheticTokens.borderSubtle.cgColor
        expandSidebarButton.contentTintColor = CorralAestheticTokens.icon
        createButton.contentTintColor = CorralAestheticTokens.icon
        setTabs(tabs, selectedTabID: selectedTabID)
    }
    public func rename(_ tabID: UUID) {
        (itemsStack.arrangedSubviews.first { ($0 as? CorralTabItemView)?.tab.id == tabID } as? CorralTabItemView)?.beginRename()
    }

    fileprivate func select(_ id: UUID) { onSelectTab?(id) }
    fileprivate func close(_ id: UUID) { onCloseTab?(id) }
    fileprivate func commitRename(_ id: UUID, _ title: String) { onRenameTab?(id, title) }
    fileprivate func performContextAction(_ id: UUID, _ action: String) { onContextAction?(id, action) }
    @objc private func toggleSidebar() { onToggleSidebar?() }
    @objc private func createTab() { onCreateTab?() }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .move }
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let value = sender.draggingPasteboard.string(forType: .string), let id = UUID(uuidString: value),
              let sourceIndex = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let x = convert(sender.draggingLocation, from: nil).x
        let target = itemsStack.arrangedSubviews.compactMap { $0 as? CorralTabItemView }.first { x < $0.frame.midX }
        let targetIndex = target.flatMap { item in tabs.firstIndex(where: { $0.id == item.tab.id }) } ?? tabs.count
        let adjusted = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        onReorderTabs?(id, max(0, adjusted))
        return true
    }
}

@MainActor
private final class CorralTabItemView: NSView, NSTextFieldDelegate, NSDraggingSource {
    let tab: CorralTab
    private weak var owner: CorralTabBarView?
    private let status = CorralStatusIndicatorView()
    private let title = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let selected: Bool
    private var editField: CorralInlineRenameField?
    private var dragStart: NSPoint?
    private var didStartDrag = false

    init(tab: CorralTab, selected: Bool, owner: CorralTabBarView) {
        self.tab = tab
        self.owner = owner
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        let showsCapsule = selected && !tab.isPinned
        layer?.backgroundColor = selected && !showsCapsule ? CorralAestheticTokens.tabActiveBackground.cgColor : NSColor.clear.cgColor
        layer?.borderColor = selected && !showsCapsule ? CorralAestheticTokens.tabActiveBorder.cgColor : NSColor.clear.cgColor
        layer?.borderWidth = selected && !showsCapsule ? 1 : 0
        status.fillsIdle = true
        status.status = tab.status
        status.translatesAutoresizingMaskIntoConstraints = false
        title.stringValue = tab.isPinned ? String(tab.title.prefix(1)).uppercased() : tab.title
        title.font = .systemFont(ofSize: tab.isPinned ? 11 : 12, weight: tab.isPinned ? .semibold : .regular)
        title.textColor = selected ? CorralAestheticTokens.text : CorralAestheticTokens.textSecondary
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(status)
        addSubview(title)
        var pinnedProviderIcon: CorralProviderIconView?
        if tab.isPinned, let provider = tab.provider {
            let icon = CorralProviderIconView(provider: provider, size: 15, active: tab.status == .working || tab.status == .blocked)
            pinnedProviderIcon = icon
            addSubview(icon)
            title.isHidden = true
        }
        closeButton.image = CorralLegacyIcon.image(.close, size: 10, tint: CorralAestheticTokens.textMuted)
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.contentTintColor = CorralAestheticTokens.textMuted
        closeButton.toolTip = "关闭工作台"
        closeButton.setAccessibilityLabel("关闭工作台"); closeButton.setAccessibilityIdentifier("corral.tab.close")
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.alphaValue = selected ? 0.7 : 0
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        if !tab.isPinned { addSubview(closeButton) }
        let width: CGFloat = tab.isPinned ? 32 : 160
        widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        let preferredWidth = widthAnchor.constraint(equalToConstant: width)
        preferredWidth.priority = NSLayoutConstraint.Priority(480)
        preferredWidth.isActive = true
        status.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        status.widthAnchor.constraint(equalToConstant: tab.isPinned ? 6 : 6).isActive = true
        status.heightAnchor.constraint(equalToConstant: tab.isPinned ? 6 : 6).isActive = true
        if tab.isPinned {
            widthAnchor.constraint(equalToConstant: 32).isActive = true
            if let pinnedProviderIcon {
                NSLayoutConstraint.activate([
                    pinnedProviderIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                    pinnedProviderIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
                    status.leadingAnchor.constraint(equalTo: pinnedProviderIcon.trailingAnchor, constant: 1),
                    status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
                ])
            } else {
                NSLayoutConstraint.activate([
                    title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), title.centerYAnchor.constraint(equalTo: centerYAnchor),
                    status.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 1),
                    status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
                ])
            }
        } else {
            widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            NSLayoutConstraint.activate([
                status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                title.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 6), title.centerYAnchor.constraint(equalTo: centerYAnchor),
                title.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
                closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), closeButton.centerYAnchor.constraint(equalTo: centerYAnchor), closeButton.widthAnchor.constraint(equalToConstant: 18), closeButton.heightAnchor.constraint(equalToConstant: 18)
            ])
        }
        toolTip = tab.title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tab.title)
        setAccessibilityIdentifier("corral.tab")
        setAccessibilitySelected(selected)
        registerForDraggedTypes([.string])
    }
    override func accessibilityPerformPress() -> Bool { owner?.select(tab.id); return true }
    override func accessibilityPerformShowMenu() -> Bool { makeContextMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self); return true }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { CorralAccessibilityMenuActions.actions(for: makeContextMenu()) }

    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { beginRename(); return }
        dragStart = convert(event.locationInWindow, from: nil)
        didStartDrag = false
        owner?.select(tab.id)
    }
    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - dragStart.x, point.y - dragStart.y) > 4 else { return }
        didStartDrag = true
        let writer = NSPasteboardItem()
        writer.setString(tab.id.uuidString, forType: .string)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        (tab.title as NSString).draw(at: NSPoint(x: 6, y: 6), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: CorralAestheticTokens.text])
        image.unlockFocus()
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(convert(bounds, to: nil), contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) {
        closeButton.alphaValue = 0.7
        if !selected { layer?.backgroundColor = CorralAestheticTokens.hover.cgColor; title.textColor = CorralAestheticTokens.text }
    }
    override func mouseExited(with event: NSEvent) {
        closeButton.alphaValue = selected ? 0.7 : 0
        if !selected { layer?.backgroundColor = NSColor.clear.cgColor; title.textColor = CorralAestheticTokens.textSecondary }
    }
    override func rightMouseDown(with event: NSEvent) { NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: self) }
    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: tab.title)
        addMenuItem(menu, title: "适应当前窗口", action: "reflow")
        if tab.isCustomTitle { addMenuItem(menu, title: "恢复自动标题", action: "resetTitle") }
        addMenuItem(menu, title: tab.isPinned ? "取消固定" : "固定到最左", action: "pin")
        menu.addItem(.separator())
        addMenuItem(menu, title: "关闭工作台", action: "close")
        let unpinnedCount = owner?.tabs.filter { !$0.isPinned }.count ?? 0
        let others = addMenuItem(menu, title: "关闭其他工作台", action: "closeOthers"); others.isEnabled = unpinnedCount > 1 && !tab.isPinned
        let right = addMenuItem(menu, title: "关闭右侧所有工作台", action: "closeRight"); right.isEnabled = (owner?.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0) < (owner?.tabs.count ?? 1) - 1
        menu.autoenablesItems = false
        return menu
    }
    @discardableResult
    private func addMenuItem(_ menu: NSMenu, title: String, action: String) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: #selector(contextAction(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = action
        let icon: CorralLegacyIcon? = switch action {
        case "reflow": .reflow
        case "resetTitle": .edit
        case "pin": .pin
        case "close": .close
        case "closeOthers": .closeLeft
        case "closeRight": .closeRight
        default: nil
        }
        if let icon { item.image = CorralLegacyIcon.image(icon, size: 15) }
        return item
    }
    @objc private func contextAction(_ item: NSMenuItem) { owner?.performContextAction(tab.id, item.representedObject as? String ?? "") }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    @objc private func closeTab() { owner?.close(tab.id) }
    @objc private func renameFromMenu() { beginRename() }
    @objc private func togglePin() { tab.isPinned.toggle(); owner?.setTabs(owner?.tabs ?? [], selectedTabID: owner?.selectedTabID) }
    func beginRename() {
        guard !tab.isPinned else { return }
        let field = CorralInlineRenameField(string: tab.title)
        field.beginEditing()
        field.isBezeled = false; field.drawsBackground = true; field.backgroundColor = CorralAestheticTokens.surface1
        field.textColor = CorralAestheticTokens.text; field.font = .systemFont(ofSize: 12); field.delegate = self
        field.onCommit = { [weak self] text in self?.finishRename(text) }
        field.onCancel = { [weak self] in self?.removeEditor() }
        field.frame = title.frame.insetBy(dx: -4, dy: -3)
        addSubview(field); title.isHidden = true; editField = field
        window?.makeFirstResponder(field); field.selectText(nil)
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = editField, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        field.finish(commit: true)
    }
    private func finishRename(_ value: String) { if !value.isEmpty { tab.title = value; owner?.commitRename(tab.id, value) }; removeEditor() }
    private func removeEditor() { editField?.removeFromSuperview(); editField = nil; title.stringValue = tab.isPinned ? String(tab.title.prefix(1)) : tab.title; title.isHidden = false }
}

public enum CorralSidebarSpaceKind: String, Sendable { case allSpaces, favorites, workspace }

@MainActor
public struct CorralSidebarSpace: Identifiable, Sendable {
    public static let allSpacesID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let favoritesID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    public let id: UUID
    public var name: String
    public var workingCount: Int
    public var agentCount: Int
    public var kind: CorralSidebarSpaceKind
    public var isVirtual: Bool { kind != .workspace }
    public init(id: UUID = UUID(), name: String, workingCount: Int = 0, agentCount: Int = 0, isVirtual: Bool = false, kind: CorralSidebarSpaceKind = .workspace) {
        self.id = id; self.name = name; self.workingCount = workingCount; self.agentCount = agentCount
        self.kind = isVirtual ? (name == "收藏" ? .favorites : .allSpaces) : kind
    }
}

@MainActor
public struct CorralSidebarAgent: Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var status: CorralStatusIndicatorView.Status
    public var provider: String?
    public var deviceName: String?
    public var spaceID: UUID?
    public var isFavorite: Bool
    public var isOpen: Bool
    public var isActive: Bool
    public var isClosing: Bool
    public init(id: UUID = UUID(), name: String, status: CorralStatusIndicatorView.Status = .idle, provider: String? = nil, deviceName: String? = nil, spaceID: UUID? = nil, isFavorite: Bool = false, isOpen: Bool = false, isActive: Bool = false, isClosing: Bool = false) {
        self.id = id; self.name = name; self.status = status; self.provider = provider; self.deviceName = deviceName; self.spaceID = spaceID; self.isFavorite = isFavorite; self.isOpen = isOpen; self.isActive = isActive; self.isClosing = isClosing
    }
}

@MainActor
public final class CorralSidebarSession: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

@MainActor
public final class CorralSidebarDevice: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let sessions: [CorralSidebarSession]
    public let isOnline: Bool
    public init(id: UUID = UUID(), name: String, sessions: [CorralSidebarSession] = [], isOnline: Bool = false) { self.id = id; self.name = name; self.sessions = sessions; self.isOnline = isOnline }
}

/// Maps enabled context-menu items to AX custom actions so headless automation never needs a modal menu.
@MainActor
enum CorralAccessibilityMenuActions {
    static func actions(for menu: NSMenu?) -> [NSAccessibilityCustomAction]? {
        menu?.items.filter { !$0.isSeparatorItem && $0.isEnabled && $0.action != nil }.map { item in
            NSAccessibilityCustomAction(name: item.title) { NSApp.sendAction(item.action!, to: item.target, from: item) }
        }
    }
}

/// Sidebar row content: an AX button whose press opens/selects the row and whose custom actions mirror its menu.
@MainActor
final class CorralSidebarCellView: NSTableCellView {
    var onPress: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    override func accessibilityPerformPress() -> Bool { onPress?(); return onPress != nil }
    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = menuProvider?() else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self); return true
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { CorralAccessibilityMenuActions.actions(for: menuProvider?()) }
}

/// Draws `.spaces-row` / `.agents-row` backgrounds: list padding 10px, agents add a 2px transparent border.
@MainActor
final class CorralSidebarRowView: NSTableRowView {
    var isAgentRow = false
    var isOpen = false
    var isActive = false
    private var isHovered = false { didSet { needsDisplay = true; revealHoverControls() } }
    override var isSelected: Bool { didSet { revealHoverControls() } }
    var backgroundRect: NSRect { isAgentRow ? bounds.insetBy(dx: 12, dy: 2) : bounds.insetBy(dx: 10, dy: 0) }
    var fillColor: NSColor? {
        if isSelected || isActive { return CorralAestheticTokens.selectionBackground }
        if isHovered { return isAgentRow ? (isOpen ? CorralAestheticTokens.hover : CorralAestheticTokens.hoverSubtle) : CorralAestheticTokens.hover }
        return isOpen ? CorralAestheticTokens.fillSubtle : nil
    }
    override func drawBackground(in dirtyRect: NSRect) {
        guard let color = fillColor else { return }
        color.setFill()
        let radius: CGFloat = isAgentRow ? 6 : 7
        NSBezierPath(roundedRect: backgroundRect, xRadius: radius, yRadius: radius).fill()
    }
    override func drawSelection(in dirtyRect: NSRect) {}
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func didAddSubview(_ subview: NSView) { super.didAddSubview(subview); revealHoverControls() }
    /// `.spaces-row-add` is only visible on hover or selection.
    private func revealHoverControls() {
        let visible = isHovered || isSelected
        func walk(_ view: NSView) { for child in view.subviews { if child.identifier?.rawValue.hasPrefix(Self.hoverControlPrefix) == true { child.alphaValue = visible ? 1 : 0 }; walk(child) } }
        walk(self)
    }
    static let hoverControlPrefix = "hover:"
}

@MainActor
final class CorralSidebarSectionHeader: NSView {
    private let chevron = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let workingIndicator = CorralStatusIndicatorView()
    var onToggle: (() -> Void)?
    private(set) var isExpanded = true
    /// `.sidebar-group-head` padding 14px 20px 4px around a 20px `.sidebar-group-btn`.
    static let height: CGFloat = 38
    init(title: String) {
        super.init(frame: .zero)
        chevron.image = CorralLegacyIcon.image(.chevronDown, size: 11)
        chevron.contentTintColor = CorralAestheticTokens.textMuted
        chevron.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = CorralAestheticTokens.textMuted
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        workingIndicator.status = .working
        workingIndicator.isHidden = true
        workingIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron); addSubview(titleLabel); addSubview(workingIndicator)
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20), chevron.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor), chevron.widthAnchor.constraint(equalToConstant: 11), chevron.heightAnchor.constraint(equalToConstant: 11),
            titleLabel.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 4), titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: workingIndicator.leadingAnchor, constant: -8), titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            workingIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20), workingIndicator.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor), workingIndicator.widthAnchor.constraint(equalToConstant: 6), workingIndicator.heightAnchor.constraint(equalToConstant: 6)
        ])
        toolTip = title
    }
    required init?(coder: NSCoder) { nil }
    var title: String { titleLabel.stringValue }
    var titleFrame: NSRect { titleLabel.frame }
    func setTitle(_ title: String) { titleLabel.stringValue = title; toolTip = title }
    func update(isExpanded: Bool, hasWorking: Bool) {
        self.isExpanded = isExpanded
        workingIndicator.isHidden = isExpanded || !hasWorking
        chevron.frameCenterRotation = isExpanded ? 0 : 90
    }
    func refreshTheme() {
        chevron.contentTintColor = CorralAestheticTokens.textMuted
        titleLabel.textColor = CorralAestheticTokens.textMuted
    }
    override func mouseDown(with event: NSEvent) { onToggle?() }
}

@MainActor
private final class SidebarTableData: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    enum Kind { case spaces, agents }
    let kind: Kind
    weak var sidebar: CorralSidebarView?
    var spaces: [CorralSidebarSpace] = []
    var agents: [CorralSidebarAgent] = []
    var controllers: [UUID: SessionContextMenuController] = [:]
    init(_ kind: Kind) { self.kind = kind }
    func numberOfRows(in tableView: NSTableView) -> Int { kind == .spaces ? spaces.count : agents.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { kind == .spaces ? CorralSidebarView.spaceRowHeight : CorralSidebarView.agentRowHeight }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = CorralSidebarRowView()
        rowView.isAgentRow = kind == .agents
        if kind == .agents, agents.indices.contains(row) { rowView.isOpen = agents[row].isOpen; rowView.isActive = agents[row].isActive }
        return rowView
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = CorralSidebarCellView()
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.button)
        if kind == .spaces, spaces.indices.contains(row) {
            let space = spaces[row]
            cell.setAccessibilityIdentifier("corral.sidebar.space"); cell.setAccessibilityLabel(space.name)
            cell.onPress = { [weak self] in self?.sidebar?.selectSpace(id: space.id) }
            cell.menuProvider = { [weak self] in self?.sidebar?.spaceContextMenu(for: space.id) }
        } else if agents.indices.contains(row) {
            let agent = agents[row]
            cell.setAccessibilityIdentifier("corral.sidebar.agent"); cell.setAccessibilityLabel(agent.name)
            cell.onPress = { [weak self] in self?.sidebar?.onSelectAgent?(agent.id) }
            cell.menuProvider = { [weak self] in self?.sidebar?.agentContextMenu(for: agent.id) }
        }
        let rowStack = NSStackView()
        rowStack.orientation = .horizontal; rowStack.alignment = .centerY; rowStack.spacing = 10; rowStack.translatesAutoresizingMaskIntoConstraints = false
        let contentInset: CGFloat
        if kind == .spaces {
            // `.spaces-row`: 10px list padding + 10px row padding, 13.5px text, counts pushed right.
            contentInset = 20
            let space = spaces[row]
            let isSelected = space.id == sidebar?.selectedSpaceID
            let iconName: CorralLegacyIcon = switch space.kind { case .allSpaces: .grid; case .favorites: .star; case .workspace: .folder }
            let icon = NSImageView(image: CorralLegacyIcon.image(iconName, size: 15) ?? NSImage())
            icon.contentTintColor = space.kind == .favorites ? CorralAestheticTokens.warning : CorralAestheticTokens.icon
            let label = NSTextField(labelWithString: space.name)
            label.font = .systemFont(ofSize: 13.5, weight: isSelected ? .semibold : .regular); label.textColor = CorralAestheticTokens.text
            label.lineBreakMode = .byTruncatingTail; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); label.setContentHuggingPriority(.init(1), for: .horizontal)
            rowStack.addArrangedSubview(icon); rowStack.addArrangedSubview(label)
            if space.kind == .workspace {
                let add = NSButton(title: "", target: sidebar, action: #selector(CorralSidebarView.createAgentForSpaceButton(_:)))
                add.image = CorralLegacyIcon.image(.plus, size: 13, tint: CorralAestheticTokens.icon); add.imagePosition = .imageOnly; add.imageScaling = .scaleProportionallyDown
                add.isBordered = false; add.contentTintColor = CorralAestheticTokens.icon; add.toolTip = "在 \(space.name) 中新建 Agent"; add.setAccessibilityLabel(add.toolTip ?? "新建 Agent")
                add.identifier = NSUserInterfaceItemIdentifier(CorralSidebarRowView.hoverControlPrefix + space.id.uuidString); add.alphaValue = 0; add.translatesAutoresizingMaskIntoConstraints = false
                add.widthAnchor.constraint(equalToConstant: 20).isActive = true; add.heightAnchor.constraint(equalToConstant: 20).isActive = true
                rowStack.addArrangedSubview(add)
            }
            if space.workingCount > 0 {
                let working = CorralStatusIndicatorView(); working.status = .working; working.translatesAutoresizingMaskIntoConstraints = false
                working.widthAnchor.constraint(equalToConstant: 6).isActive = true; working.heightAnchor.constraint(equalToConstant: 6).isActive = true
                rowStack.addArrangedSubview(working); rowStack.setCustomSpacing(6, after: working)
            }
            let workingCount = NSTextField(labelWithString: "\(space.workingCount)")
            workingCount.font = .monospacedDigitSystemFont(ofSize: 12, weight: space.workingCount > 0 ? .semibold : .regular); workingCount.textColor = space.workingCount > 0 ? CorralAestheticTokens.success : CorralAestheticTokens.textMuted
            let totalCount = NSTextField(labelWithString: "\(space.agentCount)")
            totalCount.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); totalCount.textColor = CorralAestheticTokens.textMuted
            rowStack.addArrangedSubview(workingCount); rowStack.setCustomSpacing(8, after: workingCount); rowStack.addArrangedSubview(totalCount)
        } else {
            // `.agents-row`: 10px list padding + 2px border + 12px row padding, 8px dot, 13.5px medium title.
            contentInset = 24
            let agent = agents[row]
            let status = CorralStatusIndicatorView(); status.status = agent.status; status.translatesAutoresizingMaskIntoConstraints = false
            status.widthAnchor.constraint(equalToConstant: 8).isActive = true; status.heightAnchor.constraint(equalToConstant: 8).isActive = true
            let name = NSTextField(labelWithString: agent.name); name.font = .systemFont(ofSize: 13.5, weight: agent.isActive ? .semibold : .medium); name.textColor = CorralAestheticTokens.text; name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); name.setContentHuggingPriority(.init(1), for: .horizontal)
            rowStack.addArrangedSubview(status)
            if let provider = agent.provider { rowStack.addArrangedSubview(CorralProviderIconView(provider: provider, size: 18, active: agent.status == .working || agent.status == .blocked)) }
            rowStack.addArrangedSubview(name)
            var marks: [NSView] = []
            func mark(_ icon: CorralLegacyIcon, _ tint: NSColor) -> NSImageView { let view = NSImageView(image: CorralLegacyIcon.image(icon, size: 12) ?? NSImage()); view.contentTintColor = tint; return view }
            if agent.status == .done { marks.append(mark(.check, CorralAestheticTokens.success)) }
            if agent.isFavorite { marks.append(mark(.star, CorralAestheticTokens.warning)) }
            if let device = agent.deviceName {
                let badge = CorralDeviceBadgeView(); badge.configure(deviceName: device, deviceCount: sidebar?.devices.count ?? 0)
                marks.append(badge)
            }
            for mark in marks { rowStack.addArrangedSubview(mark); rowStack.setCustomSpacing(5, after: mark) }
            cell.alphaValue = agent.isClosing ? 0.4 : 1
        }
        cell.addSubview(rowStack)
        NSLayoutConstraint.activate([rowStack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: contentInset), rowStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -contentInset), rowStack.topAnchor.constraint(equalTo: cell.topAnchor), rowStack.bottomAnchor.constraint(equalTo: cell.bottomAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if kind == .spaces, spaces.indices.contains(table.selectedRow) { sidebar?.selectSpace(spaces[table.selectedRow]) }
        if kind == .agents, agents.indices.contains(table.selectedRow) { sidebar?.onSelectAgent?(agents[table.selectedRow].id) }
    }
    func tableView(_ tableView: NSTableView, menuFor event: NSEvent, row: Int) -> NSMenu? {
        if kind == .spaces, spaces.indices.contains(row), !spaces[row].isVirtual { return sidebar?.spaceContextMenu(for: spaces[row].id) }
        guard kind == .agents, agents.indices.contains(row) else { return nil }
        return sidebar?.agentContextMenu(for: agents[row].id)
    }
}

@MainActor
public final class CorralSidebarView: NSView {
    public let spacesTable = NSTableView()
    public let agentsTable = NSTableView()
    public let deviceBadgeView = CorralDeviceBadgeView()
    public let devicesButton = NSButton(title: "设备", target: nil, action: nil)
    public let settingsButton = CorralSettingsButton()
    public var onSettings: (() -> Void)?
    public var onCreateAgent: ((UUID?) -> Void)?
    public var onCreateSpace: (() -> Void)?
    public var onSelectSpace: ((UUID) -> Void)?
    public var onSelectAgent: ((UUID) -> Void)?
    public var onToggleFavorite: ((UUID, Bool) -> Void)?
    public var onOpenAgent: ((UUID) -> Void)?
    public var onCloseAgent: ((UUID) -> Void)?
    public var onToggleDevices: (() -> Void)?
    public private(set) var spaces: [CorralSidebarSpace] = []
    public private(set) var agents: [CorralSidebarAgent] = []
    public private(set) var devices: [CorralSidebarDevice] = []
    public private(set) var selectedSpaceID = CorralSidebarSpace.allSpacesID
    public private(set) var spacesExpanded = true
    public private(set) var agentsExpanded = true
    private let spaceData = SidebarTableData(.spaces)
    private let agentData = SidebarTableData(.agents)
    private let spacesHeader = CorralSidebarSectionHeader(title: "Spaces")
    private let agentsHeader = CorralSidebarSectionHeader(title: "Agents")
    private let spacesScroll = NSScrollView()
    private let agentsScroll = NSScrollView()
    private var contextMenuControllers: [UUID: SessionContextMenuController] = [:]
    private var allAgents: [CorralSidebarAgent] = []
    private let footerStatus = NSTextField(labelWithString: "未连接设备")
    private let footerStatusDot = NSView()
    private let footerBorder = NSView()
    private var spacesHeight: NSLayoutConstraint!
    public static let spaceRowHeight: CGFloat = 32
    public static let agentRowHeight: CGFloat = 34
    public static let spacesMaximumHeight: CGFloat = 288
    public static let footerHeight: CGFloat = 44

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.backgroundColor = CorralAestheticTokens.surface0.cgColor
        spaceData.sidebar = self; agentData.sidebar = self
        configureTable(spacesTable, data: spaceData); configureTable(agentsTable, data: agentData)
        configureScroll(spacesScroll, table: spacesTable); configureScroll(agentsScroll, table: agentsTable)
        spacesHeader.onToggle = { [weak self] in self?.setSpacesExpanded(!(self?.spacesExpanded ?? true)) }
        agentsHeader.onToggle = { [weak self] in self?.setAgentsExpanded(!(self?.agentsExpanded ?? true)) }
        // `.sidebar-footer`: 44px, 1px top border, padding 4px 8px 4px 12px; 34px devices hit area + 34px settings.
        let footer = NSView()
        footerBorder.wantsLayer = true; footerBorder.layer?.backgroundColor = CorralAestheticTokens.border.cgColor; footerBorder.translatesAutoresizingMaskIntoConstraints = false
        devicesButton.target = self; devicesButton.action = #selector(toggleDevices); devicesButton.image = CorralLegacyIcon.image(.layers, size: 15, tint: CorralAestheticTokens.text); devicesButton.imagePosition = .imageLeading; devicesButton.imageHugsTitle = true
        devicesButton.font = .systemFont(ofSize: 13, weight: .semibold); devicesButton.isBordered = false; devicesButton.contentTintColor = CorralAestheticTokens.text; devicesButton.setAccessibilityLabel("设备管理"); devicesButton.setAccessibilityIdentifier("corral.sidebar.devices"); devicesButton.translatesAutoresizingMaskIntoConstraints = false
        footerStatus.font = .systemFont(ofSize: 11); footerStatus.textColor = CorralAestheticTokens.textMuted; footerStatus.translatesAutoresizingMaskIntoConstraints = false
        footerStatusDot.wantsLayer = true; footerStatusDot.layer?.cornerRadius = 3.5; footerStatusDot.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.setAccessibilityIdentifier("corral.sidebar.settings")
        settingsButton.target = self; settingsButton.action = #selector(openSettings); settingsButton.translatesAutoresizingMaskIntoConstraints = false
        for view in [footerBorder, devicesButton, footerStatus, footerStatusDot, settingsButton] { footer.addSubview(view) }
        NSLayoutConstraint.activate([
            footerBorder.leadingAnchor.constraint(equalTo: footer.leadingAnchor), footerBorder.trailingAnchor.constraint(equalTo: footer.trailingAnchor), footerBorder.topAnchor.constraint(equalTo: footer.topAnchor), footerBorder.heightAnchor.constraint(equalToConstant: 1),
            devicesButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 20), devicesButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor), devicesButton.heightAnchor.constraint(equalToConstant: 34),
            footerStatus.leadingAnchor.constraint(equalTo: devicesButton.trailingAnchor, constant: 8), footerStatus.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            footerStatusDot.leadingAnchor.constraint(equalTo: footerStatus.trailingAnchor, constant: 8), footerStatusDot.centerYAnchor.constraint(equalTo: footer.centerYAnchor), footerStatusDot.widthAnchor.constraint(equalToConstant: 7), footerStatusDot.heightAnchor.constraint(equalToConstant: 7),
            footerStatusDot.trailingAnchor.constraint(lessThanOrEqualTo: settingsButton.leadingAnchor, constant: -8),
            settingsButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -8), settingsButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor), settingsButton.widthAnchor.constraint(equalToConstant: 34), settingsButton.heightAnchor.constraint(equalToConstant: 34)
        ])
        let stack = NSStackView(views: [spacesHeader, spacesScroll, agentsHeader, agentsScroll, footer])
        stack.orientation = .vertical; stack.alignment = .width; stack.distribution = .fill; stack.spacing = 0; stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setClippingResistancePriority(.defaultLow, for: .vertical)
        addSubview(stack)
        spacesHeight = spacesScroll.heightAnchor.constraint(equalToConstant: 0)
        let agentsFill = agentsScroll.heightAnchor.constraint(equalToConstant: 10_000); agentsFill.priority = .defaultLow
        NSLayoutConstraint.activate([
            spacesHeader.heightAnchor.constraint(equalToConstant: CorralSidebarSectionHeader.height), agentsHeader.heightAnchor.constraint(equalToConstant: CorralSidebarSectionHeader.height),
            spacesHeight, agentsFill, footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setSpaces([])
        setDevices([])
    }

    public override func layout() {
        super.layout()
        sizeDocumentView(spacesTable, in: spacesScroll)
        sizeDocumentView(agentsTable, in: agentsScroll)
    }
    public required init?(coder: NSCoder) { fatalError("CorralSidebarView is created programmatically") }
    public convenience init(devices: [CorralSidebarDevice]) { self.init(frame: .zero); setDevices(devices) }
    public func setSpaces(_ spaces: [CorralSidebarSpace]) {
        let workspaces = spaces.filter { $0.kind == .workspace && !$0.isVirtual }
        self.spaces = [
            CorralSidebarSpace(id: CorralSidebarSpace.allSpacesID, name: "All Spaces", kind: .allSpaces),
            CorralSidebarSpace(id: CorralSidebarSpace.favoritesID, name: "收藏", kind: .favorites)
        ] + workspaces
        applyAgentCounts()
        spaceData.spaces = self.spaces
        if !self.spaces.contains(where: { $0.id == selectedSpaceID }) { selectedSpaceID = CorralSidebarSpace.allSpacesID }
        spacesTable.reloadData()
        spacesHeight.constant = min(CGFloat(self.spaces.count) * Self.spaceRowHeight, Self.spacesMaximumHeight)
        if let index = self.spaces.firstIndex(where: { $0.id == selectedSpaceID }) { spacesTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        refreshVisibleAgents()
        updateSectionHeaders()
    }
    public func agentContextMenu(for id: UUID) -> NSMenu? {
        guard let agent = agents.first(where: { $0.id == id }) else { return nil }
        let controller = SessionContextMenuBuilder.makeMenu(for: agent.id, isFavorite: agent.isFavorite,
            onFavorite: { [weak self] id, value in self?.onToggleFavorite?(id, value) },
            onClose: { [weak self] id in self?.onCloseAgent?(id) })
        contextMenuControllers[id] = controller
        return controller.menu
    }
    public func spaceContextMenu(for id: UUID) -> NSMenu? {
        guard let space = spaces.first(where: { $0.id == id && $0.kind == .workspace }) else { return nil }
        let menu = NSMenu(title: space.name)
        let item = menu.addItem(withTitle: "新建 Agent", action: #selector(createAgentForSpace(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = id; item.image = CorralLegacyIcon.image(.plus, size: 14)
        return menu
    }
    @objc fileprivate func createAgentForSpace(_ item: NSMenuItem) { if let id = item.representedObject as? UUID { onCreateAgent?(id) } }
    @objc fileprivate func createAgentForSpaceButton(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: String(raw.dropFirst(CorralSidebarRowView.hoverControlPrefix.count))) else { return }
        onCreateAgent?(id)
    }
    fileprivate func selectSpace(_ space: CorralSidebarSpace) {
        selectedSpaceID = space.id
        spacesTable.reloadData(forRowIndexes: IndexSet(integersIn: 0..<spacesTable.numberOfRows), columnIndexes: IndexSet(integer: 0))
        refreshVisibleAgents(); updateSectionHeaders()
        onSelectSpace?(space.id)
    }
    public func setAgents(_ agents: [CorralSidebarAgent]) {
        allAgents = agents
        refreshVisibleAgents(); updateSpaceCounts(); updateSectionHeaders()
    }
    public func setSpacesExpanded(_ expanded: Bool) { spacesExpanded = expanded; spacesScroll.isHidden = !expanded; updateSectionHeaders() }
    public func selectSpace(id: UUID) {
        guard let space = spaces.first(where: { $0.id == id }) else { return }
        selectSpace(space)
    }
    public func setAgentsExpanded(_ expanded: Bool) { agentsExpanded = expanded; agentsScroll.isHidden = !expanded; updateSectionHeaders() }
    public func refreshTheme() {
        layer?.backgroundColor = CorralAestheticTokens.surface0.cgColor
        spacesTable.backgroundColor = CorralAestheticTokens.surface0
        agentsTable.backgroundColor = CorralAestheticTokens.surface0
        footerStatus.textColor = CorralAestheticTokens.textMuted
        footerBorder.layer?.backgroundColor = CorralAestheticTokens.border.cgColor
        devicesButton.image = CorralLegacyIcon.image(.layers, size: 15, tint: CorralAestheticTokens.text)
        spacesHeader.refreshTheme(); agentsHeader.refreshTheme()
        settingsButton.refreshTheme()
        spacesTable.reloadData(forRowIndexes: IndexSet(integersIn: 0..<spaces.count), columnIndexes: IndexSet(integer: 0)); agentsTable.reloadData()
        updateSectionHeaders()
    }
    public func setDevices(_ devices: [CorralSidebarDevice]) {
        self.devices = devices
        footerStatus.stringValue = devices.isEmpty ? "未连接设备" : "\(devices.count) 台设备"
        let online = devices.contains(where: \.isOnline)
        footerStatusDot.layer?.backgroundColor = online ? CorralAestheticTokens.success.cgColor : NSColor.clear.cgColor
        footerStatusDot.layer?.borderColor = online ? NSColor.clear.cgColor : CorralAestheticTokens.idleDot.cgColor
        footerStatusDot.layer?.borderWidth = online ? 0 : 1
        footerStatusDot.toolTip = online ? "至少一台设备在线" : "设备离线"
        let sessions = devices.flatMap { device in device.sessions.map { CorralSidebarAgent(id: $0.id, name: $0.name, status: .idle, deviceName: device.name) } }
        setAgents(sessions)
        deviceBadgeView.configure(deviceName: devices.first?.name ?? "", deviceCount: devices.count)
    }
    private func refreshVisibleAgents() {
        let selectedKind = spaces.first(where: { $0.id == selectedSpaceID })?.kind ?? .allSpaces
        let visible: [CorralSidebarAgent] = switch selectedKind {
        case .allSpaces: allAgents
        case .favorites: allAgents.filter(\.isFavorite)
        case .workspace: allAgents.filter { $0.spaceID == selectedSpaceID }
        }
        agents = visible.enumerated().sorted { lhs, rhs in
            if lhs.element.isFavorite != rhs.element.isFavorite { return lhs.element.isFavorite }
            return lhs.offset < rhs.offset
        }.map(\.element)
        agentData.agents = agents; agentsTable.reloadData()
    }
    /// Every row's `working / total` is derived from the agents themselves, including real workspace rows.
    private func applyAgentCounts() {
        for index in spaces.indices {
            let members: [CorralSidebarAgent] = switch spaces[index].kind {
            case .allSpaces: allAgents
            case .favorites: allAgents.filter(\.isFavorite)
            case .workspace: allAgents.filter { $0.spaceID == spaces[index].id }
            }
            spaces[index].agentCount = members.count
            spaces[index].workingCount = members.filter { $0.status == .working }.count
        }
    }
    private func updateSpaceCounts() {
        guard spaces.count >= 2 else { return }
        applyAgentCounts()
        spaceData.spaces = spaces
        spacesTable.reloadData(forRowIndexes: IndexSet(integersIn: 0..<spaces.count), columnIndexes: IndexSet(integer: 0))
    }
    private func updateSectionHeaders() {
        spacesHeader.update(isExpanded: spacesExpanded, hasWorking: spaces.contains { $0.workingCount > 0 })
        let selected = spaces.first { $0.id == selectedSpaceID }
        let agentsTitle = switch selected?.kind {
        case .favorites: "收藏的 Agents"
        case .workspace: "\(selected?.name ?? "Space") 的 Agents"
        default: "Agents"
        }
        agentsHeader.setTitle(agentsTitle)
        agentsHeader.update(isExpanded: agentsExpanded, hasWorking: agents.contains { $0.status == .working })
    }
    private func configureTable(_ table: NSTableView, data: SidebarTableData) {
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        table.headerView = nil; table.rowSizeStyle = .custom; table.intercellSpacing = .zero; table.backgroundColor = CorralAestheticTokens.surface0; table.style = .plain; table.selectionHighlightStyle = .regular
        table.dataSource = data; table.delegate = data; table.usesAutomaticRowHeights = false
    }
    private func configureScroll(_ scroll: NSScrollView, table: NSTableView) {
        table.autoresizingMask = [.width]
        scroll.documentView = table; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder; scroll.translatesAutoresizingMaskIntoConstraints = false
    }
    private func sizeDocumentView(_ table: NSTableView, in scroll: NSScrollView) {
        let rowsHeight = CGFloat(table.numberOfRows) * (table === spacesTable ? Self.spaceRowHeight : Self.agentRowHeight)
        let size = NSSize(width: max(1, scroll.contentSize.width), height: max(scroll.contentSize.height, rowsHeight))
        if table.frame.size != size { table.setFrameSize(size) }
    }
    @objc private func toggleDevices() { onToggleDevices?() }
    @objc private func openSettings() { onSettings?() }
}

@MainActor
public final class SplitDropZoneView: NSView {
    public enum Edge: String, Sendable { case left, right, top, bottom, center }
    public var edge: Edge = .center { didSet { needsDisplay = true } }
    public override func draw(_ dirtyRect: NSRect) {
        var rect = bounds.insetBy(dx: 2, dy: 2)
        switch edge {
        case .left: rect.size.width *= 0.25
        case .right: rect.origin.x += rect.width * 0.75; rect.size.width *= 0.25
        case .bottom: rect.size.height *= 0.25
        case .top: rect.origin.y += rect.height * 0.75; rect.size.height *= 0.25
        case .center: break
        }
        CorralAestheticTokens.accent.withAlphaComponent(0.16).setFill(); NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        CorralAestheticTokens.accent.setStroke(); let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 6, yRadius: 6); outline.lineWidth = 2; outline.stroke()
    }
}

@MainActor
public final class CorralWorkspaceStageView: NSView {
    public var onDropTab: ((UUID, SplitDropZoneView.Edge) -> Void)?
    public var activeTabID: UUID?
    public let dropZone = SplitDropZoneView()
    public private(set) var emptyStateLabel: NSTextField?
    public var onCreateAgent: (() -> Void)?
    private var emptyActionButton: NSButton?
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); registerForDraggedTypes([.string]); dropZone.isHidden = true; addSubview(dropZone)
        wantsLayer = true; layer?.backgroundColor = CorralAestheticTokens.background.cgColor
    }
    public required init?(coder: NSCoder) { fatalError("CorralWorkspaceStageView is created programmatically") }
    public override func layout() { super.layout(); dropZone.frame = bounds.insetBy(dx: 2, dy: 2) }
    public func showEmptyState(_ show: Bool, action: (() -> Void)?) {
        if let action { onCreateAgent = action }
        guard show else { emptyStateLabel?.removeFromSuperview(); emptyActionButton?.removeFromSuperview(); emptyStateLabel = nil; emptyActionButton = nil; return }
        guard emptyStateLabel == nil else { return }
        let label = NSTextField(labelWithString: "选择 Space 或新建 Agent 开始工作")
        label.font = .systemFont(ofSize: 14); label.textColor = CorralAestheticTokens.textMuted; label.alignment = .center; label.translatesAutoresizingMaskIntoConstraints = false
        let button = NSButton(title: "新建 Agent", target: self, action: #selector(createAgent)); button.bezelStyle = .rounded; button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label); addSubview(button); NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -22), button.centerXAnchor.constraint(equalTo: centerXAnchor), button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12)])
        emptyStateLabel = label; emptyActionButton = button
    }
    @objc private func createAgent() { onCreateAgent?() }
    public func edge(at normalizedPoint: NSPoint) -> SplitDropZoneView.Edge {
        normalizedPoint.x < 0.25 ? .left : normalizedPoint.x > 0.75 ? .right : normalizedPoint.y < 0.25 ? .bottom : normalizedPoint.y > 0.75 ? .top : .center
    }
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .move }
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let x = point.x / max(bounds.width, 1); let y = point.y / max(bounds.height, 1)
        dropZone.edge = edge(at: NSPoint(x: x, y: y))
        dropZone.isHidden = false
        return .move
    }
    public override func draggingExited(_ sender: NSDraggingInfo?) { dropZone.isHidden = true }
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropZone.isHidden = true }
        guard let raw = sender.draggingPasteboard.string(forType: .string), let id = UUID(uuidString: raw) else { return false }
        onDropTab?(id, dropZone.edge); return true
    }
}

@MainActor
public final class SplitWorkspaceView: NSView, NSSplitViewDelegate {
    public private(set) var splitterCount = 0
    public let stageViews: [SessionID: NSView]
    public private(set) var root: WorkspaceLayoutNode?
    public var onRatioChange: (([Int], Double) -> Void)?
    public private(set) var focusedSessionID: SessionID?
    private var splitViews: [NSSplitView] = []
    private var splitPaths: [ObjectIdentifier: [Int]] = [:]
    private var initialRatios: [ObjectIdentifier: Double] = [:]
    private var latestRatios: [ObjectIdentifier: Double] = [:]

    public init(root: WorkspaceLayoutNode?, stageViews: [SessionID: NSView]) {
        self.root = root; self.stageViews = stageViews
        super.init(frame: .zero); wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor
        rebuild()
    }
    public override var isOpaque: Bool { false }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        for split in splitViews {
            guard let first = split.arrangedSubviews.first else { continue }
            let local = split.convert(point, from: self)
            let divider = split.isVertical ? first.frame.maxX : first.frame.maxY
            let position = split.isVertical ? local.x : local.y
            let crossAxis = split.isVertical ? local.y : local.x
            let crossExtent = split.isVertical ? split.bounds.height : split.bounds.width
            if crossAxis >= 0, crossAxis <= crossExtent, abs(position - divider) <= max(5, split.dividerThickness) {
                return split
            }
        }
        return nil
    }
    public required init?(coder: NSCoder) { fatalError("SplitWorkspaceView is created programmatically") }
    public func updateRoot(_ root: WorkspaceLayoutNode?) { self.root = root; rebuild() }
    public func split(_ source: SessionID, beside target: SessionID, direction: SplitDirection, ratio: Double = 0.5) {
        guard let root else { self.root = .session(source); rebuild(); return }
        self.root = inserting(source, at: target, in: root, direction: direction, ratio: ratio); rebuild()
    }
    public func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let minimum: CGFloat = splitView.isVertical ? 120 : 60
        return min(extent - minimum, max(minimum, proposedPosition))
    }
    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let split = notification.object as? NSSplitView, split.arrangedSubviews.count > 1 else { return }
        let extent = split.isVertical ? split.bounds.width : split.bounds.height
        guard extent > 0 else { return }
        let divider = split.dividerThickness
        let usable = max(1, extent - divider)
        let ratio = Double((split.isVertical ? split.arrangedSubviews[0].frame.width : split.arrangedSubviews[0].frame.height) / usable)
        latestRatios[ObjectIdentifier(split)] = min(0.95, max(0.05, ratio))
    }
    private func build(_ node: WorkspaceLayoutNode, path: [Int] = []) -> NSView {
        switch node {
        case .session(let id): return stageViews[id] ?? NSView()
        case .split(let direction, let ratio, let first, let second):
            let split = CorralNativeSplitView(); split.isVertical = direction == .horizontal; split.dividerStyle = .thin; split.delegate = self; splitViews.append(split)
            let splitID = ObjectIdentifier(split)
            splitPaths[splitID] = path
            initialRatios[splitID] = ratio
            split.onResizeFinished = { [weak self, weak split] in
                guard let self, let split else { return }
                let id = ObjectIdentifier(split)
                guard let ratio = self.latestRatios[id], abs(ratio - (self.initialRatios[id] ?? ratio)) >= 0.0001 else { return }
                self.onRatioChange?(self.splitPaths[id] ?? [], ratio)
            }
            split.addArrangedSubview(build(first, path: path + [0])); split.addArrangedSubview(build(second, path: path + [1])); splitterCount += 1
            DispatchQueue.main.async { [weak split] in guard let split else { return }; let extent = split.isVertical ? split.bounds.width : split.bounds.height; let usable = extent - split.dividerThickness; if usable > 0 { split.setPosition(usable * CGFloat(ratio), ofDividerAt: 0) } }
            return split
        }
    }
    public func focus(_ sessionID: SessionID) {
        focusedSessionID = sessionID
        for (id, view) in stageViews {
            view.wantsLayer = true
            view.layer?.borderWidth = id == sessionID ? 2 : 0
            view.layer?.borderColor = id == sessionID ? CorralAestheticTokens.accent.cgColor : NSColor.clear.cgColor
        }
    }
    private func inserting(_ source: SessionID, at target: SessionID, in node: WorkspaceLayoutNode, direction: SplitDirection, ratio: Double) -> WorkspaceLayoutNode {
        switch node {
        case .session(let id) where id == target: return .split(direction: direction, ratio: ratio, first: .session(target), second: .session(source))
        case .session: return node
        case .split(let axis, let oldRatio, let first, let second): return .split(direction: axis, ratio: oldRatio, first: inserting(source, at: target, in: first, direction: direction, ratio: ratio), second: inserting(source, at: target, in: second, direction: direction, ratio: ratio))
        }
    }
    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }; splitViews.removeAll(); splitPaths.removeAll(); initialRatios.removeAll(); latestRatios.removeAll(); splitterCount = 0
        guard let root else { return }
        let content = build(root); content.translatesAutoresizingMaskIntoConstraints = false; addSubview(content)
        if let focusedSessionID { focus(focusedSessionID) }
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor), content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
}

@MainActor
private final class CorralNativeSplitView: NSSplitView {
    var onResizeFinished: (() -> Void)?
    override var dividerThickness: CGFloat { 6 }
    override func drawDivider(in rect: NSRect) { CorralAestheticTokens.borderSubtle.setFill(); NSBezierPath(rect: rect).fill() }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onResizeFinished?()
    }
}

@MainActor
public final class CorralSidebarTitleBarView: NSView {
    public var onToggleSidebar: (() -> Void)?
    private let trafficLightsSpacer = NSView()
    public let collapseButton = NSButton(title: "▤", target: nil, action: nil)
    private let dragRegion = CorralWindowDragRegion()
    private let bottomBorder = NSView()
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); wantsLayer = true; layer?.backgroundColor = CorralAestheticTokens.surface0.cgColor
        trafficLightsSpacer.translatesAutoresizingMaskIntoConstraints = false
        bottomBorder.wantsLayer = true; bottomBorder.layer?.backgroundColor = CorralAestheticTokens.border.cgColor; bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        dragRegion.translatesAutoresizingMaskIntoConstraints = false; addSubview(dragRegion); addSubview(trafficLightsSpacer); addSubview(collapseButton); addSubview(bottomBorder)
        collapseButton.image = CorralLegacyIcon.image(.sidebar, size: 16)
        collapseButton.title = ""; collapseButton.imagePosition = .imageOnly; collapseButton.imageScaling = .scaleProportionallyDown; collapseButton.isBordered = false; collapseButton.contentTintColor = CorralAestheticTokens.icon; collapseButton.translatesAutoresizingMaskIntoConstraints = false
        collapseButton.target = self; collapseButton.action = #selector(toggle); collapseButton.toolTip = "隐藏侧边栏"; collapseButton.setAccessibilityLabel("隐藏侧边栏"); collapseButton.setAccessibilityIdentifier("corral.sidebar.toggle")
        NSLayoutConstraint.activate([
            trafficLightsSpacer.leadingAnchor.constraint(equalTo: leadingAnchor), trafficLightsSpacer.topAnchor.constraint(equalTo: topAnchor), trafficLightsSpacer.bottomAnchor.constraint(equalTo: bottomAnchor), trafficLightsSpacer.widthAnchor.constraint(equalToConstant: 80),
            collapseButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 88), collapseButton.centerYAnchor.constraint(equalTo: centerYAnchor), collapseButton.widthAnchor.constraint(equalToConstant: 28), collapseButton.heightAnchor.constraint(equalToConstant: 26),
            dragRegion.leadingAnchor.constraint(equalTo: collapseButton.trailingAnchor, constant: 8), dragRegion.trailingAnchor.constraint(equalTo: trailingAnchor), dragRegion.topAnchor.constraint(equalTo: topAnchor), dragRegion.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor), bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor), bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor), bottomBorder.heightAnchor.constraint(equalToConstant: 1)
        ])
    }
    public required init?(coder: NSCoder) { fatalError("CorralSidebarTitleBarView is created programmatically") }
    public func refreshTheme() { layer?.backgroundColor = CorralAestheticTokens.surface0.cgColor; bottomBorder.layer?.backgroundColor = CorralAestheticTokens.border.cgColor; collapseButton.contentTintColor = CorralAestheticTokens.icon }
    @objc private func toggle() { onToggleSidebar?() }
}

public typealias CorralTitleBarView = CorralSidebarTitleBarView

@MainActor
public final class TabSwitchTelemetry {
    public private(set) var fitCount = 0
    public private(set) var subscribeCount = 0
    public private(set) var unsubscribeCount = 0
    public private(set) var resizeCount = 0
    public private(set) var resetCount = 0
    public private(set) var isRecordingSwitch = false
    public var allCountsAreZero: Bool { fitCount == 0 && subscribeCount == 0 && unsubscribeCount == 0 && resizeCount == 0 && resetCount == 0 }
    fileprivate func beginSwitch() { fitCount = 0; subscribeCount = 0; unsubscribeCount = 0; resizeCount = 0; resetCount = 0; isRecordingSwitch = true }
    fileprivate func endSwitch() { isRecordingSwitch = false }
    public func recordFit() { if isRecordingSwitch { fitCount += 1 } }
    public func recordSubscribe() { if isRecordingSwitch { subscribeCount += 1 } }
    public func recordUnsubscribe() { if isRecordingSwitch { unsubscribeCount += 1 } }
    public func recordResize() { if isRecordingSwitch { resizeCount += 1 } }
    public func recordReset() { if isRecordingSwitch { resetCount += 1 } }
}

@MainActor
public final class CorralWorkspaceView: NSView {
    public let tabBar = CorralTabBarView()
    public let sidebar: CorralSidebarView
    public let stageContainer = CorralWorkspaceStageView()
    public let tabSwitchTelemetry = TabSwitchTelemetry()
    public private(set) var tabs: [CorralTab] = []
    public private(set) var activeTabID: UUID?
    public let titleBar = CorralSidebarTitleBarView()
    public var onCreateTab: (() -> Void)?
    public var onSettings: (() -> Void)?
    public var onCreateAgent: ((UUID?) -> Void)?
    public var onToggleSidebar: (() -> Void)?
    public var onSelectAgent: ((UUID) -> Void)?
    public var onSplit: ((UUID, SplitDropZoneView.Edge) -> Void)?
    public var onDropTab: ((UUID, UUID?, SplitDropZoneView.Edge) -> Void)?
    public var onOpenSession: ((UUID, UUID?, Bool) -> Void)?
    public var onFocusSession: ((UUID, UUID) -> Void)?
    public var onDevices: (() -> Void)?
    public var onTabContextAction: ((UUID, String) -> Void)?
    public private(set) var previewSessionID: UUID?
    public var isSidebarCollapsed: Bool { !sidebarIsVisible }
    public static let sidebarWidth: CGFloat = 280
    public static let headerHeight: CGFloat = 38
    private var sidebarColumnWidth: NSLayoutConstraint!
    private var sidebarIsVisible = true

    public init(tabs: [CorralTab] = [], sidebar: CorralSidebarView = CorralSidebarView()) {
        self.sidebar = sidebar
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = CorralAestheticTokens.background.cgColor
        let left = NSView(); left.translatesAutoresizingMaskIntoConstraints = false
        let right = NSView(); right.translatesAutoresizingMaskIntoConstraints = false
        for view in [left, right] { addSubview(view) }
        for view in [titleBar, sidebar] { view.translatesAutoresizingMaskIntoConstraints = false; left.addSubview(view) }
        for view in [tabBar, stageContainer] { view.translatesAutoresizingMaskIntoConstraints = false; right.addSubview(view) }
        sidebarColumnWidth = left.widthAnchor.constraint(equalToConstant: Self.sidebarWidth)
        NSLayoutConstraint.activate([
            sidebarColumnWidth,
            left.leadingAnchor.constraint(equalTo: leadingAnchor), left.topAnchor.constraint(equalTo: topAnchor), left.bottomAnchor.constraint(equalTo: bottomAnchor),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor), right.trailingAnchor.constraint(equalTo: trailingAnchor), right.topAnchor.constraint(equalTo: topAnchor), right.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleBar.leadingAnchor.constraint(equalTo: left.leadingAnchor), titleBar.trailingAnchor.constraint(equalTo: left.trailingAnchor), titleBar.topAnchor.constraint(equalTo: left.topAnchor), titleBar.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            sidebar.leadingAnchor.constraint(equalTo: left.leadingAnchor), sidebar.trailingAnchor.constraint(equalTo: left.trailingAnchor), sidebar.topAnchor.constraint(equalTo: titleBar.bottomAnchor), sidebar.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: right.leadingAnchor), tabBar.trailingAnchor.constraint(equalTo: right.trailingAnchor), tabBar.topAnchor.constraint(equalTo: right.topAnchor), tabBar.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            stageContainer.leadingAnchor.constraint(equalTo: right.leadingAnchor), stageContainer.trailingAnchor.constraint(equalTo: right.trailingAnchor), stageContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor), stageContainer.bottomAnchor.constraint(equalTo: right.bottomAnchor)
        ])
        titleBar.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        tabBar.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        tabBar.bindSidebarToggleButton(titleBar.collapseButton)
        tabBar.bindDevicesButton(sidebar.devicesButton)
        sidebar.onSettings = { [weak self] in self?.onSettings?() }; sidebar.onCreateAgent = { [weak self] in self?.onCreateAgent?($0) }; sidebar.onToggleDevices = { [weak self] in self?.onDevices?() }
        sidebar.onSelectAgent = { [weak self] id in self?.smartOpenSession(id); self?.onSelectAgent?(id) }
        tabBar.onSelectTab = { [weak self] in self?.selectTab(id: $0) }; tabBar.onCreateTab = { [weak self] in self?.onCreateTab?() }; tabBar.onCloseTab = { [weak self] in self?.closeTab(id: $0) }
        tabBar.onRenameTab = { [weak self] id, title in self?.renameTab(id: id, title: title) }; tabBar.onReorderTabs = { [weak self] id, index in self?.reorderTab(id: id, to: index) }
        tabBar.onContextAction = { [weak self] id, action in self?.performTabContextAction(id, action) }
        stageContainer.onDropTab = { [weak self] id, edge in self?.handleDrop(id, edge: edge) }
        stageContainer.onCreateAgent = { [weak self] in self?.onCreateAgent?(nil) }
        let orderedTabs = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
        for tab in orderedTabs { attach(tab) }
        self.tabs = orderedTabs; tabBar.setTabs(orderedTabs, selectedTabID: nil); stageContainer.showEmptyState(orderedTabs.isEmpty, action: nil)
        if let first = orderedTabs.first { selectTab(id: first.id) }
    }
    public required init?(coder: NSCoder) { fatalError("CorralWorkspaceView is created programmatically") }
    public func addTab(_ tab: CorralTab, select: Bool = true) { guard !tabs.contains(where: { $0.id == tab.id }) else { return }; attach(tab); tabs.append(tab); stageContainer.showEmptyState(false, action: nil); tabBar.setTabs(tabs, selectedTabID: activeTabID); if select || activeTabID == nil { selectTab(id: tab.id) } }
    public func synchronizeWorkspaceTabs(_ tabs: [CorralTab], selectedTabID: UUID, previewSessionID: UUID?) {
        let ordered = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
        let ids = Set(ordered.map(\.id))
        for tab in self.tabs where !ids.contains(tab.id) { tab.contentView.removeFromSuperview() }
        for tab in ordered where !self.tabs.contains(where: { $0.id == tab.id }) { attach(tab) }
        self.tabs = ordered
        activeTabID = selectedTabID
        self.previewSessionID = previewSessionID
        stageContainer.activeTabID = selectedTabID
        for tab in ordered { tab.contentView.isHidden = tab.id != selectedTabID }
        tabBar.setTabs(ordered, selectedTabID: selectedTabID)
    }
    public func setSidebarCollapsed(_ collapsed: Bool) {
        let isVisible = !collapsed
        guard sidebarIsVisible != isVisible else { return }
        sidebarIsVisible = isVisible
        sidebarColumnWidth.constant = isVisible ? Self.sidebarWidth : 0
        tabBar.setSidebarCollapsed(collapsed)
        titleBar.isHidden = !isVisible
        sidebar.isHidden = !isVisible
    }
    public func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        tabSwitchTelemetry.beginSwitch(); defer { tabSwitchTelemetry.endSwitch() }
        previewSessionID = nil
        activeTabID = id; stageContainer.activeTabID = id
        for tab in tabs { tab.contentView.isHidden = tab.id != id }
        tabBar.setTabs(tabs, selectedTabID: id)
        if let selected = tabs.first(where: { $0.id == id }), let focus = firstFocusableView(in: selected.contentView) { window?.makeFirstResponder(focus) }
    }
    public func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].contentView.removeFromSuperview(); tabs.remove(at: index)
        let next = activeTabID == id ? tabs.dropFirst(max(0, index - 1)).first?.id ?? tabs.last?.id : activeTabID
        activeTabID = nil; tabBar.setTabs(tabs, selectedTabID: next); stageContainer.showEmptyState(tabs.isEmpty, action: nil)
        if let next { selectTab(id: next) }
    }
    public func view(forTab id: UUID) -> NSView? { tabs.first(where: { $0.id == id })?.contentView }
    public func smartOpenSession(_ sessionID: UUID) {
        if let existing = tabs.first(where: { $0.sessionIDs.contains(sessionID) || $0.activeSessionID == sessionID }) {
            previewSessionID = nil; existing.activeSessionID = sessionID; selectTab(id: existing.id); onFocusSession?(sessionID, existing.id); return
        }
        guard let current = tabs.first(where: { $0.id == activeTabID }) ?? tabs.first else {
            previewSessionID = sessionID; onOpenSession?(sessionID, nil, true); return
        }
        if current.isBlankWorkspace {
            current.isBlankWorkspace = false; current.sessionIDs.insert(sessionID); current.activeSessionID = sessionID
            previewSessionID = nil; onOpenSession?(sessionID, current.id, false)
        } else {
            previewSessionID = sessionID; onOpenSession?(sessionID, current.id, true)
        }
    }
    public func renameTab(id: UUID, title: String) { guard !title.isEmpty, let tab = tabs.first(where: { $0.id == id }) else { return }; tab.title = title; tab.isCustomTitle = true; tabBar.setTabs(tabs, selectedTabID: activeTabID) }
    fileprivate func performTabContextAction(_ id: UUID, _ action: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), let tab = tabs.first(where: { $0.id == id }) else { return }
        switch action {
        case "pin":
            tab.isPinned.toggle()
            if tab.isPinned { reorderTab(id: id, to: tabs.filter(\.isPinned).count - 1) }
            else { reorderTab(id: id, to: max(0, tabs.firstIndex(where: { !$0.isPinned }) ?? tabs.count - 1)) }
            tabBar.setTabs(tabs, selectedTabID: activeTabID)
        case "close": closeTab(id: id)
        case "closeOthers": tabs.filter { $0.id != id && !$0.isPinned }.map(\.id).forEach(closeTab(id:))
        case "closeRight": Array(tabs.suffix(from: index + 1)).filter { !$0.isPinned }.map(\.id).forEach(closeTab(id:))
        case "resetTitle": tab.title = tab.defaultTitle; tab.isCustomTitle = false; tabBar.setTabs(tabs, selectedTabID: activeTabID); onTabContextAction?(id, action)
        default: onTabContextAction?(id, action)
        }
    }
    public func reorderTab(id: UUID, to targetIndex: Int) {
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        var remaining = tabs
        let tab = remaining.remove(at: source)
        let pinnedCount = remaining.filter(\.isPinned).count
        let lowerBound = tab.isPinned ? 0 : pinnedCount
        let upperBound = tab.isPinned ? pinnedCount : remaining.count
        let destination = min(max(targetIndex, lowerBound), upperBound)
        guard source != destination else { return }
        remaining.insert(tab, at: destination)
        tabs = remaining
        tabBar.setTabs(tabs, selectedTabID: activeTabID)
    }
    public func setTheme(_ mode: CorralThemeMode) {
        CorralAestheticTokens.themeMode = mode
        window?.backgroundColor = CorralAestheticTokens.surface0
        titleBar.refreshTheme(); sidebar.refreshTheme(); tabBar.refreshTheme()
        applyTheme(to: self)
    }
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        guard event.keyCode == 17 else { return super.performKeyEquivalent(with: event) }
        onCreateTab?()
        return true
    }
    private func toggleSidebar() {
        setSidebarCollapsed(sidebarIsVisible)
        onToggleSidebar?()
    }
    private func handleDrop(_ id: UUID, edge: SplitDropZoneView.Edge) {
        guard let activeTabID, activeTabID != id else { return }
        if edge == .center { tabBar.onSelectTab?(id) } else { onDropTab?(id, activeTabID, edge); onSplit?(id, edge) }
    }
    private func attach(_ tab: CorralTab) {
        let view = tab.contentView; view.translatesAutoresizingMaskIntoConstraints = false; view.isHidden = true; stageContainer.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: stageContainer.leadingAnchor), view.trailingAnchor.constraint(equalTo: stageContainer.trailingAnchor), view.topAnchor.constraint(equalTo: stageContainer.topAnchor), view.bottomAnchor.constraint(equalTo: stageContainer.bottomAnchor)])
    }
    private func firstFocusableView(in view: NSView) -> NSView? { if view.acceptsFirstResponder { return view }; for child in view.subviews { if let result = firstFocusableView(in: child) { return result } }; return nil }
    private func applyTheme(to view: NSView) {
        if view === self || view === sidebar || view === titleBar || view === tabBar { view.layer?.backgroundColor = CorralAestheticTokens.surface0.cgColor }
        if view === stageContainer { view.layer?.backgroundColor = CorralAestheticTokens.background.cgColor }
        if let background = view.layer?.backgroundColor, let color = NSColor(cgColor: background) { view.layer?.backgroundColor = CorralAestheticTokens.remap(color).cgColor }
        if let border = view.layer?.borderColor, let color = NSColor(cgColor: border) { view.layer?.borderColor = CorralAestheticTokens.remap(color).cgColor }
        if let shadow = view.layer?.shadowColor, let color = NSColor(cgColor: shadow) { view.layer?.shadowColor = CorralAestheticTokens.remap(color).cgColor }
        if let field = view as? NSTextField {
            if let textColor = field.textColor { field.textColor = CorralAestheticTokens.remap(textColor) }
            if let backgroundColor = field.backgroundColor { field.backgroundColor = CorralAestheticTokens.remap(backgroundColor) }
        }
        if let button = view as? NSButton, let tint = button.contentTintColor { button.contentTintColor = CorralAestheticTokens.remap(tint) }
        if let table = view as? NSTableView { table.backgroundColor = CorralAestheticTokens.surface0 }
        if let badge = view as? CorralDeviceBadgeView { badge.refreshTheme() }
        if let status = view as? CorralStatusIndicatorView { status.refreshTheme() }
        if let provider = view as? CorralProviderIconView { provider.refreshTheme() }
        if let settings = view as? CorralSettingsButton { settings.refreshTheme() }
        view.subviews.forEach { applyTheme(to: $0) }
        view.needsDisplay = true
    }
}
