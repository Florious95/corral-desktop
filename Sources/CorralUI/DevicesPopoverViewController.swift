import AppKit
import CorralContracts

@MainActor
public final class DevicesPopoverViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    public let repository: any DeviceRepositoryProtocol
    public private(set) var devices: [DeviceRecord] = []
    public private(set) var editingDeviceID: DeviceID?
    public private(set) var deletionConfirmationDeviceID: DeviceID?
    public private(set) var deletionInProgressDeviceID: DeviceID?
    public private(set) var errorMessage: String?
    public private(set) var selectedDeviceIDs = Set<DeviceID>()
    public private(set) var readyDeviceIDs = Set<DeviceID>()
    public var onDevicesChanged: (([DeviceRecord]) -> Void)?
    public var onSelectionChanged: ((Set<DeviceID>) -> Void)?
    public var onAddDevice: (() -> Void)?
    public var onPairMobile: (() -> Void)?

    public let tableView = NSTableView()
    /// Retained for API compatibility; the visible control is `allDevicesRow` (`.dp-row` "All Devices").
    public let allDevicesButton = NSButton(checkboxWithTitle: "All Devices", target: nil, action: nil)
    public let allDevicesRow = DevicesMenuRowView(icon: .layers, title: "All Devices")
    public let pairRow = DevicesMenuRowView(icon: .qr, title: "配对移动端…", secondary: true)
    public let addRow = DevicesMenuRowView(icon: .plus, title: "Add Device…", secondary: true)
    public let connectionStatus = CorralStatusIndicatorView()
    public let selectionSummary = NSTextField(labelWithString: "0 devices · 0 connected")
    private let errorLabel = NSTextField(labelWithString: "")
    private var tableHeight: NSLayoutConstraint!
    /// Native hosts card: 300pt wide, 155pt fixed chrome, 50pt per visible device row.
    public static let width: CGFloat = 300
    public static let contentInset: CGFloat = 6
    public static let cornerRadius: CGFloat = 12
    public static let fixedChromeHeight: CGFloat = 155
    public static let rowHeight: CGFloat = 50

    public init(repository: any DeviceRepositoryProtocol) {
        self.repository = repository
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: Self.width, height: 240)
    }

    public required init?(coder: NSCoder) {
        fatalError("DevicesPopoverViewController is created programmatically")
    }

    public override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("device-name"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityIdentifier("corral.devices.list")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let title = NSTextField(labelWithString: "")
        title.attributedStringValue = NSAttributedString(string: "DEVICES", attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .kern: 0.5, .foregroundColor: CorralAestheticTokens.textMuted])
        let titleRow = NSStackView(views: [title]); titleRow.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 6, right: 12)

        allDevicesButton.target = self; allDevicesButton.action = #selector(toggleAllDevices)
        allDevicesRow.accessory = connectionStatus
        allDevicesRow.subtitleField = selectionSummary
        allDevicesRow.setAccessibilityIdentifier("corral.devices.all")
        allDevicesRow.onPress = { [weak self] in
            guard let self else { return }
            self.allDevicesButton.state = self.allDevicesRow.isChecked ? .off : .on
            self.toggleAllDevices()
        }
        pairRow.setAccessibilityIdentifier("corral.devices.pair"); pairRow.onPress = { [weak self] in self?.pairMobile() }
        addRow.setAccessibilityIdentifier("corral.devices.add"); addRow.onPress = { [weak self] in self?.addDevice() }
        connectionStatus.status = .offline
        connectionStatus.translatesAutoresizingMaskIntoConstraints = false
        connectionStatus.widthAnchor.constraint(equalToConstant: 6).isActive = true; connectionStatus.heightAnchor.constraint(equalToConstant: 6).isActive = true
        let separator = NSView(); separator.wantsLayer = true; separator.layer?.backgroundColor = CorralAestheticTokens.border.cgColor
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = CorralAestheticTokens.danger
        errorLabel.isHidden = true

        let content = NSStackView(views: [titleRow, allDevicesRow, scrollView, pairRow, separator, addRow, errorLabel])
        content.orientation = .vertical
        content.alignment = .width
        content.distribution = .fill
        content.spacing = 0
        content.edgeInsets = NSEdgeInsets(top: Self.contentInset, left: Self.contentInset, bottom: Self.contentInset, right: Self.contentInset)
        content.setCustomSpacing(4, after: pairRow); content.setCustomSpacing(4, after: separator)
        content.setAccessibilityIdentifier("corral.devices.popover")
        content.wantsLayer = true
        content.layer?.backgroundColor = CorralAestheticTokens.surface2.cgColor
        content.layer?.cornerRadius = Self.cornerRadius
        content.layer?.masksToBounds = true
        view = content
        tableHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([content.widthAnchor.constraint(equalToConstant: Self.width), tableHeight])
        updateSelectionSummary()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        Task { [weak self] in try? await self?.reloadDevices() }
    }

    public func reloadDevices() async throws {
        devices = try await repository.listDevices()
        if selectedDeviceIDs.isEmpty { selectedDeviceIDs = Set(devices.map(\.id)) }
        tableView.reloadData()
        updateSelectionSummary()
        onDevicesChanged?(devices)
    }

    /// Lists up to five devices before scrolling; the popover resizes to its content.
    private func updateContentSize() {
        guard isViewLoaded else { return }
        let visibleRows = min(devices.count, 5)
        tableHeight.constant = CGFloat(visibleRows) * Self.rowHeight
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.width, height: Self.fixedChromeHeight + CGFloat(visibleRows) * Self.rowHeight)
    }

    public static func shouldCommitReturn(hasMarkedText: Bool) -> Bool {
        !hasMarkedText
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { devices.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard devices.indices.contains(row) else { return nil }
        let record = devices[row]
        let editing = editingDeviceID == record.id
        let confirmingDelete = deletionConfirmationDeviceID == record.id
        let rowView = DeviceManagementRowView(
            record: record,
            editing: editing,
            confirmingDelete: confirmingDelete,
            deleting: deletionInProgressDeviceID == record.id,
            selected: selectedDeviceIDs.contains(record.id),
            online: readyDeviceIDs.contains(record.id)
        )
        rowView.nameField.delegate = self
        rowView.onSelection = { [weak self] id, selected in self?.setDevice(id, selected: selected) }
        rowView.onRename = { [weak self] in self?.beginRenaming($0) }
        rowView.onSave = { [weak self] id, name in self?.scheduleRename(id, to: name) }
        rowView.onCancelRename = { [weak self] in self?.cancelRenaming($0) }
        rowView.onRequestDelete = { [weak self] in self?.requestDeletion(of: $0) }
        rowView.onConfirmDelete = { [weak self] in self?.scheduleDeletion(of: $0) }
        rowView.onCancelDelete = { [weak self] in self?.cancelDeletion(of: $0) }
        return rowView
    }

    public func beginRenaming(_ id: DeviceID) {
        guard devices.contains(where: { $0.id == id }) else { return }
        editingDeviceID = id
        deletionConfirmationDeviceID = nil
        tableView.reloadData()
        guard let row = devices.firstIndex(where: { $0.id == id }),
              let rowView = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? DeviceManagementRowView else { return }
        rowView.nameField.window?.makeFirstResponder(rowView.nameField)
    }

    public func cancelRenaming(_ id: DeviceID) {
        guard editingDeviceID == id else { return }
        editingDeviceID = nil
        tableView.reloadData()
    }

    @discardableResult
    public func commitRenaming(_ id: DeviceID, to proposedName: String, hasMarkedText: Bool = false) async throws -> Bool {
        guard Self.shouldCommitReturn(hasMarkedText: hasMarkedText),
              let record = prepareRename(id, to: proposedName) else { return false }
        try await persistRename(record)
        return true
    }

    public func requestDeletion(of id: DeviceID) {
        guard devices.contains(where: { $0.id == id }) else { return }
        editingDeviceID = nil
        deletionConfirmationDeviceID = id
        tableView.reloadData()
    }

    public func cancelDeletion(of id: DeviceID) {
        guard deletionConfirmationDeviceID == id, deletionInProgressDeviceID == nil else { return }
        deletionConfirmationDeviceID = nil
        tableView.reloadData()
    }

    @discardableResult
    public func confirmDeletion(of id: DeviceID) async throws -> Bool {
        guard deletionConfirmationDeviceID == id, deletionInProgressDeviceID == nil else { return false }
        deletionInProgressDeviceID = id
        tableView.reloadData()
        do {
            try await repository.delete(id: id)
            devices.removeAll { $0.id == id }
            selectedDeviceIDs.remove(id); readyDeviceIDs.remove(id)
            deletionConfirmationDeviceID = nil
            deletionInProgressDeviceID = nil
            tableView.reloadData()
            updateSelectionSummary()
            onDevicesChanged?(devices)
            return true
        } catch {
            deletionInProgressDeviceID = nil
            show(error)
            tableView.reloadData()
            throw error
        }
    }

    public func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        guard let field = control as? DeviceNameTextField else { return true }
        if let editor = control.currentEditor() as? NSTextView, editor.hasMarkedText() { return false }
        return editingDeviceID == field.deviceID
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let field = control as? DeviceNameTextField, let id = field.deviceID else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            guard Self.shouldCommitReturn(hasMarkedText: textView.hasMarkedText()) else { return false }
            scheduleRename(id, to: field.stringValue)
            field.window?.makeFirstResponder(tableView)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelRenaming(id)
            field.window?.makeFirstResponder(tableView)
            return true
        }
        return false
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? DeviceNameTextField,
              let id = field.deviceID,
              editingDeviceID == id else { return }
        scheduleRename(id, to: field.stringValue)
    }

    private func prepareRename(_ id: DeviceID, to proposedName: String) -> DeviceRecord? {
        guard editingDeviceID == id, let current = devices.first(where: { $0.id == id }) else { return nil }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            cancelRenaming(id)
            return nil
        }
        editingDeviceID = nil
        tableView.reloadData()
        guard name != current.name else { return nil }
        return DeviceRecord(id: current.id, name: name, endpoint: current.endpoint, credential: current.credential)
    }

    private func scheduleRename(_ id: DeviceID, to name: String) {
        guard let record = prepareRename(id, to: name) else { return }
        Task { [weak self] in
            do { try await self?.persistRename(record) }
            catch { self?.show(error) }
        }
    }

    private func persistRename(_ record: DeviceRecord) async throws {
        do {
            try await repository.save(record)
            if let index = devices.firstIndex(where: { $0.id == record.id }) { devices[index] = record }
            errorMessage = nil
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
            tableView.reloadData()
            onDevicesChanged?(devices)
        } catch {
            show(error)
            tableView.reloadData()
            throw error
        }
    }

    private func scheduleDeletion(of id: DeviceID) {
        Task { [weak self] in
            do { _ = try await self?.confirmDeletion(of: id) }
            catch { self?.show(error) }
        }
    }

    public func setReadyDevices(_ ids: Set<DeviceID>) {
        readyDeviceIDs = ids.intersection(Set(devices.map(\.id)))
        tableView.reloadData(); updateSelectionSummary()
    }

    public func setDevice(_ id: DeviceID, selected: Bool) {
        if selected { selectedDeviceIDs.insert(id) } else { selectedDeviceIDs.remove(id) }
        tableView.reloadData(); updateSelectionSummary()
        onSelectionChanged?(selectedDeviceIDs)
    }

    private func updateSelectionSummary() {
        let selectedCount = devices.filter { selectedDeviceIDs.contains($0.id) }.count
        selectionSummary.stringValue = "\(devices.count) devices · \(readyDeviceIDs.count) connected"
        allDevicesButton.state = selectedCount == 0 ? .off : selectedCount == devices.count ? .on : .mixed
        allDevicesRow.isChecked = !devices.isEmpty && selectedCount == devices.count
        connectionStatus.status = readyDeviceIDs.isEmpty ? .offline : .working
        updateContentSize()
    }

    @objc private func toggleAllDevices() { selectedDeviceIDs = allDevicesButton.state == .on ? Set(devices.map(\.id)) : []; tableView.reloadData(); updateSelectionSummary(); onSelectionChanged?(selectedDeviceIDs) }
    private func addDevice() { onAddDevice?() }
    private func pairMobile() { onPairMobile?() }

    private func show(_ error: Error) {
        errorMessage = String(describing: error)
        errorLabel.stringValue = errorMessage ?? ""
        errorLabel.isHidden = false
    }
}

