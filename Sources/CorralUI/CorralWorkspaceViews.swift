import AppKit
import QuartzCore
import CorralContracts
import CorralServices

@MainActor
public final class CorralTab: Identifiable {
    public let id: UUID
    public var title: String
    public var badge: String?
    public var provider: String?
    public var status: CorralStatusIndicatorView.Status
    public var isPinned: Bool
    public var isPreview = false
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
    private struct ItemAppearance: Equatable {
        let title: String
        let provider: String?
        let status: CorralStatusIndicatorView.Status
        let pinned: Bool
    }
    private var renderedItems: [UUID: (appearance: ItemAppearance, view: CorralTabItemView)] = [:]
    /// Keep every Tab reachable without letting its document widen the window.
    private let tabsLane = NSScrollView()
    private var revealSelectedTab = false
    private var capsuleSelectionAnimationPending = false
    private let bottomBorder = NSView()
    private let activeCapsule = NSView()
    private let trafficLightsSpacer = NSView()
    private let expandSidebarButton = NSButton(title: "▤", target: nil, action: nil)
    private let dragRegion = CorralWindowDragRegion()
    private var itemsLeadingConstraint: NSLayoutConstraint!
    private var isMouseInsideTabBar = false
    private var trackingArea: NSTrackingArea?
    private var lockedTabWidth: CGFloat?
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
        itemsStack.spacing = 2
        itemsStack.translatesAutoresizingMaskIntoConstraints = true
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
        tabsLane.automaticallyAdjustsContentInsets = false
        tabsLane.contentInsets = NSEdgeInsets(top: 0, left: 1, bottom: 0, right: 1)
        tabsLane.drawsBackground = false
        tabsLane.borderType = .noBorder
        tabsLane.hasVerticalScroller = false
        tabsLane.hasHorizontalScroller = false
        tabsLane.horizontalScrollElasticity = .allowed
        tabsLane.documentView = itemsStack
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
            createButton.leadingAnchor.constraint(equalTo: tabsLane.trailingAnchor, constant: 8), createButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            createButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
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
        let selectionChanged = self.selectedTabID != selectedTabID
        self.selectedTabID = selectedTabID
        let regularCount = self.tabs.filter { !$0.isPinned }.count
        let didUnlock = regularCount <= 1 && lockedTabWidth != nil
        if didUnlock { lockedTabWidth = nil }
        var updated: [UUID: (appearance: ItemAppearance, view: CorralTabItemView)] = [:]
        var ordered: [CorralTabItemView] = []
        for tab in self.tabs {
            let appearance = ItemAppearance(title: tab.title, provider: tab.provider, status: tab.status,
                                            pinned: tab.isPinned)
            let item: CorralTabItemView
            if let existing = renderedItems[tab.id], existing.appearance == appearance {
                item = existing.view
                item.tab = tab
                item.setSelected(tab.id == selectedTabID)
            } else { item = CorralTabItemView(tab: tab, selected: tab.id == selectedTabID, owner: self) }
            updated[tab.id] = (appearance, item)
            ordered.append(item)
        }
        renderedItems = updated
        if selectionChanged {
            revealSelectedTab = true
            capsuleSelectionAnimationPending = true
            needsLayout = true
        }
        let existing = itemsStack.arrangedSubviews
        guard existing.count != ordered.count || zip(existing, ordered).contains(where: { $0 !== $1 }) else {
            if didUnlock { updateTabWidths(animated: true) }
            return
        }
        for view in existing where !ordered.contains(where: { $0 === view }) {
            itemsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, view) in ordered.enumerated() {
            if itemsStack.arrangedSubviews.indices.contains(index), itemsStack.arrangedSubviews[index] === view { continue }
            if view.superview === itemsStack { itemsStack.removeArrangedSubview(view) }
            itemsStack.insertArrangedSubview(view, at: index)
            // Keep accessibility/subview traversal in the same order as the lane.
            itemsStack.addSubview(view, positioned: .above, relativeTo: index == 0 ? activeCapsule : ordered[index - 1])
        }
        updateTabWidths(animated: lockedTabWidth == nil)
        itemsStack.needsLayout = true
        needsLayout = true
    }

    private func updateTabWidths(animated: Bool) {
        let items = itemsStack.arrangedSubviews.compactMap { $0 as? CorralTabItemView }
        guard !items.isEmpty else { itemsStack.setFrameSize(NSSize(width: 0, height: 28)); return }
        let regularItems = items.filter { !$0.tab.isPinned }
        let pinnedCount = items.count - regularItems.count
        let fixedChromeWidth = itemsLeadingConstraint.constant + 8 + 26 + 8
        let availableForItems = max(0, bounds.width - fixedChromeWidth)
        let gaps = CGFloat(max(0, items.count - 1)) * itemsStack.spacing
        let regularBudget = availableForItems - CGFloat(pinnedCount) * CorralTabItemView.pinnedWidth - gaps
        let naturalWidth = regularItems.isEmpty ? CorralTabItemView.maximumRegularWidth : regularBudget / CGFloat(regularItems.count)
        let adaptiveWidth = min(CorralTabItemView.maximumRegularWidth, max(CorralTabItemView.minimumRegularWidth, naturalWidth))
        let requestedWidth = lockedTabWidth.map {
            min(CorralTabItemView.maximumRegularWidth, max(CorralTabItemView.minimumRegularWidth, $0))
        } ?? adaptiveWidth
        let backingScale = max(window?.backingScaleFactor ?? 1, 1)
        let regularWidth = floor(requestedWidth * backingScale) / backingScale

        for item in items {
            item.setWidth(item.tab.isPinned ? CorralTabItemView.pinnedWidth : regularWidth, animated: animated && lockedTabWidth == nil)
        }
        let documentSize = NSSize(width: itemsStack.fittingSize.width, height: 28)
        if abs(itemsStack.frame.width - documentSize.width) > 0.25 {
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                    context.allowsImplicitAnimation = true
                    itemsStack.animator().setFrameSize(documentSize)
                }
            } else {
                itemsStack.setFrameSize(documentSize)
            }
        }
        itemsStack.needsLayout = true
    }

    public override func layout() {
        super.layout()
        updateTabWidths(animated: false)
        itemsStack.layoutSubtreeIfNeeded()
        if revealSelectedTab, let item = itemsStack.arrangedSubviews.first(where: { ($0 as? CorralTabItemView)?.tab.id == selectedTabID }) {
            item.scrollToVisible(item.bounds)
            revealSelectedTab = false
        }
        guard let selectedTabID, let item = itemsStack.arrangedSubviews.compactMap({ $0 as? CorralTabItemView }).first(where: { $0.tab.id == selectedTabID }), !item.tab.isPinned else {
            activeCapsule.isHidden = true
            activeCapsuleFrame = nil
            capsuleSelectionAnimationPending = false
            return
        }
        let targetFrame = item.frame
        let canSlide = capsuleSelectionAnimationPending && activeCapsuleFrame != nil && !activeCapsule.isHidden
        if canSlide {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.89, 0.32, 1.12)
                context.allowsImplicitAnimation = true
                activeCapsule.animator().frame = targetFrame
                activeCapsule.animator().alphaValue = 1
            }
        } else if capsuleSelectionAnimationPending {
            activeCapsule.frame = targetFrame
            activeCapsule.alphaValue = 0
            activeCapsule.isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                activeCapsule.animator().alphaValue = 1
            }
        } else {
            activeCapsule.frame = targetFrame
            activeCapsule.alphaValue = 1
            activeCapsule.isHidden = false
        }
        activeCapsuleFrame = targetFrame
        capsuleSelectionAnimationPending = false
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
        renderedItems.removeAll()
        setTabs(tabs, selectedTabID: selectedTabID)
    }
    public func rename(_ tabID: UUID) {
        (itemsStack.arrangedSubviews.first { ($0 as? CorralTabItemView)?.tab.id == tabID } as? CorralTabItemView)?.beginRename()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        isMouseInsideTabBar = true
    }

    public override func mouseExited(with event: NSEvent) {
        guard let window else {
            isMouseInsideTabBar = false
            guard lockedTabWidth != nil else { return }
            lockedTabWidth = nil
            updateTabWidths(animated: true)
            return
        }
        let eventLocation = convert(event.locationInWindow, from: nil)
        let pointerLocation = event.window === window
            ? eventLocation
            : convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard !bounds.contains(pointerLocation) else {
            isMouseInsideTabBar = true
            return
        }
        isMouseInsideTabBar = false
        guard lockedTabWidth != nil else { return }
        lockedTabWidth = nil
        updateTabWidths(animated: true)
    }

    fileprivate func select(_ id: UUID) { onSelectTab?(id) }
    fileprivate func close(_ id: UUID) { onCloseTab?(id) }
    fileprivate func closeFromButton(_ id: UUID, currentWidth: CGFloat) {
        if tabs.filter({ !$0.isPinned }).count > 1, tabs.first(where: { $0.id == id })?.isPinned == false {
            // A close-button activation proves the pointer is in the tab bar even if
            // AppKit has not delivered the tracking-area enter event yet.
            isMouseInsideTabBar = true
            let width = lockedTabWidth ?? currentWidth
            if width > 0 {
                lockedTabWidth = width
                updateTabWidths(animated: false)
            }
        }
        onCloseTab?(id)
    }
    fileprivate func commitRename(_ id: UUID, _ title: String) { onRenameTab?(id, title) }
    fileprivate func performContextAction(_ id: UUID, _ action: String) { onContextAction?(id, action) }
    @objc private func toggleSidebar() { onToggleSidebar?() }
    @objc private func createTab() { onCreateTab?() }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .move }
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let value = sender.draggingPasteboard.string(forType: .string), let id = UUID(uuidString: value),
              let sourceIndex = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let x = itemsStack.convert(sender.draggingLocation, from: nil).x
        let target = itemsStack.arrangedSubviews.compactMap { $0 as? CorralTabItemView }.first { x < $0.frame.midX }
        let targetIndex = target.flatMap { item in tabs.firstIndex(where: { $0.id == item.tab.id }) } ?? tabs.count
        let adjusted = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        onReorderTabs?(id, max(0, adjusted))
        return true
    }
}

