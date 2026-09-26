import AppKit
import CorralContracts

@MainActor
public final class CorralTab {
    public let id: UUID
    public var title: String
    public var badge: String?
    /// The view is created once for this tab and remains attached while other tabs are selected.
    public let contentView: NSView

    public init(id: UUID = UUID(), title: String, badge: String? = nil, contentView: NSView) {
        self.id = id
        self.title = title
        self.badge = badge
        self.contentView = contentView
    }
}

@MainActor
public final class CorralTabBarView: NSView {
    public private(set) var tabs: [CorralTab] = []
    public private(set) var selectedTabID: UUID?
    public var onSelectTab: ((UUID) -> Void)?
    public var onCreateTab: (() -> Void)?
    public var onCloseTab: ((UUID) -> Void)?

    private let tabStack = NSStackView()
    private let createButton = NSButton(title: "+", target: nil, action: nil)

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = CorralAestheticTokens.surface0.cgColor
        tabStack.orientation = .horizontal
        tabStack.alignment = .centerY
        tabStack.spacing = 4
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabStack)

        createButton.title = "+"
        createButton.font = .systemFont(ofSize: 18, weight: .regular)
        createButton.isBordered = false
        createButton.contentTintColor = CorralAestheticTokens.textSecondary
        createButton.toolTip = "New tab"
        createButton.target = self
        createButton.action = #selector(createTab)
        createButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(createButton)

        NSLayoutConstraint.activate([
            tabStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            tabStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            tabStack.trailingAnchor.constraint(lessThanOrEqualTo: createButton.leadingAnchor, constant: -8),
            createButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            createButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            createButton.widthAnchor.constraint(equalToConstant: 28),
            createButton.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    public required init?(coder: NSCoder) {
        fatalError("CorralTabBarView is created programmatically")
    }

    public func setTabs(_ tabs: [CorralTab], selectedTabID: UUID?) {
        self.tabs = tabs
        self.selectedTabID = tabs.contains(where: { $0.id == selectedTabID }) ? selectedTabID : nil
        tabStack.arrangedSubviews.forEach {
            tabStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for tab in tabs {
            let item = CorralTabItemView(tab: tab, selected: tab.id == self.selectedTabID)
            item.onSelect = { [weak self] in self?.select(tab.id) }
            item.onClose = { [weak self] in self?.onCloseTab?(tab.id) }
            tabStack.addArrangedSubview(item)
        }
    }

    private func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
        setTabs(tabs, selectedTabID: id)
        onSelectTab?(id)
    }

    @objc private func createTab() {
        onCreateTab?()
    }
}

@MainActor
private final class CorralTabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let selectButton = NSButton(title: "", target: nil, action: nil)
    private let badgeLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "×", target: nil, action: nil)

    init(tab: CorralTab, selected: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = (selected ? CorralAestheticTokens.surface2 : .clear).cgColor

        selectButton.title = tab.title
        selectButton.font = .systemFont(ofSize: 12, weight: selected ? .medium : .regular)
        selectButton.contentTintColor = selected ? CorralAestheticTokens.text : CorralAestheticTokens.textSecondary
        selectButton.cell?.lineBreakMode = .byTruncatingTail
        selectButton.cell?.wraps = false
        selectButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        badgeLabel.stringValue = tab.badge ?? ""
        badgeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        badgeLabel.textColor = CorralAestheticTokens.text
        badgeLabel.alignment = .center
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.backgroundColor = CorralAestheticTokens.surface3.cgColor
        badgeLabel.layer?.cornerRadius = 5
        badgeLabel.isHidden = tab.badge == nil || tab.badge?.isEmpty == true

        selectButton.isBordered = false
        selectButton.alignment = .left
        selectButton.target = self
        selectButton.action = #selector(selectTab)
        selectButton.setAccessibilityLabel("Select tab \(tab.title)")

        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 14, weight: .regular)
        closeButton.contentTintColor = CorralAestheticTokens.textMuted
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.toolTip = "Close \(tab.title)"
        closeButton.setAccessibilityLabel("Close tab \(tab.title)")

        let contents = NSStackView(views: [selectButton, badgeLabel, closeButton])
        contents.orientation = .horizontal
        contents.alignment = .centerY
        contents.spacing = 6
        contents.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contents)
        selectButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            contents.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            contents.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            contents.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            contents.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            closeButton.widthAnchor.constraint(equalToConstant: 17),
            closeButton.heightAnchor.constraint(equalToConstant: 19),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            badgeLabel.heightAnchor.constraint(equalToConstant: 16),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
            widthAnchor.constraint(lessThanOrEqualToConstant: 190),
            heightAnchor.constraint(equalToConstant: 32)
        ])
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("CorralTabItemView is created programmatically")
    }

    @objc private func selectTab() { onSelect?() }
    @objc private func closeTab() { onClose?() }
}