@MainActor
private final class DeviceNameTextField: NSTextField {
    var deviceID: DeviceID?
}

/// `.dp-row` / `.dp-add`: icon, 13px semibold title (+ status dot), 11px muted subtitle, trailing check or actions.
@MainActor
public final class DevicesMenuRowView: NSView {
    public var onPress: (() -> Void)?
    public var isChecked = false { didSet { check.isHidden = !isChecked; setAccessibilitySelected(isChecked) } }
    let titleField = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let check = NSImageView()
    private let textStack = NSStackView()
    private let titleRow = NSStackView()
    private let trailing = NSStackView()
    private var isHovered = false { didSet { layer?.backgroundColor = (isHovered ? CorralAestheticTokens.hoverSubtle : NSColor.clear).cgColor } }
    var accessory: NSView? { didSet { if let accessory { titleRow.addArrangedSubview(accessory) } } }
    var subtitleField: NSTextField? {
        didSet {
            guard let subtitleField else { return }
            subtitleField.font = .systemFont(ofSize: 11); subtitleField.textColor = CorralAestheticTokens.textMuted; subtitleField.lineBreakMode = .byTruncatingTail
            textStack.addArrangedSubview(subtitleField)
        }
    }

    public init(icon: CorralLegacyIcon, title: String, secondary: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 8
        iconView.image = CorralLegacyIcon.image(icon, size: 16); iconView.contentTintColor = secondary ? CorralAestheticTokens.textSecondary : CorralAestheticTokens.text
        titleField.stringValue = title; titleField.lineBreakMode = .byTruncatingTail
        titleField.font = .systemFont(ofSize: 13, weight: secondary ? .regular : .semibold); titleField.textColor = secondary ? CorralAestheticTokens.textSecondary : CorralAestheticTokens.text
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        check.image = CorralLegacyIcon.image(.check, size: 14); check.contentTintColor = CorralAestheticTokens.text; check.isHidden = true
        titleRow.orientation = .horizontal; titleRow.alignment = .centerY; titleRow.spacing = 6; titleRow.addArrangedSubview(titleField)
        textStack.orientation = .vertical; textStack.alignment = .leading; textStack.spacing = 2; textStack.addArrangedSubview(titleRow)
        textStack.setHuggingPriority(.init(1), for: .horizontal)
        trailing.orientation = .horizontal; trailing.alignment = .centerY; trailing.spacing = 3; trailing.addArrangedSubview(check)
        let row = NSStackView(views: [iconView, textStack, trailing]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10; row.distribution = .fill
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12); row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor), row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor), iconView.widthAnchor.constraint(equalToConstant: 16)])
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { nil }
    func addTrailing(_ view: NSView) { trailing.insertArrangedSubview(view, at: 0) }
    public override func accessibilityPerformPress() -> Bool { onPress?(); return onPress != nil }
    public override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() } }
    public override func mouseDown(with event: NSEvent) {}
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }
    public override func mouseEntered(with event: NSEvent) { isHovered = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false }
}

