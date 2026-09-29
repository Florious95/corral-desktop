import AppKit
import CorralContracts
import CorralServices

public struct CorralMVPSessionRow: Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let status: String
    public let provider: String?
    public let isSelected: Bool

    public init(id: UUID, name: String, status: String = "idle", provider: String? = nil, isSelected: Bool = false) {
        self.id = id
        self.name = name
        self.status = status
        self.provider = provider
        self.isSelected = isSelected
    }
}

@MainActor
private final class CorralMVPSessionCellView: CorralSidebarCellView {
    private let statusIndicator = CorralStatusIndicatorView()
    private let providerSlot = NSView()
    private let nameField: NSTextField

    init(session: CorralMVPSessionRow) {
        nameField = NSTextField(labelWithString: session.name)
        super.init(frame: .zero)
        statusIndicator.status = CorralStatusIndicatorView.Status(rawValue: session.status) ?? .unknown
        nameField.font = .systemFont(ofSize: 13, weight: session.isSelected ? .semibold : .regular)
        nameField.textColor = CorralAestheticTokens.text
        nameField.lineBreakMode = .byTruncatingTail
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameField.setContentHuggingPriority(.init(1), for: .horizontal)
        addSubview(statusIndicator)
        addSubview(providerSlot)
        addSubview(nameField)
        if let provider = session.provider, !provider.isEmpty {
            providerSlot.addSubview(CorralProviderIconView(provider: provider, size: 18, active: session.status == "working" || session.status == "blocked"))
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        statusIndicator.frame = NSRect(x: 24, y: (bounds.height - 8) / 2, width: 8, height: 8)
        providerSlot.frame = NSRect(x: 42, y: (bounds.height - 18) / 2, width: 18, height: 18)
        let textHeight = ceil(nameField.fittingSize.height)
        nameField.frame = NSRect(x: 70.5, y: (bounds.height - textHeight) / 2, width: max(0, bounds.width - 82.5), height: textHeight)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layout()
    }
}

@MainActor
public final class CorralMVPWorkspaceView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    public let stageContainer = NSView()
    public let sidebar: NSView = NSView()
    public let collapseButton = NSButton(title: "", target: nil, action: nil)
    public let devicesButton = NSButton(title: "查看所有主机", target: nil, action: nil)
    public static let terminalViewportLeadingInset: CGFloat = 5
    public var onSelectAgent: ((UUID) -> Void)?
    public var onToggleSidebar: (() -> Void)?
    public var onShowAllHosts: (() -> Void)?

    private let sidebarHeader = NSView()
    private let sidebarFooter = NSView()
    private let sidebarHeaderBorder = NSView()
    private let sidebarFooterBorder = NSView()
    private let table = CorralAgentTableView()
    private let scrollView = NSScrollView()
    private var sessions: [CorralMVPSessionRow] = []