public enum CorralSplitOrientation: Sendable {
    case columns
    case rows
}

public indirect enum CorralSplitLayout: Sendable {
    case leaf(UUID)
    case split(CorralSplitOrientation, [CorralSplitLayout])
}

@MainActor
public final class SplitWorkspaceView: NSView, NSSplitViewDelegate {
    public private(set) var splitterCount = 0
    public let stageViews: [UUID: NSView]
    private let minimumPaneExtent: CGFloat = 96
    private var splitViews: [NSSplitView] = []

    public init(layout: CorralSplitLayout, stages: [UUID: NSView]) {
        stageViews = stages
        super.init(frame: .zero)
        let root = makeNode(layout, stages: stages)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        splitterCount = splitViews.count
        wantsLayer = true
        layer?.backgroundColor = CorralAestheticTokens.background.cgColor
    }

    public required init?(coder: NSCoder) {
        fatalError("SplitWorkspaceView is created programmatically")
    }

    private func makeNode(_ layout: CorralSplitLayout, stages: [UUID: NSView]) -> NSView {
        switch layout {
        case .leaf(let id):
            guard let stage = stages[id] else { preconditionFailure("Missing stage view for split leaf \(id)") }
            return stage
        case .split(let orientation, let children):
            precondition(children.count >= 2, "A split requires at least two children")
            let split = CorralNativeSplitView(frame: .zero)
            split.isVertical = orientation == .columns
            split.dividerStyle = .thin
            split.delegate = self
            splitViews.append(split)
            for child in children {
                split.addSubview(makeNode(child, stages: stages))
            }
            return split
        }
    }

    public func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMin, minimumPaneExtent)
    }

    public func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        return min(proposedMax, max(minimumPaneExtent, extent - minimumPaneExtent))
    }
}

@MainActor
private final class CorralNativeSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 1 }

    override func drawDivider(in rect: NSRect) {
        CorralAestheticTokens.borderSubtle.setFill()
        NSBezierPath(rect: rect).fill()
    }
}

public struct CorralSidebarSession: Sendable, Identifiable {
    public let id: UUID
    public let name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

public struct CorralSidebarDevice: Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let sessions: [CorralSidebarSession]

    public init(id: UUID = UUID(), name: String, sessions: [CorralSidebarSession] = []) {
        self.id = id
        self.name = name
        self.sessions = sessions
    }
}

@MainActor
public final class CorralDeviceBadgeView: NSView {
    public private(set) var deviceNames: [String] = []
    public let maximumWidth = CorralAestheticTokens.multiDeviceBadgeMaximumWidth
    public var displayedText: String { label.stringValue }

    private let label = NSTextField(labelWithString: "")
    private var widthConstraint: NSLayoutConstraint!

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = CorralAestheticTokens.surface2.cgColor
        layer?.cornerRadius = 8

        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = CorralAestheticTokens.textSecondary
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        widthConstraint = widthAnchor.constraint(equalToConstant: 24)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        update(deviceNames: [])
    }

    public required init?(coder: NSCoder) {
        fatalError("CorralDeviceBadgeView is created programmatically")
    }

    public func update(deviceNames: [String]) {
        self.deviceNames = deviceNames
        isHidden = deviceNames.count <= 1
        let fullText = deviceNames.joined(separator: " · ")
        label.stringValue = fullText
        toolTip = deviceNames.count > 1 ? deviceNames.joined(separator: ", ") : nil
        let naturalWidth = label.intrinsicContentSize.width + 12
        widthConstraint.constant = isHidden ? 0 : min(maximumWidth, max(24, naturalWidth))
        needsLayout = true
    }
}