@MainActor
private final class CorralTabItemView: NSView, NSTextFieldDelegate, NSDraggingSource {
    fileprivate static let minimumRegularWidth: CGFloat = 44
    fileprivate static let maximumRegularWidth: CGFloat = 160
    fileprivate static let pinnedWidth: CGFloat = 32
    private var widthConstraint: NSLayoutConstraint!
    private var minimumWidthConstraint: NSLayoutConstraint!
    var tab: CorralTab
    private weak var owner: CorralTabBarView?
    private let status = CorralStatusIndicatorView()
    private let title = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private var providerIconView: NSImageView?
    private var statusLeadingConstraint: NSLayoutConstraint?
    private var regularProviderLeadingConstraint: NSLayoutConstraint?
    private var titleLeadingConstraint: NSLayoutConstraint?
    private var compactTitleLeadingConstraint: NSLayoutConstraint?
    private var titleTrailingConstraint: NSLayoutConstraint?
    private var compactTitleTrailingConstraint: NSLayoutConstraint?
    private var closeTrailingConstraint: NSLayoutConstraint?
    private var isCompact = false
    private var isMinimal = false
    private var pendingExpansionWidth: CGFloat?
    private var selected: Bool
    private var hovered = false
    private var editField: CorralInlineRenameField?
    private var dragStart: NSPoint?
    private var pressTime: TimeInterval = 0
    private var didStartDrag = false

