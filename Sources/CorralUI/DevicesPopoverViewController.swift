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
    public let allDevicesButton = NSButton(checkboxWithTitle: "All Devices", target: nil, action: nil)
    public let connectionStatus = CorralStatusIndicatorView()
    public let selectionSummary = NSTextField(labelWithString: "未添加设备")
    private let errorLabel = NSTextField(labelWithString: "")

    public init(repository: any DeviceRepositoryProtocol) {
        self.repository = repository
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 520, height: 430)
    }

    public required init?(coder: NSCoder) {
        fatalError("DevicesPopoverViewController is created programmatically")
    }

    public override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("device-name"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 48
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let title = NSTextField(labelWithString: "设备")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = CorralAestheticTokens.text
        allDevicesButton.target = self; allDevicesButton.action = #selector(toggleAllDevices)
        allDevicesButton.font = .systemFont(ofSize: 11); allDevicesButton.contentTintColor = CorralAestheticTokens.textSecondary
        let toolbar = NSStackView(views: [title, NSView(), allDevicesButton]); toolbar.orientation = .horizontal; toolbar.alignment = .centerY; toolbar.spacing = 8
        let addButton = NSButton(title: "添加设备", target: self, action: #selector(addDevice)); addButton.bezelStyle = .rounded
        let pairButton = NSButton(title: "配对移动端", target: self, action: #selector(pairMobile)); pairButton.bezelStyle = .rounded
        let actions = NSStackView(views: [addButton, pairButton]); actions.orientation = .horizontal; actions.alignment = .centerY; actions.spacing = 8
        connectionStatus.status = .offline
        selectionSummary.font = .systemFont(ofSize: 10); selectionSummary.textColor = CorralAestheticTokens.textMuted
        let footer = NSStackView(views: [connectionStatus, selectionSummary, NSView(), actions]); footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 7
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = CorralAestheticTokens.danger
        errorLabel.isHidden = true

        let content = NSStackView(views: [toolbar, scrollView, footer, errorLabel])
        content.orientation = .vertical
        content.alignment = .width
        content.distribution = .fill
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        content.wantsLayer = true
        content.layer?.backgroundColor = CorralAestheticTokens.surface0.cgColor
        view = content
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        toolbar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        footer.heightAnchor.constraint(equalToConstant: 32).isActive = true
        errorLabel.heightAnchor.constraint(equalToConstant: 16).isActive = true
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
            selected: selectedDeviceIDs.contains(record.id)
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
        connectionStatus.status = readyDeviceIDs.isEmpty ? .offline : .working
    }

    public func setDevice(_ id: DeviceID, selected: Bool) {
        if selected { selectedDeviceIDs.insert(id) } else { selectedDeviceIDs.remove(id) }
        tableView.reloadData(); updateSelectionSummary()
        onSelectionChanged?(selectedDeviceIDs)
    }

    private func updateSelectionSummary() {
        let names = devices.filter { selectedDeviceIDs.contains($0.id) }.map(\.name)
        selectionSummary.stringValue = devices.isEmpty ? "未添加设备" : names.isEmpty ? "未勾选设备" : names.count == devices.count ? "全部设备" : names.joined(separator: " · ")
        allDevicesButton.state = names.isEmpty ? .off : names.count == devices.count ? .on : .mixed
        connectionStatus.status = readyDeviceIDs.isEmpty ? .offline : .working
    }

    @objc private func toggleAllDevices() { selectedDeviceIDs = allDevicesButton.state == .on ? Set(devices.map(\.id)) : []; tableView.reloadData(); updateSelectionSummary(); onSelectionChanged?(selectedDeviceIDs) }
    @objc private func addDevice() { onAddDevice?() }
    @objc private func pairMobile() { onPairMobile?() }

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

    private let selectionButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "", target: nil, action: nil)
    private let deviceID: DeviceID
    private let editing: Bool
    private let confirmingDelete: Bool
    private let selected: Bool

    init(record: DeviceRecord, editing: Bool, confirmingDelete: Bool, deleting: Bool, selected: Bool) {
        deviceID = record.id
        self.editing = editing
        self.confirmingDelete = confirmingDelete
        self.selected = selected
        super.init(frame: .zero)

        nameField.deviceID = record.id
        nameField.stringValue = record.name
        nameField.isEditable = editing
        nameField.isSelectable = editing
        nameField.isBordered = editing
        nameField.drawsBackground = editing
        nameField.backgroundColor = CorralAestheticTokens.surface1
        nameField.textColor = CorralAestheticTokens.text
        nameField.font = .systemFont(ofSize: 12)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.translatesAutoresizingMaskIntoConstraints = false

        selectionButton.state = selected ? .on : .off
        selectionButton.target = self; selectionButton.action = #selector(toggleSelection)
        primaryButton.isBordered = false
        primaryButton.contentTintColor = confirmingDelete ? CorralAestheticTokens.danger : CorralAestheticTokens.text
        primaryButton.target = self
        primaryButton.action = #selector(primaryAction)
        secondaryButton.isBordered = false
        secondaryButton.contentTintColor = CorralAestheticTokens.textSecondary
        secondaryButton.target = self
        secondaryButton.action = #selector(secondaryAction)

        if deleting {
            primaryButton.title = "删除中…"
            primaryButton.isEnabled = false
            secondaryButton.isHidden = true
        } else if confirmingDelete {
            primaryButton.title = "确认删除"
            secondaryButton.title = "取消"
        } else if editing {
            primaryButton.title = "保存"
            secondaryButton.title = "取消"
        } else {
            primaryButton.title = "重命名"
            secondaryButton.title = "删除"
        }

        let actions = NSStackView(views: [primaryButton, secondaryButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 4
        let row = NSStackView(views: [selectionButton, nameField, actions])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            primaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
            secondaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
            heightAnchor.constraint(equalToConstant: 46)
        ])
    }

    required init?(coder: NSCoder) { fatalError("DeviceManagementRowView is created programmatically") }

    @objc private func toggleSelection() { onSelection?(deviceID, selectionButton.state == .on) }

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