@MainActor
private final class CorralSidebarNode {
    let title: String
    let children: [CorralSidebarNode]

    init(title: String, children: [CorralSidebarNode] = []) {
        self.title = title
        self.children = children
    }
}

@MainActor
public final class CorralSidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    public let outlineView = NSOutlineView()
    public let deviceBadgeView = CorralDeviceBadgeView()
    public private(set) var devices: [CorralSidebarDevice] = []
    public var onSelectSession: ((UUID) -> Void)?

    private let scrollView = NSScrollView()
    private let headerTitle = NSTextField(labelWithString: "DEVICES")
    private var nodes: [CorralSidebarNode] = []
    private var sessionIDs: [ObjectIdentifier: UUID] = [:]

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = CorralAestheticTokens.surface0.cgColor

        headerTitle.font = .systemFont(ofSize: 10, weight: .semibold)
        headerTitle.textColor = CorralAestheticTokens.textMuted
        deviceBadgeView.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerTitle)
        addSubview(deviceBadgeView)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar-item"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 26
        outlineView.indentationPerLevel = 13
        outlineView.style = .sourceList
        outlineView.backgroundColor = CorralAestheticTokens.surface0
        outlineView.dataSource = self
        outlineView.delegate = self
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            headerTitle.centerYAnchor.constraint(equalTo: deviceBadgeView.centerYAnchor),
            deviceBadgeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            deviceBadgeView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            headerTitle.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            scrollView.topAnchor.constraint(equalTo: deviceBadgeView.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    public convenience init(devices: [CorralSidebarDevice]) {
        self.init(frame: .zero)
        setDevices(devices)
    }

    public required init?(coder: NSCoder) {
        fatalError("CorralSidebarView is created programmatically")
    }

    public func setDevices(_ devices: [CorralSidebarDevice]) {
        self.devices = devices
        deviceBadgeView.update(deviceNames: devices.map(\.name))
        sessionIDs.removeAll(keepingCapacity: true)
        nodes = devices.map { device in
            let sessions = device.sessions.map { session -> CorralSidebarNode in
                let node = CorralSidebarNode(title: session.name)
                sessionIDs[ObjectIdentifier(node)] = session.id
                return node
            }
            return CorralSidebarNode(title: device.name, children: sessions)
        }
        outlineView.reloadData()
        for node in nodes where !node.children.isEmpty {
            outlineView.expandItem(node)
        }
    }

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? CorralSidebarNode else { return nodes.count }
        return item.children.count
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? CorralSidebarNode else { return nodes[index] }
        return item.children[index]
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? CorralSidebarNode)?.children.isEmpty == false
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? CorralSidebarNode else { return nil }
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: node.title)
        text.font = .systemFont(ofSize: 12, weight: node.children.isEmpty ? .regular : .medium)
        text.textColor = node.children.isEmpty ? CorralAestheticTokens.textSecondary : CorralAestheticTokens.text
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.textField = text
        return cell
    }

    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let sessionID = sessionIDs[ObjectIdentifier(item as AnyObject)] else { return true }
        onSelectSession?(sessionID)
        return true
    }
}

@MainActor
public final class CorralTitleBarView: NSView {
    public var onSettings: (() -> Void)?

    private let dragRegion = CorralWindowDragRegion()
    private let titleLabel = NSTextField(labelWithString: "Corral")
    private let settingsButton = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings") ?? NSImage(), target: nil, action: nil)

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = CorralAestheticTokens.surface0.cgColor
        dragRegion.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dragRegion)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = CorralAestheticTokens.text
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        settingsButton.isBordered = false
        settingsButton.bezelStyle = .regularSquare
        settingsButton.contentTintColor = CorralAestheticTokens.text
        settingsButton.toolTip = "Settings"
        settingsButton.setAccessibilityLabel("Settings")
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.wantsLayer = true
        settingsButton.layer?.backgroundColor = CorralAestheticTokens.surface2.cgColor
        settingsButton.layer?.cornerRadius = 5
        settingsButton.layer?.borderColor = CorralAestheticTokens.border.cgColor
        settingsButton.layer?.borderWidth = 1
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(settingsButton)

        NSLayoutConstraint.activate([
            dragRegion.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 76),
            dragRegion.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -8),
            dragRegion.topAnchor.constraint(equalTo: topAnchor),
            dragRegion.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            settingsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 32),
            settingsButton.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    public required init?(coder: NSCoder) {
        fatalError("CorralTitleBarView is created programmatically")
    }

    @objc private func openSettings() { onSettings?() }
}