    init(tab: CorralTab, selected: Bool, owner: CorralTabBarView) {
        self.tab = tab
        self.owner = owner
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        setContentCompressionResistancePriority(.required, for: .horizontal)
        status.fillsIdle = true
        status.status = tab.status
        status.translatesAutoresizingMaskIntoConstraints = false
        title.stringValue = tab.title
        title.toolTip = tab.title
        title.font = .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setAccessibilityIdentifier("corral.tab.title")
        title.setAccessibilityLabel(tab.title)
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(status)
        addSubview(title)
        let providerIcon: NSImageView
        if let provider = tab.provider {
            providerIcon = CorralProviderIconView(provider: provider, size: 15, active: tab.status == .working || tab.status == .blocked)
        } else {
            providerIcon = NSImageView()
            providerIcon.translatesAutoresizingMaskIntoConstraints = false
            providerIcon.image = CorralLegacyIcon.image(.terminal, size: 15)
            providerIcon.contentTintColor = CorralAestheticTokens.textMuted
            providerIcon.setAccessibilityLabel("终端")
            NSLayoutConstraint.activate([
                providerIcon.widthAnchor.constraint(equalToConstant: 15),
                providerIcon.heightAnchor.constraint(equalToConstant: 15)
            ])
        }
        addSubview(providerIcon)
        providerIconView = providerIcon
        closeButton.image = CorralLegacyIcon.image(.close, size: 10, tint: CorralAestheticTokens.textMuted)
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.contentTintColor = CorralAestheticTokens.textMuted
        closeButton.toolTip = "关闭工作台"
        closeButton.setAccessibilityLabel("关闭工作台"); closeButton.setAccessibilityIdentifier("corral.tab.close")
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        let showsCloseButton = !tab.isPinned
        title.isHidden = tab.isPinned
        if showsCloseButton { addSubview(closeButton) }
        let initialWidth = tab.isPinned ? Self.pinnedWidth : Self.maximumRegularWidth
        widthConstraint = widthAnchor.constraint(equalToConstant: initialWidth)
        minimumWidthConstraint = widthAnchor.constraint(greaterThanOrEqualToConstant: tab.isPinned ? Self.pinnedWidth : Self.minimumRegularWidth)
        NSLayoutConstraint.activate([widthConstraint, minimumWidthConstraint])
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        NSLayoutConstraint.activate([
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.widthAnchor.constraint(equalToConstant: 6),
            status.heightAnchor.constraint(equalToConstant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        let statusLeading = status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: tab.isPinned ? 3 : 8)
        statusLeadingConstraint = statusLeading
        let providerLeading = providerIcon.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: tab.isPinned ? 3 : 6)
        regularProviderLeadingConstraint = providerLeading
        providerIcon.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        if tab.isPinned {
            NSLayoutConstraint.activate([statusLeading, providerLeading])
        } else {
            let titleLeading = title.leadingAnchor.constraint(equalTo: providerIcon.trailingAnchor, constant: 5)
            let compactTitleLeading = title.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 3)
            let titleTrailing = title.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6)
            let compactTitleTrailing = title.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -3)
            let closeTrailing = closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
            titleLeadingConstraint = titleLeading
            compactTitleLeadingConstraint = compactTitleLeading
            titleTrailingConstraint = titleTrailing
            compactTitleTrailingConstraint = compactTitleTrailing
            closeTrailingConstraint = closeTrailing
            NSLayoutConstraint.activate([
                statusLeading, providerLeading, titleLeading, titleTrailing, closeTrailing,
                closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                closeButton.widthAnchor.constraint(equalToConstant: 18),
                closeButton.heightAnchor.constraint(equalToConstant: 18)
            ])
        }
        if !showsCloseButton {
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8).isActive = true
        }
        toolTip = tab.title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tab.title)
        setAccessibilityIdentifier("corral.tab")
        updateSelectionAppearance()
        registerForDraggedTypes([.string])
    }
    func setWidth(_ width: CGFloat, animated: Bool) {
        let compact = !tab.isPinned && width < 96
        let minimal = !tab.isPinned && width < 60
        if let pendingExpansionWidth, abs(pendingExpansionWidth - width) <= 0.25 {
            // Keep compact contents clipped/hidden until the width animation finishes.
        } else if animated, isCompact, !compact {
            pendingExpansionWidth = width
        } else {
            pendingExpansionWidth = nil
            setCompactMode(compact, minimal: minimal)
        }
        guard abs(widthConstraint.constant - width) > 0.25 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                context.allowsImplicitAnimation = true
                widthConstraint.animator().constant = width
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, let pending = self.pendingExpansionWidth,
                          abs(pending - width) <= 0.25 else { return }
                    self.pendingExpansionWidth = nil
                    self.setCompactMode(compact, minimal: minimal)
                    self.layoutSubtreeIfNeeded()
                }
            })
        } else {
            widthConstraint.constant = width
        }
    }

    private func setCompactMode(_ compact: Bool, minimal: Bool) {
        guard !tab.isPinned, isCompact != compact || isMinimal != minimal,
              let providerLeading = regularProviderLeadingConstraint,
              let titleLeading = titleLeadingConstraint,
              let compactTitleLeading = compactTitleLeadingConstraint,
              let titleTrailing = titleTrailingConstraint,
              let compactTitleTrailing = compactTitleTrailingConstraint else { return }
        isCompact = compact
        isMinimal = minimal
        providerIconView?.isHidden = compact
        title.isHidden = minimal
        statusLeadingConstraint?.constant = compact ? 3 : 8
        closeTrailingConstraint?.constant = compact ? -4 : -6
        if compact {
            NSLayoutConstraint.deactivate([providerLeading, titleLeading, titleTrailing])
            NSLayoutConstraint.activate([compactTitleLeading, compactTitleTrailing])
        } else {
            NSLayoutConstraint.deactivate([compactTitleLeading, compactTitleTrailing])
            NSLayoutConstraint.activate([providerLeading, titleLeading, titleTrailing])
        }
    }

    func setSelected(_ selected: Bool) {
        guard self.selected != selected else { return }
        self.selected = selected
        updateSelectionAppearance()
    }
    private func updateSelectionAppearance() {
        let pinnedSelection = selected && tab.isPinned
        layer?.backgroundColor = (pinnedSelection ? CorralAestheticTokens.tabActiveBackground : (!selected && hovered ? CorralAestheticTokens.hover : NSColor.clear)).cgColor
        layer?.borderColor = (pinnedSelection ? CorralAestheticTokens.tabActiveBorder : NSColor.clear).cgColor
        layer?.borderWidth = pinnedSelection ? 1 : 0
        title.textColor = selected || hovered ? CorralAestheticTokens.text : CorralAestheticTokens.textSecondary
        closeButton.alphaValue = selected || hovered ? 0.7 : 0
        setAccessibilitySelected(selected)
    }
    override func accessibilityPerformPress() -> Bool { owner?.select(tab.id); return true }
    override func accessibilityPerformShowMenu() -> Bool { makeContextMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self); return true }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { CorralAccessibilityMenuActions.actions(for: makeContextMenu()) }

    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { beginRename(); return }
        dragStart = convert(event.locationInWindow, from: nil)
        pressTime = event.timestamp
        didStartDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard event.timestamp - pressTime >= 0.18,
              hypot(point.x - dragStart.x, point.y - dragStart.y) > 6 else { return }
        didStartDrag = true
        let writer = NSPasteboardItem()
        writer.setString(tab.id.uuidString, forType: .string)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        (tab.title as NSString).draw(at: NSPoint(x: 6, y: 6), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: CorralAestheticTokens.text])
        image.unlockFocus()
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard dragStart != nil, !didStartDrag,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        owner?.select(tab.id)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateSelectionAppearance()
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateSelectionAppearance()
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
        case "splitRight", "splitDown": .split
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
    @objc private func closeTab() { owner?.closeFromButton(tab.id, currentWidth: bounds.width) }
    @objc private func renameFromMenu() { beginRename() }
    @objc private func togglePin() { owner?.performContextAction(tab.id, "pin") }
    func beginRename() {
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
    private func removeEditor() {
        editField?.removeFromSuperview()
        editField = nil
        title.stringValue = tab.title
        title.toolTip = tab.title
        title.setAccessibilityLabel(tab.title)
        toolTip = tab.title
        setAccessibilityLabel(tab.title)
        title.isHidden = false
    }
}

public enum CorralSidebarSpaceKind: String, Sendable { case allSpaces, favorites, workspace }

@MainActor
public struct CorralSidebarSpace: Identifiable, Sendable, Equatable {
    public static let allSpacesID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let favoritesID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    public let id: UUID
    public var name: String
    public var workingCount: Int
    public var agentCount: Int
    public var kind: CorralSidebarSpaceKind
    public var isVirtual: Bool { kind != .workspace }
    public var isBranchWorkspace: Bool {
        name.lowercased().split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains {
            $0 == "branch" || $0 == "feature" || $0.hasPrefix("branch-") || $0.hasPrefix("feature-")
        }
    }
    public init(id: UUID = UUID(), name: String, workingCount: Int = 0, agentCount: Int = 0, isVirtual: Bool = false, kind: CorralSidebarSpaceKind = .workspace) {
        self.id = id; self.name = name; self.workingCount = workingCount; self.agentCount = agentCount
        self.kind = isVirtual ? (name == "收藏" ? .favorites : .allSpaces) : kind
    }
}