@MainActor
private final class DeviceManagementRowView: NSView {
    let nameField = DeviceNameTextField(labelWithString: "")
    var onSelection: ((DeviceID, Bool) -> Void)?
    var onRename: ((DeviceID) -> Void)?
    var onSave: ((DeviceID, String) -> Void)?
    var onCancelRename: ((DeviceID) -> Void)?
    var onRequestDelete: ((DeviceID) -> Void)?
    var onConfirmDelete: ((DeviceID) -> Void)?
    var onCancelDelete: ((DeviceID) -> Void)?

    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "", target: nil, action: nil)
    private let deviceID: DeviceID
    private let editing: Bool
    private let confirmingDelete: Bool
    private let selected: Bool
    private let actions = NSStackView()
    private let persistentActions: Bool

    init(record: DeviceRecord, editing: Bool, confirmingDelete: Bool, deleting: Bool, selected: Bool, online: Bool) {
        deviceID = record.id
        self.editing = editing
        self.confirmingDelete = confirmingDelete
        self.selected = selected
        persistentActions = editing || confirmingDelete || deleting
        super.init(frame: .zero)

        nameField.deviceID = record.id
        nameField.stringValue = record.name
        nameField.isEditable = editing
        nameField.isSelectable = editing
        nameField.isBordered = editing
        nameField.drawsBackground = editing
        nameField.backgroundColor = CorralAestheticTokens.fieldBackground
        nameField.textColor = CorralAestheticTokens.text
        nameField.font = .systemFont(ofSize: 13, weight: .semibold)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let dot = CorralStatusIndicatorView(); dot.status = online ? .working : .offline; dot.fillsIdle = false
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true; dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        dot.setAccessibilityLabel(online ? "在线" : "离线")
        let sub = NSTextField(labelWithString: "\(record.endpoint.host):\(record.endpoint.port) · WebSocket")
        sub.font = .systemFont(ofSize: 11); sub.textColor = CorralAestheticTokens.textMuted; sub.lineBreakMode = .byTruncatingTail
        let titleRow = NSStackView(views: [nameField, dot]); titleRow.orientation = .horizontal; titleRow.alignment = .centerY; titleRow.spacing = 6
        let text = NSStackView(views: [titleRow, sub]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        text.setHuggingPriority(.init(1), for: .horizontal)
        let icon = NSImageView(image: CorralLegacyIcon.image(.monitor, size: 16) ?? NSImage()); icon.contentTintColor = CorralAestheticTokens.text

        for button in [primaryButton, secondaryButton] {
            button.isBordered = false; button.font = .systemFont(ofSize: 11); button.target = self
        }
        primaryButton.action = #selector(primaryAction); secondaryButton.action = #selector(secondaryAction)
        primaryButton.contentTintColor = confirmingDelete ? CorralAestheticTokens.danger : CorralAestheticTokens.text
        secondaryButton.contentTintColor = CorralAestheticTokens.textSecondary
        if deleting {
            primaryButton.title = "删除中…"; primaryButton.isEnabled = false; secondaryButton.isHidden = true
        } else if confirmingDelete {
            primaryButton.title = "确认删除"; secondaryButton.title = "取消"
        } else if editing {
            primaryButton.title = "保存"; secondaryButton.title = "取消"
        } else {
            // `.dp-action-btn`: 22px icon buttons revealed on hover.
            primaryButton.title = "重命名"; primaryButton.image = CorralLegacyIcon.image(.edit, size: 13); primaryButton.imagePosition = .imageOnly
            secondaryButton.title = "删除"; secondaryButton.image = CorralLegacyIcon.image(.trash, size: 13); secondaryButton.imagePosition = .imageOnly
            secondaryButton.contentTintColor = CorralAestheticTokens.textMuted
            for button in [primaryButton, secondaryButton] { button.widthAnchor.constraint(equalToConstant: 22).isActive = true; button.heightAnchor.constraint(equalToConstant: 22).isActive = true }
        }
        primaryButton.setAccessibilityLabel("\(primaryButton.title) \(record.name)"); primaryButton.setAccessibilityIdentifier("corral.devices.primary")
        secondaryButton.setAccessibilityLabel("\(secondaryButton.title) \(record.name)"); secondaryButton.setAccessibilityIdentifier("corral.devices.secondary")
        actions.orientation = .horizontal; actions.alignment = .centerY; actions.spacing = 3
        actions.addArrangedSubview(primaryButton); actions.addArrangedSubview(secondaryButton)
        actions.alphaValue = persistentActions ? 1 : 0
        let check = NSImageView(image: CorralLegacyIcon.image(.check, size: 14) ?? NSImage()); check.contentTintColor = CorralAestheticTokens.text
        check.isHidden = !selected || persistentActions

        let row = NSStackView(views: [icon, text, actions, check])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10; row.distribution = .fill
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true; layer?.cornerRadius = 8
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), nameField.widthAnchor.constraint(lessThanOrEqualToConstant: 150)
        ])
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(record.name)
        setAccessibilityIdentifier("corral.devices.row"); setAccessibilitySelected(selected)
    }

    required init?(coder: NSCoder) { fatalError("DeviceManagementRowView is created programmatically") }

    override func accessibilityPerformPress() -> Bool { toggleSelection(); return true }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [primaryButton, secondaryButton].filter { !$0.isHidden && $0.isEnabled && !$0.title.isEmpty }.map { button in
            NSAccessibilityCustomAction(name: button.title) { [weak button] in button?.performClick(nil); return true }
        }
    }
    override func mouseUp(with event: NSEvent) { if !editing, bounds.contains(convert(event.locationInWindow, from: nil)) { toggleSelection() } }
    override func mouseDown(with event: NSEvent) { if editing { super.mouseDown(with: event) } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = CorralAestheticTokens.hoverSubtle.cgColor; actions.alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.clear.cgColor; actions.alphaValue = persistentActions ? 1 : 0 }

    private func toggleSelection() { onSelection?(deviceID, !selected) }

    @objc private func primaryAction() {
        if confirmingDelete { onConfirmDelete?(deviceID) }
        else if editing { onSave?(deviceID, nameField.stringValue) }
        else { onRename?(deviceID) }
    }

    @objc private func secondaryAction() {
        if confirmingDelete { onCancelDelete?(deviceID) }
        else if editing { onCancelRename?(deviceID) }
        else { onRequestDelete?(deviceID) }
    }
}