@MainActor
public final class CorralWorkspaceView: NSView {
    public let tabBar = CorralTabBarView()
    public let sidebar: CorralSidebarView
    public let stageContainer = NSView()
    public private(set) var tabs: [CorralTab] = []
    public private(set) var activeTabID: UUID?
    public var onCreateTab: (() -> Void)?
    public var onSettings: (() -> Void)?

    private let titleBar = CorralTitleBarView()

    public init(tabs: [CorralTab] = [], sidebar: CorralSidebarView = CorralSidebarView()) {
        self.sidebar = sidebar
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CorralAestheticTokens.background.cgColor

        titleBar.onSettings = { [weak self] in self?.onSettings?() }
        tabBar.onSelectTab = { [weak self] id in self?.selectTab(id: id) }
        tabBar.onCreateTab = { [weak self] in self?.onCreateTab?() }
        tabBar.onCloseTab = { [weak self] id in self?.closeTab(id: id) }

        let body = NSStackView(views: [sidebar, stageContainer])
        body.orientation = .horizontal
        body.alignment = .top
        body.distribution = .fill
        body.spacing = 0
        body.translatesAutoresizingMaskIntoConstraints = false
        sidebar.widthAnchor.constraint(equalToConstant: 216).isActive = true
        stageContainer.wantsLayer = true
        stageContainer.layer?.backgroundColor = CorralAestheticTokens.background.cgColor

        let layout = NSStackView(views: [titleBar, tabBar, body])
        layout.orientation = .vertical
        layout.alignment = .width
        layout.distribution = .fill
        layout.spacing = 0
        layout.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: trailingAnchor),
            layout.topAnchor.constraint(equalTo: topAnchor),
            layout.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: 40),
            tabBar.heightAnchor.constraint(equalToConstant: 36)
        ])

        for tab in tabs { attach(tab) }
        self.tabs = tabs
        tabBar.setTabs(tabs, selectedTabID: nil)
        if let first = tabs.first { selectTab(id: first.id) }
    }

    public required init?(coder: NSCoder) {
        fatalError("CorralWorkspaceView is created programmatically")
    }

    public func addTab(_ tab: CorralTab, select: Bool = true) {
        guard !tabs.contains(where: { $0.id == tab.id }) else { return }
        attach(tab)
        tabs.append(tab)
        tabBar.setTabs(tabs, selectedTabID: activeTabID)
        if select || activeTabID == nil { selectTab(id: tab.id) }
    }

    public func selectTab(id: UUID) {
        guard let selected = tabs.first(where: { $0.id == id }) else { return }
        activeTabID = id
        for tab in tabs {
            tab.contentView.isHidden = tab.id != id
        }
        tabBar.setTabs(tabs, selectedTabID: id)
        if let firstResponder = firstFocusableView(in: selected.contentView) {
            window?.makeFirstResponder(firstResponder)
        }
    }

    public func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].contentView.removeFromSuperview()
        tabs.remove(at: index)
        let nextID = activeTabID == id ? tabs.dropFirst(max(0, index - 1)).first?.id ?? tabs.last?.id : activeTabID
        activeTabID = nil
        tabBar.setTabs(tabs, selectedTabID: nextID)
        if let nextID { selectTab(id: nextID) }
    }

    public func view(forTab id: UUID) -> NSView? {
        tabs.first(where: { $0.id == id })?.contentView
    }

    private func attach(_ tab: CorralTab) {
        let view = tab.contentView
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        stageContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: stageContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: stageContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: stageContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: stageContainer.bottomAnchor)
        ])
    }

    private func firstFocusableView(in view: NSView) -> NSView? {
        if view.acceptsFirstResponder { return view }
        for child in view.subviews {
            if let responder = firstFocusableView(in: child) { return responder }
        }
        return nil
    }
}