@MainActor
public struct CorralSidebarAgent: Identifiable, Sendable, Equatable {
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
    /// The real device-scoped session this row drags onto the stage.
    public var sessionID: SessionID?
    public init(id: UUID = UUID(), name: String, status: CorralStatusIndicatorView.Status = .idle, provider: String? = nil, deviceName: String? = nil, spaceID: UUID? = nil, isFavorite: Bool = false, isOpen: Bool = false, isActive: Bool = false, isClosing: Bool = false, sessionID: SessionID? = nil) {
        self.id = id; self.name = name; self.status = status; self.provider = provider; self.deviceName = deviceName; self.spaceID = spaceID; self.isFavorite = isFavorite; self.isOpen = isOpen; self.isActive = isActive; self.isClosing = isClosing; self.sessionID = sessionID
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

/// Sidebar row content: an AX button whose completed click or accessibility press opens/selects the row.
@MainActor
class CorralSidebarCellView: NSTableCellView {
    var onPress: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    override func accessibilityPerformPress() -> Bool { performPress() }
    private func performPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
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
    var backgroundRadius: CGFloat { isAgentRow ? 6 : 7 }
    var fillColor: NSColor? {
        if isSelected || isActive { return CorralAestheticTokens.selectionBackground }
        if isHovered { return isAgentRow ? (isOpen ? CorralAestheticTokens.hover : CorralAestheticTokens.hoverSubtle) : CorralAestheticTokens.hover }
        return isOpen ? CorralAestheticTokens.fillSubtle : nil
    }
    override func drawBackground(in dirtyRect: NSRect) {
        guard let color = fillColor else { return }
        color.setFill()
        NSBezierPath(roundedRect: backgroundRect, xRadius: backgroundRadius, yRadius: backgroundRadius).fill()
    }
    func animateFavoritePin() {
        wantsLayer = true
        guard let layer else { return }
        let pulse = CALayer()
        pulse.frame = backgroundRect
        pulse.cornerRadius = backgroundRadius
        pulse.backgroundColor = CorralAestheticTokens.warning.withAlphaComponent(0.2).cgColor
        pulse.opacity = 0
        layer.insertSublayer(pulse, at: 0)
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 0.55, 0]
        animation.keyTimes = [0, 0.2, 1]
        animation.duration = 0.38
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        pulse.add(animation, forKey: "favorite-pin-highlight")
        DispatchQueue.main.asyncAfter(deadline: .now() + animation.duration + 0.03) { [weak pulse] in
            pulse?.removeFromSuperlayer()
        }
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
final class CorralAgentTableView: NSTableView {
    var sessionIDForRow: ((Int) -> SessionID?)?
    var onAgentClick: ((SessionID, SessionOpenGesture) -> Void)?
    private var pressedSessionID: SessionID?
    private var pressedGesture: SessionOpenGesture = .singleClick
    private var pressEvent: NSEvent?
    private var didDrag = false
    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        pressedSessionID = row >= 0 ? sessionIDForRow?(row) : nil
        pressedGesture = event.clickCount >= 2 ? .doubleClick : .singleClick
        pressEvent = event
        didDrag = false
        dragging = false
        // Agent rows have coordinator-owned selection. NSTableView's nested drag tracking
        // consumes mouse-up; let this one gesture owner dispatch both clicks and drags.
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressEvent, let sessionID = pressedSessionID, !dragging else { return }
        let origin = pressEvent.locationInWindow, point = event.locationInWindow
        guard hypot(point.x - origin.x, point.y - origin.y) > 4 else { return }
        didDrag = true
        guard event.timestamp - pressEvent.timestamp >= 0.18 else { return }
        dragging = true
        let writer = NSPasteboardItem()
        writer.setString(sessionID.rawValue, forType: CorralWorkspaceStageView.sessionPasteboardType)
        let row = self.row(at: convert(origin, from: nil))
        let rect = rect(ofRow: row)
        let image = NSImage(size: rect.size)
        if let bitmap = bitmapImageRepForCachingDisplay(in: rect) {
            cacheDisplay(in: rect, to: bitmap)
            image.addRepresentation(bitmap)
        }
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(rect, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    override func mouseUp(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        let releasedSessionID = row >= 0 ? sessionIDForRow?(row) : nil
        let downSessionID = pressedSessionID
        let gesture = pressedGesture
        let wasDragged = didDrag
        pressedSessionID = nil
        pressEvent = nil
        pressedGesture = .singleClick
        didDrag = false
        dragging = false
        dispatchClickIfCompleted(from: downSessionID, to: releasedSessionID, wasDragged: wasDragged, gesture: gesture)
    }

    func dispatchClickIfCompleted(from pressedSessionID: SessionID?, to releasedSessionID: SessionID?, wasDragged: Bool, gesture: SessionOpenGesture = .singleClick) {
        guard !wasDragged, let pressedSessionID, pressedSessionID == releasedSessionID else { return }
        onAgentClick?(pressedSessionID, gesture)
    }
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
            cell.onPress = { [weak self] in self?.sidebar?.handleAgentAccessibilityPress(id: agent.id) }
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
            let iconName: CorralLegacyIcon = switch space.kind { case .allSpaces: .grid; case .favorites: .star; case .workspace: space.isBranchWorkspace ? .gitBranch : .folder }
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
        // Agent active/highlight state is coordinator-owned; row clicks only emit an intent after mouse-up.
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { kind == .spaces }
    func agentClicked(sessionID: SessionID, gesture: SessionOpenGesture) { sidebar?.handleAgentRowClick(sessionID: sessionID, gesture: gesture) }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard kind == .agents, agents.indices.contains(row), let sessionID = agents[row].sessionID else { return nil }
        let item = NSPasteboardItem()
        item.setString(sessionID.rawValue, forType: CorralWorkspaceStageView.sessionPasteboardType)
        return item
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
    public let agentsTable: NSTableView = CorralAgentTableView()
    public let deviceBadgeView = CorralDeviceBadgeView()
    public let devicesButton = NSButton(title: "设备", target: nil, action: nil)
    public let settingsButton = CorralSettingsButton()
    public var onSettings: (() -> Void)?
    public var onCreateAgent: ((UUID?) -> Void)?
    public var onCreateSpace: (() -> Void)?
    public var onSelectSpace: ((UUID) -> Void)?
    public var onSelectAgent: ((SessionID, SessionOpenGesture) -> Void)?
    public var onToggleFavorite: ((UUID, Bool) -> Void)?
    public var onRenameAgent: ((UUID) -> Void)?
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
    private let footerBorder = NSView()
    private var spacesHeight: NSLayoutConstraint!
    private var agentsHeight: NSLayoutConstraint!
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
        // The host card shares the footer with the fixed-size settings target.
        let footer = NSView()
        footerBorder.wantsLayer = true; footerBorder.layer?.backgroundColor = CorralAestheticTokens.border.cgColor; footerBorder.translatesAutoresizingMaskIntoConstraints = false
        devicesButton.title = "查看所有主机"
        devicesButton.target = self; devicesButton.action = #selector(toggleDevices); devicesButton.image = CorralLegacyIcon.image(.layers, size: 15, tint: CorralAestheticTokens.text); devicesButton.imagePosition = .imageLeading; devicesButton.imageHugsTitle = true
        devicesButton.font = .systemFont(ofSize: 13, weight: .semibold); devicesButton.isBordered = false; devicesButton.contentTintColor = CorralAestheticTokens.text; devicesButton.setAccessibilityLabel("查看所有主机"); devicesButton.setAccessibilityIdentifier("corral.sidebar.devices"); devicesButton.wantsLayer = true; devicesButton.layer?.backgroundColor = CorralAestheticTokens.surface1.cgColor; devicesButton.layer?.cornerRadius = 8; devicesButton.layer?.borderWidth = 1; devicesButton.layer?.borderColor = CorralAestheticTokens.borderSubtle.cgColor; devicesButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.setAccessibilityIdentifier("corral.sidebar.settings")
        settingsButton.target = self; settingsButton.action = #selector(openSettings); settingsButton.translatesAutoresizingMaskIntoConstraints = false
        for view in [footerBorder, devicesButton, settingsButton] { footer.addSubview(view) }
        NSLayoutConstraint.activate([
            footerBorder.leadingAnchor.constraint(equalTo: footer.leadingAnchor), footerBorder.trailingAnchor.constraint(equalTo: footer.trailingAnchor), footerBorder.topAnchor.constraint(equalTo: footer.topAnchor), footerBorder.heightAnchor.constraint(equalToConstant: 1),
            devicesButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12), devicesButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor), devicesButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -4), devicesButton.heightAnchor.constraint(equalToConstant: 35),
            settingsButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -8), settingsButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor), settingsButton.widthAnchor.constraint(equalToConstant: 34), settingsButton.heightAnchor.constraint(equalToConstant: 35)
        ])
        let spacer = NSView()
        let stack = NSStackView(views: [spacesHeader, spacesScroll, agentsHeader, agentsScroll, spacer, footer])
        stack.orientation = .vertical; stack.alignment = .width; stack.distribution = .fill; stack.spacing = 0; stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setClippingResistancePriority(.defaultLow, for: .vertical)
        addSubview(stack)
        spacesHeight = spacesScroll.heightAnchor.constraint(equalToConstant: 0)
        agentsHeight = agentsScroll.heightAnchor.constraint(equalToConstant: 0)
        let spacerFill = spacer.heightAnchor.constraint(equalToConstant: 10_000)
        spacerFill.priority = .defaultLow
        NSLayoutConstraint.activate([
            footer.widthAnchor.constraint(equalTo: widthAnchor),
            spacesHeader.heightAnchor.constraint(equalToConstant: CorralSidebarSectionHeader.height), agentsHeader.heightAnchor.constraint(equalToConstant: CorralSidebarSectionHeader.height),
            spacesHeight, agentsHeight, spacerFill, footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setSpaces([])
        setDevices([])
    }

    public override func layout() {
        updateScrollHeights()
        super.layout()
        sizeDocumentView(spacesTable, in: spacesScroll)
        sizeDocumentView(agentsTable, in: agentsScroll)
    }
    private func updateScrollHeights() {
        let available = max(0, bounds.height - 2 * CorralSidebarSectionHeader.height - Self.footerHeight)
        let minimumAgentsSpace = agentsExpanded ? min(2 * Self.agentRowHeight, available) : 0
        let spacesLimit = max(0, available - minimumAgentsSpace)
        let spacesContentHeight = CGFloat(spaces.count) * Self.spaceRowHeight
        let spacesHeightValue = spacesExpanded ? min(spacesContentHeight, Self.spacesMaximumHeight, spacesLimit) : 0
        let agentsHeightValue = agentsExpanded ? max(0, available - spacesHeightValue) : 0
        if spacesHeight.constant != spacesHeightValue { spacesHeight.constant = spacesHeightValue }
        if agentsHeight.constant != agentsHeightValue { agentsHeight.constant = agentsHeightValue }
    }
    public required init?(coder: NSCoder) { fatalError("CorralSidebarView is created programmatically") }
    public convenience init(devices: [CorralSidebarDevice]) { self.init(frame: .zero); setDevices(devices) }
    public func setSpaces(_ spaces: [CorralSidebarSpace]) {
        let previous = self.spaces
        let workspaces = spaces.filter { $0.kind == .workspace && !$0.isVirtual }
        self.spaces = [
            CorralSidebarSpace(id: CorralSidebarSpace.allSpacesID, name: "All Spaces", kind: .allSpaces),
            CorralSidebarSpace(id: CorralSidebarSpace.favoritesID, name: "收藏", kind: .favorites)
        ] + workspaces
        applyAgentCounts()
        guard self.spaces != previous else { return }
        spaceData.spaces = self.spaces
        let selectionWasRemoved = !self.spaces.contains { $0.id == selectedSpaceID }
        if selectionWasRemoved { selectedSpaceID = CorralSidebarSpace.allSpacesID }
        spacesTable.reloadData()
        updateScrollHeights()
        if let index = self.spaces.firstIndex(where: { $0.id == selectedSpaceID }) { spacesTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        refreshVisibleAgents()
        updateSectionHeaders()
        if selectionWasRemoved { onSelectSpace?(selectedSpaceID) }
    }
    public func agentContextMenu(for id: UUID) -> NSMenu? {
        guard let agent = agents.first(where: { $0.id == id }) else { return nil }
        let controller = SessionContextMenuBuilder.makeMenu(for: agent.id, isFavorite: agent.isFavorite,
            onFavorite: { [weak self] id, value in self?.onToggleFavorite?(id, value) },
            onClose: { [weak self] id in self?.onCloseAgent?(id) },
            onRename: { [weak self] id in self?.onRenameAgent?(id) })
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
    func handleAgentRowClick(sessionID: SessionID, gesture: SessionOpenGesture) {
        onSelectAgent?(sessionID, gesture)
    }
    func handleAgentAccessibilityPress(id: UUID) {
        guard let sessionID = agents.first(where: { $0.id == id })?.sessionID else { return }
        onSelectAgent?(sessionID, .singleClick)
    }
    fileprivate func selectSpace(_ space: CorralSidebarSpace) {
        let row = spaces.firstIndex { $0.id == space.id }
        if selectedSpaceID == space.id {
            if let row, spacesTable.selectedRow != row {
                spacesTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                spacesTable.scrollRowToVisible(row)
            }
            return
        }
        selectedSpaceID = space.id
        if let row {
            spacesTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            spacesTable.scrollRowToVisible(row)
        }
        spacesTable.reloadData(forRowIndexes: IndexSet(integersIn: 0..<spacesTable.numberOfRows), columnIndexes: IndexSet(integer: 0))
        refreshVisibleAgents(); updateSectionHeaders()
        onSelectSpace?(space.id)
    }
    public func setAgents(_ agents: [CorralSidebarAgent]) {
        guard allAgents != agents else { return }
        allAgents = agents
        refreshVisibleAgents(); updateSpaceCounts(); updateSectionHeaders()
    }
    public func setSpacesExpanded(_ expanded: Bool) {
        spacesExpanded = expanded
        updateScrollHeights()
        updateSectionHeaders()
    }
    public func selectSpace(id: UUID) {
        guard let space = spaces.first(where: { $0.id == id }) else { return }
        selectSpace(space)
    }
    public func setAgentsExpanded(_ expanded: Bool) {
        agentsExpanded = expanded
        updateScrollHeights()
        updateSectionHeaders()
    }
    public func clearSelectedSession() { agentsTable.deselectAll(nil) }
    @discardableResult
    public func selectSession(id: SessionID) -> Bool {
        guard let agent = allAgents.first(where: { $0.sessionID == id }) else { return false }
        setSpacesExpanded(true)
        setAgentsExpanded(true)
        let spaceID = agent.spaceID.flatMap { id in
            spaces.contains { $0.id == id && $0.kind == .workspace } ? id : nil
        } ?? CorralSidebarSpace.allSpacesID
        selectSpace(id: spaceID)
        guard let row = agents.firstIndex(where: { $0.sessionID == id }) else { return false }
        agentsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        agentsTable.scrollRowToVisible(row)
        return true
    }
    public func refreshTheme() {
        layer?.backgroundColor = CorralAestheticTokens.surface0.cgColor
        spacesTable.backgroundColor = CorralAestheticTokens.surface0
        agentsTable.backgroundColor = CorralAestheticTokens.surface0
        footerBorder.layer?.backgroundColor = CorralAestheticTokens.border.cgColor
        devicesButton.image = CorralLegacyIcon.image(.layers, size: 15, tint: CorralAestheticTokens.text)
        devicesButton.layer?.backgroundColor = CorralAestheticTokens.surface1.cgColor
        devicesButton.layer?.borderColor = CorralAestheticTokens.borderSubtle.cgColor
        spacesHeader.refreshTheme(); agentsHeader.refreshTheme()
        settingsButton.refreshTheme()
        spacesTable.reloadData(forRowIndexes: IndexSet(integersIn: 0..<spaces.count), columnIndexes: IndexSet(integer: 0)); agentsTable.reloadData()
        updateSectionHeaders()
    }
    public func setDevices(_ devices: [CorralSidebarDevice]) {
        setDeviceMetadata(devices)
        let sessions = devices.flatMap { device in device.sessions.map { CorralSidebarAgent(id: $0.id, name: $0.name, status: .idle, deviceName: device.name) } }
        setAgents(sessions)
    }
    /// The coordinator supplies full agent identities separately; device metadata must not replace them.
    public func setDeviceMetadata(_ devices: [CorralSidebarDevice]) {
        let countChanged = self.devices.count != devices.count
        self.devices = devices
        deviceBadgeView.configure(deviceName: devices.first?.name ?? "", deviceCount: devices.count)
        if countChanged { agentsTable.reloadData() }
    }
    private func refreshVisibleAgents() {
        let selectedKind = spaces.first(where: { $0.id == selectedSpaceID })?.kind ?? .allSpaces
        let visible: [CorralSidebarAgent] = switch selectedKind {
        case .allSpaces: allAgents
        case .favorites: allAgents.filter(\.isFavorite)
        case .workspace: allAgents.filter { $0.spaceID == selectedSpaceID }
        }
        let updated = visible.enumerated().sorted { lhs, rhs in
            if lhs.element.isFavorite != rhs.element.isFavorite { return lhs.element.isFavorite }
            return lhs.offset < rhs.offset
        }.map(\.element)
        guard updated != agents else { return }
        let previous = agents
        agents = updated
        agentData.agents = agents
        agentsTable.deselectAll(nil)
        let previousIDs = previous.map(\.id)
        let updatedIDs = agents.map(\.id)
        if previousIDs != updatedIDs {
            if previousIDs.count == updatedIDs.count, Set(previousIDs) == Set(updatedIDs) {
                let previouslyFavorited = Set(previous.filter(\.isFavorite).map(\.id))
                let newlyFavorited = Set(agents.filter(\.isFavorite).map(\.id)).subtracting(previouslyFavorited)
                animateAgentReorder(from: previous, to: agents, highlighting: newlyFavorited)
            } else {
                agentsTable.reloadData()
            }
        } else {
            let changed = IndexSet(agents.indices.filter { previous[$0] != agents[$0] })
            agentsTable.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
            for index in changed {
                if let row = agentsTable.rowView(atRow: index, makeIfNecessary: false) as? CorralSidebarRowView {
                    row.isOpen = agents[index].isOpen
                    row.isActive = agents[index].isActive
                    row.needsDisplay = true
                }
            }
        }
    }
    private func animateAgentReorder(from previous: [CorralSidebarAgent], to updated: [CorralSidebarAgent], highlighting favoriteIDs: Set<UUID>) {
        let oldIDs = previous.map(\.id)
        let newIDs = updated.map(\.id)
        var order = oldIDs
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.38
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            context.allowsImplicitAnimation = true
            agentsTable.beginUpdates()
            for (destination, id) in newIDs.enumerated() {
                guard let source = order.firstIndex(of: id), source != destination else { continue }
                agentsTable.moveRow(at: source, to: destination)
                order.insert(order.remove(at: source), at: destination)
            }
            agentsTable.endUpdates()
        }
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let updatedByID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        let changedIDs = Set(updated.compactMap { previousByID[$0.id] != $0 ? $0.id : nil })
        let changedRows = IndexSet(newIDs.enumerated().compactMap { changedIDs.contains($0.element) ? $0.offset : nil })
        if !changedRows.isEmpty {
            agentsTable.reloadData(forRowIndexes: changedRows, columnIndexes: IndexSet(integer: 0))
        }
        agentsTable.layoutSubtreeIfNeeded()
        for id in favoriteIDs {
            guard let rowIndex = agents.firstIndex(where: { $0.id == id }),
                  let row = agentsTable.rowView(atRow: rowIndex, makeIfNecessary: true) as? CorralSidebarRowView else { continue }
            row.isOpen = updatedByID[id]?.isOpen ?? row.isOpen
            row.isActive = updatedByID[id]?.isActive ?? row.isActive
            row.animateFavoritePin()
        }
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
        let previous = spaces
        applyAgentCounts()
        let changed = IndexSet(spaces.indices.filter { previous[$0] != spaces[$0] })
        guard !changed.isEmpty else { return }
        spaceData.spaces = spaces
        spacesTable.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
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
        if data.kind == .agents, let agentTable = table as? CorralAgentTableView {
            table.setDraggingSourceOperationMask(.move, forLocal: true)
            agentTable.sessionIDForRow = { [weak data] row in
                guard let data, data.agents.indices.contains(row) else { return nil }
                return data.agents[row].sessionID
            }
            agentTable.onAgentClick = { [weak data] sessionID, gesture in data?.agentClicked(sessionID: sessionID, gesture: gesture) }
        }
    }
    private func configureScroll(_ scroll: NSScrollView, table: NSTableView) {
        table.autoresizingMask = [.width]
        scroll.documentView = table; scroll.drawsBackground = false; scroll.hasVerticalScroller = false; scroll.autohidesScrollers = true; scroll.borderType = .noBorder; scroll.translatesAutoresizingMaskIntoConstraints = false
    }
    private func sizeDocumentView(_ table: NSTableView, in scroll: NSScrollView) {
        let rowsHeight = CGFloat(table.numberOfRows) * (table === spacesTable ? Self.spaceRowHeight : Self.agentRowHeight)
        let size = NSSize(width: max(1, scroll.contentSize.width), height: max(scroll.contentSize.height, rowsHeight))
        if table.frame.size != size { table.setFrameSize(size) }
    }
    @objc private func toggleDevices() { onToggleDevices?() }
    @objc private func openSettings() { onSettings?() }
}

/// Legacy `.dropzone-overlay`: the exact slot the dropped pane will occupy.
@MainActor
public final class SplitDropZoneView: NSView {
    public typealias Edge = WorkspaceDropZone
    public var edge: Edge = .center
    public override func draw(_ dirtyRect: NSRect) {
        let blue = NSColor(srgbRed: 59 / 255, green: 130 / 255, blue: 246 / 255, alpha: 1)
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 6, yRadius: 6)
        blue.withAlphaComponent(0.08).setFill(); outline.fill()
        blue.withAlphaComponent(0.85).setStroke(); outline.lineWidth = 1.5; outline.stroke()
    }
}