    public override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = CorralAestheticTokens.background.cgColor
        sidebar.identifier = NSUserInterfaceItemIdentifier("corral.mvp.sidebar")
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = CorralAestheticTokens.surface0.cgColor
        sidebarHeader.wantsLayer = true
        sidebarHeader.layer?.backgroundColor = CorralAestheticTokens.surface0.cgColor
        sidebarFooter.wantsLayer = true
        sidebarFooter.layer?.backgroundColor = CorralAestheticTokens.surface0.cgColor
        sidebarHeaderBorder.wantsLayer = true
        sidebarHeaderBorder.layer?.backgroundColor = CorralAestheticTokens.border.cgColor
        sidebarFooterBorder.wantsLayer = true
        sidebarFooterBorder.layer?.backgroundColor = CorralAestheticTokens.border.cgColor
        stageContainer.identifier = NSUserInterfaceItemIdentifier("corral.mvp.stage")
        stageContainer.wantsLayer = true
        stageContainer.layer?.backgroundColor = CorralAestheticTokens.background.cgColor

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        stageContainer.translatesAutoresizingMaskIntoConstraints = false
        sidebarHeader.translatesAutoresizingMaskIntoConstraints = false
        sidebarFooter.translatesAutoresizingMaskIntoConstraints = false
        sidebarHeaderBorder.translatesAutoresizingMaskIntoConstraints = false
        sidebarFooterBorder.translatesAutoresizingMaskIntoConstraints = false
        collapseButton.image = CorralLegacyIcon.image(.sidebar, size: 16)
        collapseButton.imagePosition = .imageOnly
        collapseButton.isBordered = false
        collapseButton.contentTintColor = CorralAestheticTokens.icon
        collapseButton.toolTip = "隐藏侧边栏"
        collapseButton.setAccessibilityLabel("隐藏侧边栏")
        collapseButton.setAccessibilityIdentifier("corral.sidebar.toggle")
        collapseButton.target = self
        collapseButton.action = #selector(toggleSidebar)
        devicesButton.image = CorralLegacyIcon.image(.layers, size: 15, tint: CorralAestheticTokens.text)
        devicesButton.imagePosition = .imageLeading
        devicesButton.imageHugsTitle = true
        devicesButton.font = .systemFont(ofSize: 13, weight: .semibold)
        devicesButton.isBordered = false
        devicesButton.contentTintColor = CorralAestheticTokens.text
        devicesButton.setAccessibilityLabel("查看所有主机")
        devicesButton.setAccessibilityIdentifier("corral.sidebar.devices")
        devicesButton.target = self
        devicesButton.action = #selector(showAllHosts)
        for view in [collapseButton, sidebarHeaderBorder] { view.translatesAutoresizingMaskIntoConstraints = false; sidebarHeader.addSubview(view) }
        for view in [devicesButton, sidebarFooterBorder] { view.translatesAutoresizingMaskIntoConstraints = false; sidebarFooter.addSubview(view) }
        addSubview(sidebar)
        addSubview(stageContainer)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarHeader)
        sidebar.addSubview(sidebarFooter)
        sidebar.addSubview(scrollView)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 280),
            sidebarHeader.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarHeader.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarHeader.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarHeader.heightAnchor.constraint(equalToConstant: 38),
            sidebarHeaderBorder.leadingAnchor.constraint(equalTo: sidebarHeader.leadingAnchor),
            sidebarHeaderBorder.trailingAnchor.constraint(equalTo: sidebarHeader.trailingAnchor),
            sidebarHeaderBorder.bottomAnchor.constraint(equalTo: sidebarHeader.bottomAnchor),
            sidebarHeaderBorder.heightAnchor.constraint(equalToConstant: 1),
            collapseButton.leadingAnchor.constraint(equalTo: sidebarHeader.leadingAnchor, constant: 243),
            collapseButton.centerYAnchor.constraint(equalTo: sidebarHeader.centerYAnchor),
            collapseButton.widthAnchor.constraint(equalToConstant: 28),
            collapseButton.heightAnchor.constraint(equalToConstant: 27),
            sidebarFooter.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarFooter.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarFooter.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            sidebarFooter.heightAnchor.constraint(equalToConstant: 44),
            sidebarFooterBorder.leadingAnchor.constraint(equalTo: sidebarFooter.leadingAnchor),
            sidebarFooterBorder.trailingAnchor.constraint(equalTo: sidebarFooter.trailingAnchor),
            sidebarFooterBorder.topAnchor.constraint(equalTo: sidebarFooter.topAnchor),
            sidebarFooterBorder.heightAnchor.constraint(equalToConstant: 1),
            devicesButton.leadingAnchor.constraint(equalTo: sidebarFooter.leadingAnchor, constant: 12),
            devicesButton.centerYAnchor.constraint(equalTo: sidebarFooter.centerYAnchor),
            devicesButton.widthAnchor.constraint(equalToConstant: 222),
            devicesButton.heightAnchor.constraint(equalToConstant: 35),
            scrollView.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: sidebarHeader.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: sidebarFooter.topAnchor),
            stageContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            stageContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            stageContainer.topAnchor.constraint(equalTo: topAnchor),
            stageContainer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session")))
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowSizeStyle = .custom
        table.intercellSpacing = .zero
        table.backgroundColor = CorralAestheticTokens.surface0
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.usesAutomaticRowHeights = false
        table.dataSource = self
        table.delegate = self
        table.sessionIDForRow = { [weak self] row in
            guard let self, self.sessions.indices.contains(row) else { return nil }
            return SessionID(self.sessions[row].id.uuidString)
        }
        table.onAgentClick = { [weak self] sessionID, _ in
            guard let id = UUID(uuidString: sessionID.rawValue) else { return }
            self?.onSelectAgent?(id)
        }

        table.autoresizingMask = [.width]
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
    }

    public required init?(coder: NSCoder) { nil }

    @objc private func toggleSidebar() { onToggleSidebar?() }
    @objc private func showAllHosts() { onShowAllHosts?() }

    public func setSessions(_ sessions: [CorralMVPSessionRow]) {
        self.sessions = sessions
        table.reloadData()
        if let selected = sessions.firstIndex(where: \.isSelected) {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
    }

    public func attachStageView(_ view: NSView) {
        guard view.superview !== stageContainer else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        stageContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: stageContainer.leadingAnchor, constant: Self.terminalViewportLeadingInset),
            view.trailingAnchor.constraint(equalTo: stageContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: stageContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: stageContainer.bottomAnchor)
        ])
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { sessions.count }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 34 }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = CorralSidebarRowView()
        rowView.isAgentRow = true
        return rowView
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard sessions.indices.contains(row) else { return nil }
        let session = sessions[row]
        let cell = CorralMVPSessionCellView(session: session)
        cell.identifier = NSUserInterfaceItemIdentifier("corral.mvp.session-row")
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.button)
        cell.setAccessibilityIdentifier("corral.mvp.session-row")
        cell.setAccessibilityLabel("\(session.name), \(session.status)")
        cell.onPress = { [weak self] in self?.onSelectAgent?(session.id) }
        return cell
    }
}
