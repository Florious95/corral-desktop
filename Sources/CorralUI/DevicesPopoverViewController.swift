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
    public var onDevicesChanged: (([DeviceRecord]) -> Void)?

    public let tableView = NSTableView()
    private let errorLabel = NSTextField(labelWithString: "")

    public init(repository: any DeviceRepositoryProtocol) {
        self.repository = repository
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 520, height: 380)
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

        let title = NSTextField(labelWithString: "Devices")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = CorralAestheticTokens.text
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = CorralAestheticTokens.danger
        errorLabel.isHidden = true

        let content = NSStackView(views: [title, scrollView, errorLabel])
        content.orientation = .vertical
        content.alignment = .width
        content.distribution = .fill
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        content.wantsLayer = true
        content.layer?.backgroundColor = CorralAestheticTokens.surface0.cgColor
        view = content
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        errorLabel.heightAnchor.constraint(equalToConstant: 16).isActive = true
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        Task { [weak self] in try? await self?.reloadDevices() }
    }

    public func reloadDevices() async throws {
        devices = try await repository.listDevices()
        tableView.reloadData()
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
            deleting: deletionInProgressDeviceID == record.id
        )
        rowView.nameField.delegate = self
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
            deletionConfirmationDeviceID = nil
            deletionInProgressDeviceID = nil
            tableView.reloadData()
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

    init(record: DeviceRecord, editing: Bool, confirmingDelete: Bool, deleting: Bool) {
        deviceID = record.id
        self.editing = editing
        self.confirmingDelete = confirmingDelete
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

        primaryButton.isBordered = false
        primaryButton.contentTintColor = confirmingDelete ? CorralAestheticTokens.danger : CorralAestheticTokens.text
        primaryButton.target = self
        primaryButton.action = #selector(primaryAction)
        secondaryButton.isBordered = false
        secondaryButton.contentTintColor = CorralAestheticTokens.textSecondary
        secondaryButton.target = self
        secondaryButton.action = #selector(secondaryAction)

        if deleting {
            primaryButton.title = "Deleting…"
            primaryButton.isEnabled = false
            secondaryButton.isHidden = true
        } else if confirmingDelete {
            primaryButton.title = "Confirm Delete"
            secondaryButton.title = "Cancel"
        } else if editing {
            primaryButton.title = "Save"
            secondaryButton.title = "Cancel"
        } else {
            primaryButton.title = "Rename"
            secondaryButton.title = "Delete"
        }

        let actions = NSStackView(views: [primaryButton, secondaryButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 4
        let row = NSStackView(views: [nameField, actions])
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