@MainActor
public final class CorralWorkspaceStageView: NSView {
    /// Sidebar Agent rows drag their real device-scoped `SessionID` under this type.
    public static let sessionPasteboardType = NSPasteboard.PasteboardType("com.corral.native.session")
    public var onDropSession: ((SessionID, SessionID?, SplitDropZoneView.Edge) -> Void)?
    public var onDropTab: ((UUID, SessionID?, SplitDropZoneView.Edge) -> Void)?
    public var activeTabID: UUID?
    public let splitView = SplitWorkspaceView()
    public let dropZone = SplitDropZoneView()
    public private(set) var dropTarget: SplitLayout.DropTarget?
    public private(set) var emptyStateLabel: NSTextField?
    public var onCreateAgent: (() -> Void)?
    private var emptyActionButton: NSButton?
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); registerForDraggedTypes([Self.sessionPasteboardType, .string])
        addSubview(splitView); dropZone.isHidden = true; addSubview(dropZone)
        wantsLayer = true; layer?.backgroundColor = CorralAestheticTokens.background.cgColor
    }
    public required init?(coder: NSCoder) { fatalError("CorralWorkspaceStageView is created programmatically") }
    public override func layout() { super.layout(); splitView.frame = bounds }
    /// Tab content (and the Metal stage inside it) always sits beneath the pane chrome and drop highlight.
    public func addTabContent(_ view: NSView) { addSubview(view, positioned: .below, relativeTo: splitView) }
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
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget = resolveDropTarget(sender)
        guard let dropTarget else { dropZone.isHidden = true; return [] }
        dropZone.edge = dropTarget.edge
        dropZone.frame = convert(dropTarget.previewFrame, from: splitView)
        dropZone.needsDisplay = true
        dropZone.isHidden = false
        return .move
    }
    public override func draggingExited(_ sender: NSDraggingInfo?) { endDropPreview() }
    public override func draggingEnded(_ sender: NSDraggingInfo) { endDropPreview() }
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { endDropPreview() }
        // The release coordinate is authoritative; a refused final position drops nothing.
        guard let target = resolveDropTarget(sender) else { return false }
        let pasteboard = sender.draggingPasteboard
        if let raw = pasteboard.string(forType: Self.sessionPasteboardType) {
            onDropSession?(SessionID(raw), target.target, target.edge)
        } else if let raw = pasteboard.string(forType: .string), let id = UUID(uuidString: raw) {
            onDropTab?(id, target.target, target.edge)
        }
        return true
    }
    private func resolveDropTarget(_ sender: NSDraggingInfo) -> SplitLayout.DropTarget? {
        let pasteboard = sender.draggingPasteboard
        let source: SessionID
        if let raw = pasteboard.string(forType: Self.sessionPasteboardType), !raw.isEmpty {
            source = SessionID(raw)
        } else if let raw = pasteboard.string(forType: .string), let id = UUID(uuidString: raw), id != activeTabID {
            // Another Tab's session never lives in the visible layout; only the candidate geometry matters.
            source = SessionID("tab:" + raw)
        } else {
            return nil
        }
        return SplitLayout.dropTarget(at: splitView.convert(sender.draggingLocation, from: nil), source: source, root: splitView.root, in: splitView.bounds, previous: dropTarget)
    }
    private func endDropPreview() { dropZone.isHidden = true; dropTarget = nil }
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
            collapseButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9), collapseButton.centerYAnchor.constraint(equalTo: centerYAnchor), collapseButton.widthAnchor.constraint(equalToConstant: 28), collapseButton.heightAnchor.constraint(equalToConstant: 27),
            dragRegion.leadingAnchor.constraint(equalTo: trafficLightsSpacer.trailingAnchor), dragRegion.trailingAnchor.constraint(equalTo: collapseButton.leadingAnchor, constant: -8), dragRegion.topAnchor.constraint(equalTo: topAnchor), dragRegion.bottomAnchor.constraint(equalTo: bottomAnchor),
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
    private let previewBanner = NSView()
    private let previewLabel = NSTextField(labelWithString: "正在预览")
    public let previewExitButton = NSButton(title: "退出预览", target: nil, action: nil)
    public var onCreateTab: (() -> Void)?
    public var onSettings: (() -> Void)?
    public var onCreateAgent: ((UUID?) -> Void)?
    public var onToggleSidebar: (() -> Void)?
    public var onSelectAgent: ((SessionID, SessionOpenGesture) -> Void)?
    public var onClosePreview: (() -> Void)?
    public var onOpenSession: ((UUID, UUID?, Bool) -> Void)?
    public var onFocusSession: ((UUID, UUID) -> Void)?
    public var onDevices: (() -> Void)?
    public var onTabContextAction: ((UUID, String) -> Void)?
    public var onEffectiveAppearanceChanged: (() -> Void)?
    public private(set) var previewSessionID: UUID?
    public var isSidebarCollapsed: Bool { !sidebarIsVisible }
    public static let sidebarWidth: CGFloat = 280
    public static let headerHeight: CGFloat = 38
    private var sidebarColumnWidth: NSLayoutConstraint!
    private var sidebarIsVisible = true
    private var lastObservedEffectiveAppearance: NSAppearance.Name?

    public init(tabs: [CorralTab] = [], sidebar: CorralSidebarView = CorralSidebarView()) {
        self.sidebar = sidebar
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = CorralAestheticTokens.background.cgColor
        for view in [titleBar, sidebar, tabBar, stageContainer, previewBanner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        sidebarColumnWidth = sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth)
        sidebarColumnWidth.priority = .required
        previewBanner.wantsLayer = true
        previewBanner.layer?.cornerRadius = 8
        previewBanner.layer?.borderWidth = 1
        previewBanner.identifier = NSUserInterfaceItemIdentifier("corral.preview.banner")
        previewBanner.isHidden = true
        previewLabel.font = .systemFont(ofSize: 12, weight: .medium)
        previewLabel.textColor = CorralAestheticTokens.text
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewExitButton.isBordered = false
        previewExitButton.contentTintColor = CorralAestheticTokens.textSecondary
        previewExitButton.focusRingType = .none
        previewExitButton.setAccessibilityLabel("退出预览")
        previewExitButton.setAccessibilityIdentifier("corral.preview.exit")
        previewExitButton.target = self
        previewExitButton.action = #selector(exitPreview)
        previewExitButton.translatesAutoresizingMaskIntoConstraints = false
        previewBanner.addSubview(previewLabel)
        previewBanner.addSubview(previewExitButton)
        NSLayoutConstraint.activate([
            sidebarColumnWidth,
            titleBar.leadingAnchor.constraint(equalTo: leadingAnchor), titleBar.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor), titleBar.topAnchor.constraint(equalTo: topAnchor), titleBar.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor), sidebar.topAnchor.constraint(equalTo: titleBar.bottomAnchor), sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), tabBar.trailingAnchor.constraint(equalTo: trailingAnchor), tabBar.topAnchor.constraint(equalTo: topAnchor), tabBar.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            stageContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), stageContainer.trailingAnchor.constraint(equalTo: trailingAnchor), stageContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor), stageContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            previewBanner.trailingAnchor.constraint(equalTo: stageContainer.trailingAnchor, constant: -12), previewBanner.topAnchor.constraint(equalTo: stageContainer.topAnchor, constant: 12), previewBanner.widthAnchor.constraint(equalToConstant: 196), previewBanner.heightAnchor.constraint(equalToConstant: 34),
            previewLabel.leadingAnchor.constraint(equalTo: previewBanner.leadingAnchor, constant: 10), previewLabel.centerYAnchor.constraint(equalTo: previewBanner.centerYAnchor), previewLabel.trailingAnchor.constraint(lessThanOrEqualTo: previewExitButton.leadingAnchor, constant: -6),
            previewExitButton.trailingAnchor.constraint(equalTo: previewBanner.trailingAnchor, constant: -8), previewExitButton.centerYAnchor.constraint(equalTo: previewBanner.centerYAnchor), previewExitButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 62)
        ])
        previewBanner.layer?.backgroundColor = CorralAestheticTokens.surface2.cgColor
        previewBanner.layer?.borderColor = CorralAestheticTokens.borderSubtle.cgColor
        titleBar.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        tabBar.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        tabBar.bindSidebarToggleButton(titleBar.collapseButton)
        tabBar.bindDevicesButton(sidebar.devicesButton)
        sidebar.onSettings = { [weak self] in self?.onSettings?() }; sidebar.onCreateAgent = { [weak self] in self?.onCreateAgent?($0) }; sidebar.onToggleDevices = { [weak self] in self?.onDevices?() }
        sidebar.onSelectAgent = { [weak self] sessionID, gesture in self?.onSelectAgent?(sessionID, gesture) }
        tabBar.onSelectTab = { [weak self] in self?.selectTab(id: $0) }; tabBar.onCreateTab = { [weak self] in self?.onCreateTab?() }; tabBar.onCloseTab = { [weak self] in self?.closeTab(id: $0) }
        tabBar.onRenameTab = { [weak self] id, title in self?.renameTab(id: id, title: title) }; tabBar.onReorderTabs = { [weak self] id, index in self?.reorderTab(id: id, to: index) }
        tabBar.onContextAction = { [weak self] id, action in self?.performTabContextAction(id, action) }
        stageContainer.onCreateAgent = { [weak self] in self?.onCreateAgent?(nil) }
        let orderedTabs = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
        for tab in orderedTabs { attach(tab) }
        self.tabs = orderedTabs; tabBar.setTabs(orderedTabs, selectedTabID: nil); stageContainer.showEmptyState(orderedTabs.isEmpty, action: nil)
        if let first = orderedTabs.first { selectTab(id: first.id) }
    }
    public required init?(coder: NSCoder) { fatalError("CorralWorkspaceView is created programmatically") }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let current = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua
        guard current != lastObservedEffectiveAppearance else { return }
        lastObservedEffectiveAppearance = current
        guard CorralAestheticTokens.themeMode == .system else { return }
        setTheme(.system)
        onEffectiveAppearanceChanged?()
    }
    public override func layout() {
        // Keep both the sidebar and two minimum-width terminal panes usable in
        // a one-third-width desktop window. Wide windows retain the full sidebar.
        let width = sidebarIsVisible ? min(Self.sidebarWidth, max(180, bounds.width - 300)) : 0
        if sidebarColumnWidth.constant != width { sidebarColumnWidth.constant = width }
        super.layout()
    }
    public func addTab(_ tab: CorralTab, select: Bool = true) { guard !tabs.contains(where: { $0.id == tab.id }) else { return }; attach(tab); tabs.append(tab); stageContainer.showEmptyState(false, action: nil); tabBar.setTabs(tabs, selectedTabID: activeTabID); if select || activeTabID == nil { selectTab(id: tab.id) } }
    public func synchronizeWorkspaceTabs(_ tabs: [CorralTab], selectedTabID: UUID, previewSessionID: UUID?) {
        let ordered = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
        let ids = Set(ordered.map(\.id))
        for tab in self.tabs where !ids.contains(tab.id) { tab.contentView.removeFromSuperview() }
        for tab in ordered where !self.tabs.contains(where: { $0.id == tab.id }) { attach(tab) }
        self.tabs = ordered
        activeTabID = selectedTabID
        self.previewSessionID = previewSessionID
        previewBanner.isHidden = previewSessionID == nil
        stageContainer.activeTabID = selectedTabID
        for tab in ordered { tab.contentView.isHidden = tab.id != selectedTabID }
        tabBar.setTabs(ordered, selectedTabID: selectedTabID)
    }
    public func setSidebarCollapsed(_ collapsed: Bool) {
        let isVisible = !collapsed
        sidebarIsVisible = isVisible
        sidebarColumnWidth.constant = isVisible ? Self.sidebarWidth : 0
        tabBar.setSidebarCollapsed(collapsed)
        titleBar.isHidden = !isVisible
        sidebar.isHidden = !isVisible
    }
    public func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        tabSwitchTelemetry.beginSwitch(); defer { tabSwitchTelemetry.endSwitch() }
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
    public func renameTab(id: UUID, title: String) { guard !title.isEmpty, let tab = tabs.first(where: { $0.id == id }) else { return }; tab.title = title; tab.isCustomTitle = true; tabBar.setTabs(tabs, selectedTabID: activeTabID) }
    fileprivate func performTabContextAction(_ id: UUID, _ action: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), let tab = tabs.first(where: { $0.id == id }) else { return }
        switch action {
        case "pin", "splitRight", "splitDown": onTabContextAction?(id, action)
        case "close": tabBar.close(id)
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
        lastObservedEffectiveAppearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua
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
    private func attach(_ tab: CorralTab) {
        let view = tab.contentView; view.translatesAutoresizingMaskIntoConstraints = false; view.isHidden = true; stageContainer.addTabContent(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: stageContainer.leadingAnchor), view.trailingAnchor.constraint(equalTo: stageContainer.trailingAnchor), view.topAnchor.constraint(equalTo: stageContainer.topAnchor), view.bottomAnchor.constraint(equalTo: stageContainer.bottomAnchor)])
    }
    @objc private func exitPreview() { if previewSessionID != nil { onClosePreview?() } }
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
