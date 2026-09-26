import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CorralContracts

@MainActor
private final class CorralDialogOverlayView: NSVisualEffectView {
    var onOutsideClick: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow; blendingMode = .withinWindow; state = .active
        wantsLayer = true; layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
    }
    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) { onOutsideClick?() }
}

public struct CorralAgentLauncher: Equatable, Sendable {
    public let provider: String
    public let displayName: String
    public let supportsBypass: Bool
    public init(provider: String, displayName: String, supportsBypass: Bool) {
        self.provider = provider; self.displayName = displayName; self.supportsBypass = supportsBypass
    }
}

public struct CorralNewAgentRequest: Equatable, Sendable {
    public let name: String
    public let provider: String
    public let bypass: Bool
    public init(name: String, provider: String, bypass: Bool) { self.name = name; self.provider = provider; self.bypass = bypass }
}

public struct CorralSettingsValues: Equatable, Sendable {
    public var theme: CorralThemeMode
    public var fontFamily: String
    public var fontSize: Double
    public var directoryTracking: Bool
    public init(theme: CorralThemeMode = .system, fontFamily: String = "Cascadia Code, Consolas, Fira Code, JetBrains Mono, Menlo, Monaco, monospace", fontSize: Double = 13, directoryTracking: Bool = false) {
        self.theme = theme; self.fontFamily = fontFamily; self.fontSize = min(24, max(10, fontSize)); self.directoryTracking = directoryTracking
    }
}

@MainActor
open class CorralDialogViewController: NSViewController {
    public private(set) weak var presentedWindow: NSWindow?
    public private(set) var focusTraversalCount = 0
    private var overlayView: CorralDialogOverlayView?
    private weak var previousFirstResponder: NSResponder?
    private var eventMonitor: Any?
    open var canDismissWithEscape: Bool { true }
    open var initialFirstResponder: NSView? { focusableControls(in: view).first }

    public init() { super.init(nibName: nil, bundle: nil) }
    public required init?(coder: NSCoder) { nil }

    public func present(over window: NSWindow? = NSApp.keyWindow) {
        guard let window, let container = window.contentView else { return }
        loadViewIfNeeded()
        previousFirstResponder = window.firstResponder
        let overlay = CorralDialogOverlayView(frame: container.bounds)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.onOutsideClick = { [weak self] in guard let self, self.canDismissWithEscape else { return }; self.handleEscape() }
        overlay.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.centerXAnchor.constraint(equalTo: overlay.centerXAnchor), view.centerYAnchor.constraint(equalTo: overlay.centerYAnchor), view.widthAnchor.constraint(equalToConstant: view.frame.width), view.heightAnchor.constraint(equalToConstant: view.frame.height)])
        container.addSubview(overlay)
        NSLayoutConstraint.activate([overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor), overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor), overlay.topAnchor.constraint(equalTo: container.topAnchor), overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        overlayView = overlay; presentedWindow = window; window.makeFirstResponder(initialFirstResponder)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.presentedWindow?.isKeyWindow == true else { return event }
            if event.keyCode == 53, self.canDismissWithEscape { self.handleEscape(); return nil }
            if event.keyCode == 48 { self.cycleFocus(backward: event.modifierFlags.contains(.shift)); return nil }
            if event.keyCode == 9, event.modifierFlags.contains(.command), let text = NSPasteboard.general.string(forType: .string), self.handlePaste(text) { return nil }
            return event
        }
    }

    open func handleEscape() { dismiss() }
    open func handlePaste(_ text: String) -> Bool { false }

    private func cycleFocus(backward: Bool) {
        guard let window = presentedWindow else { return }
        let controls = focusableControls(in: view)
        guard !controls.isEmpty else { return }
        let current = window.firstResponder as? NSView
        let currentOwner = (current as? NSTextView)?.delegate as? NSView ?? current
        let index = controls.firstIndex { $0 === currentOwner } ?? (backward ? 0 : -1)
        let next = (index + (backward ? -1 : 1) + controls.count) % controls.count
        window.makeFirstResponder(controls[next])
        focusTraversalCount += 1
    }

    private func focusableControls(in root: NSView) -> [NSView] {
        var found: [NSView] = []
        func visit(_ view: NSView) {
            if let control = view as? NSControl, control.isEnabled, !control.isHidden, control.acceptsFirstResponder { found.append(control) }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found
    }

    public func closeDialog() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        overlayView?.removeFromSuperview(); overlayView = nil
        if let previousView = previousFirstResponder as? NSView, previousView.window === presentedWindow { _ = presentedWindow?.makeFirstResponder(previousView) }
        previousFirstResponder = nil; presentedWindow = nil
    }

    public func rootView(size: NSSize) -> NSView {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true; root.layer?.backgroundColor = CorralAestheticTokens.surface1.cgColor; root.layer?.cornerRadius = 14
        return root
    }

    public func addHeader(to root: NSView, title: String, subtitle: String? = nil, top: CGFloat = 26) -> CGFloat {
        let titleLabel = NSTextField(labelWithString: title); titleLabel.font = .systemFont(ofSize: 16, weight: .semibold); titleLabel.textColor = CorralAestheticTokens.text; titleLabel.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(titleLabel)
        NSLayoutConstraint.activate([titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: top)])
        guard let subtitle else { return top + 28 }
        let sub = NSTextField(labelWithString: subtitle); sub.font = .systemFont(ofSize: 11); sub.textColor = CorralAestheticTokens.textMuted; sub.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(sub)
        NSLayoutConstraint.activate([sub.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor), sub.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor), sub.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5)])
        return top + 47
    }

    public func addLabel(_ text: String, to root: NSView, x: CGFloat = 24, y: CGFloat, width: CGFloat = 400) -> NSTextField {
        let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 11, weight: .medium); label.textColor = CorralAestheticTokens.textSecondary; label.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: x), label.topAnchor.constraint(equalTo: root.topAnchor, constant: y), label.widthAnchor.constraint(lessThanOrEqualToConstant: width)])
        return label
    }

    public func addTextField(to root: NSView, placeholder: String, y: CGFloat, secure: Bool = false) -> NSTextField {
        let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
        field.placeholderString = placeholder; field.font = .systemFont(ofSize: 12); field.textColor = CorralAestheticTokens.text; field.backgroundColor = CorralAestheticTokens.surface0; field.isBezeled = true; field.bezelStyle = .roundedBezel; field.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(field)
        NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), field.topAnchor.constraint(equalTo: root.topAnchor, constant: y), field.heightAnchor.constraint(equalToConstant: 32)])
        return field
    }

    @discardableResult public func addActionButtons(to root: NSView, cancel: Selector, primary: Selector, primaryTitle: String = "完成", primaryEnabled: Bool = true) -> (cancel: NSButton, primary: NSButton) {
        let cancelButton = NSButton(title: "取消", target: self, action: cancel); cancelButton.bezelStyle = .rounded; cancelButton.translatesAutoresizingMaskIntoConstraints = false
        let primaryButton = NSButton(title: primaryTitle, target: self, action: primary); primaryButton.bezelStyle = .rounded; primaryButton.keyEquivalent = "\r"; primaryButton.isEnabled = primaryEnabled; primaryButton.translatesAutoresizingMaskIntoConstraints = false
        stylePrimary(primaryButton)
        root.addSubview(cancelButton); root.addSubview(primaryButton)
        NSLayoutConstraint.activate([cancelButton.trailingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: -8), cancelButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20), cancelButton.widthAnchor.constraint(equalToConstant: 74), primaryButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), primaryButton.bottomAnchor.constraint(equalTo: cancelButton.bottomAnchor), primaryButton.widthAnchor.constraint(equalToConstant: 84)])
        return (cancelButton, primaryButton)
    }

    public func stylePrimary(_ button: NSButton) {
        button.contentTintColor = CorralAestheticTokens.background; button.wantsLayer = true; button.layer?.backgroundColor = CorralAestheticTokens.accent.cgColor; button.layer?.cornerRadius = 8; button.layer?.borderWidth = 0
    }

    public func dismiss() { closeDialog() }
}

@MainActor
public final class NewAgentDialogViewController: CorralDialogViewController, NSTextFieldDelegate {
    public required init?(coder: NSCoder) { nil }
    public override var initialFirstResponder: NSView? { nameField }
    public let spaceName: String
    public let launchers: [CorralAgentLauncher]
    public let nameField = NSTextField()
    public let bypassSwitch = NSSwitch()
    public private(set) var selectedProvider: String?
    public private(set) var validationMessage: String?
    public override var canDismissWithEscape: Bool { !isLoading }
    public var isLoading = false { didSet { updateControls() } }
    public var onCreate: ((CorralNewAgentRequest) -> Void)?
    public var onCancel: (() -> Void)?
    private let errorLabel = NSTextField(labelWithString: "")
    public private(set) weak var cancelButton: NSButton?
    public private(set) weak var createButton: NSButton?
    private let launcherStack = NSStackView()
    private var launcherButtons: [NSButton] = []

    public init(spaceName: String, launchers: [CorralAgentLauncher] = [], onCreate: ((CorralNewAgentRequest) -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        let advertised = launchers.isEmpty ? [
            CorralAgentLauncher(provider: "claude_code", displayName: "Claude Code", supportsBypass: true),
            CorralAgentLauncher(provider: "codex", displayName: "Codex", supportsBypass: true),
            CorralAgentLauncher(provider: "cursor", displayName: "Cursor", supportsBypass: false),
            CorralAgentLauncher(provider: "grok", displayName: "Grok", supportsBypass: false),
            CorralAgentLauncher(provider: "pi", displayName: "Pi", supportsBypass: true)
        ] : launchers
        self.spaceName = spaceName; self.launchers = advertised; self.onCreate = onCreate; self.onCancel = onCancel; selectedProvider = advertised.first?.provider
        super.init()
    }
    public override func loadView() {
        let root = rootView(size: NSSize(width: 420, height: 488)); view = root
        var y = addHeader(to: root, title: "新建 Agent", subtitle: "在「\(spaceName)」中创建")
        _ = addLabel("任务名称", to: root, y: y); y += 20
        nameField.placeholderString = "任务名称"; nameField.font = .systemFont(ofSize: 12); nameField.textColor = CorralAestheticTokens.text; nameField.backgroundColor = CorralAestheticTokens.surface0; nameField.isBezeled = true; nameField.bezelStyle = .roundedBezel; nameField.delegate = self; nameField.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(nameField)
        NSLayoutConstraint.activate([nameField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), nameField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), nameField.topAnchor.constraint(equalTo: root.topAnchor, constant: y), nameField.heightAnchor.constraint(equalToConstant: 32)])
        y += 49
        _ = addLabel("选择 Agent", to: root, y: y); y += 21
        launcherStack.orientation = .vertical; launcherStack.alignment = .width; launcherStack.distribution = .fillEqually; launcherStack.spacing = 8; launcherStack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(launcherStack)
        for start in stride(from: 0, to: launchers.count, by: 4) {
            let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.distribution = .fillEqually; row.spacing = 8
            for launcher in launchers[start..<min(start + 4, launchers.count)] {
                let button = NSButton(title: launcher.displayName, target: self, action: #selector(selectLauncher(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(launcher.provider); button.setButtonType(.pushOnPushOff); button.bezelStyle = .rounded
                button.image = CorralProviderIconView(provider: launcher.provider, size: 18, active: true).image
                button.imagePosition = .imageAbove; button.imageScaling = .scaleProportionallyDown; button.tag = launcher.supportsBypass ? 1 : 0
                button.toolTip = launcher.displayName; button.heightAnchor.constraint(equalToConstant: 62).isActive = true
                row.addArrangedSubview(button); launcherButtons.append(button)
            }
            for _ in row.arrangedSubviews.count..<4 { row.addArrangedSubview(NSView()) }
            launcherStack.addArrangedSubview(row)
        }
        let rows = max(1, (launchers.count + 3) / 4)
        NSLayoutConstraint.activate([launcherStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), launcherStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), launcherStack.topAnchor.constraint(equalTo: root.topAnchor, constant: y), launcherStack.heightAnchor.constraint(equalToConstant: CGFloat(rows * 62 + (rows - 1) * 8))])
        y += CGFloat(rows * 62 + (rows - 1) * 8 + 20)
        let bypassLabel = NSTextField(labelWithString: "Bypass permissions"); bypassLabel.font = .systemFont(ofSize: 12, weight: .medium); bypassLabel.textColor = CorralAestheticTokens.text; bypassLabel.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(bypassLabel)
        let description = NSTextField(labelWithString: "允许 Agent 不经确认执行 shell 命令"); description.font = .systemFont(ofSize: 10); description.textColor = CorralAestheticTokens.textMuted; description.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(description)
        bypassSwitch.target = self; bypassSwitch.action = #selector(toggleBypass); bypassSwitch.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(bypassSwitch)
        NSLayoutConstraint.activate([bypassLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), bypassLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: y), description.leadingAnchor.constraint(equalTo: bypassLabel.leadingAnchor), description.topAnchor.constraint(equalTo: bypassLabel.bottomAnchor, constant: 4), bypassSwitch.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), bypassSwitch.centerYAnchor.constraint(equalTo: bypassLabel.centerYAnchor)])
        y += 52
        errorLabel.textColor = CorralAestheticTokens.danger; errorLabel.font = .systemFont(ofSize: 10); errorLabel.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(errorLabel); errorLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: y).isActive = true; errorLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24).isActive = true
        let buttons = addActionButtons(to: root, cancel: #selector(cancel), primary: #selector(create), primaryTitle: "创建")
        cancelButton = buttons.cancel; createButton = buttons.primary
        updateControls()
    }
    public var isCreateEnabled: Bool { validationMessage == nil && !nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedLauncher != nil && !isLoading }
    public func submit() {
        validateName(); guard isCreateEnabled, let launcher = selectedLauncher else { return }
        onCreate?(CorralNewAgentRequest(name: nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), provider: launcher.provider, bypass: launcher.supportsBypass && bypassSwitch.state == .on))
    }
    private var selectedLauncher: CorralAgentLauncher? { launchers.first { $0.provider == selectedProvider } }
    public func controlTextDidChange(_ notification: Notification) { validateName(); updateControls() }
    @objc private func selectLauncher(_ sender: NSButton) { selectedProvider = sender.identifier?.rawValue; if sender.tag == 0 { bypassSwitch.state = .off }; updateControls() }
    @objc private func toggleBypass() { updateControls() }
    public override func handleEscape() { guard !isLoading else { return }; onCancel?(); dismiss() }
    @objc private func cancel() { guard !isLoading else { return }; onCancel?(); dismiss() }
    @objc private func create() { submit() }
    private func validateName() {
        let name = nameField.stringValue
        validationMessage = name.unicodeScalars.count > 64 ? "名称不能超过 64 个字符" : name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? "名称不能包含控制字符" : nil
        errorLabel.stringValue = validationMessage ?? ""
    }
    private func updateControls() {
        guard isViewLoaded else { return }
        bypassSwitch.isEnabled = !isLoading && selectedLauncher?.supportsBypass == true
        for button in launcherButtons { button.isEnabled = !isLoading; button.state = button.identifier?.rawValue == selectedProvider ? .on : .off }
        nameField.isEnabled = !isLoading
        cancelButton?.isEnabled = !isLoading
        createButton?.isEnabled = isCreateEnabled
        createButton?.title = isLoading ? "创建中…" : "创建"
    }
    private func providerSymbol(_ provider: String) -> String { switch provider.lowercased() { case "claude": "sparkle"; case "codex": "chevron.left.forwardslash.chevron.right"; case "pi": "p.circle"; default: "terminal" } }
}

@MainActor
public final class SettingsDialogViewController: CorralDialogViewController {
    public required init?(coder: NSCoder) { nil }
    public private(set) var values: CorralSettingsValues
    public var onChange: ((CorralSettingsValues) -> Void)?
    public var onClose: (() -> Void)?
    public let themeControl = NSSegmentedControl(labels: ["浅色", "深色", "跟随系统"], trackingMode: .selectOne, target: nil, action: nil)
    public let fontFamilyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    public let fontSizeSlider = NSSlider(value: 13, minValue: 10, maxValue: 24, target: nil, action: nil)
    public let fontSizeField = NSTextField(string: "13")
    public let fontSizeStepper = NSStepper()
    public let directoryTrackingSwitch = NSSwitch()
    public private(set) var fontPreviewLabel: NSTextField?
    private let fonts = ["Cascadia Code, Consolas", "JetBrains Mono, \"Andale Mono\", Menlo, \"Lucida Console\"", "Fira Code, Monaco, \"Courier New\"", "Menlo, \"Segoe UI Mono\"", "Consolas, \"Andale Mono\"", "Courier New"]

    public init(values: CorralSettingsValues = CorralSettingsValues(), onChange: ((CorralSettingsValues) -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.values = values; self.onChange = onChange; self.onClose = onClose; super.init()
    }
    public override func loadView() {
        let root = rootView(size: NSSize(width: 500, height: 510)); view = root
        _ = addHeader(to: root, title: "设置", subtitle: "修改即时保存")
        _ = addLabel("主题", to: root, y: 87)
        themeControl.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(themeControl)
        NSLayoutConstraint.activate([themeControl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), themeControl.topAnchor.constraint(equalTo: root.topAnchor, constant: 108), themeControl.widthAnchor.constraint(equalToConstant: 270), themeControl.heightAnchor.constraint(equalToConstant: 28)])
        themeControl.target = self; themeControl.action = #selector(themeChanged); themeControl.selectedSegment = CorralThemeMode.allCases.firstIndex(of: values.theme) ?? 2
        _ = addLabel("终端字体", to: root, y: 154)
        fonts.forEach { fontFamilyPopup.addItem(withTitle: $0) }; fontFamilyPopup.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(fontFamilyPopup)
        NSLayoutConstraint.activate([fontFamilyPopup.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), fontFamilyPopup.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), fontFamilyPopup.topAnchor.constraint(equalTo: root.topAnchor, constant: 175), fontFamilyPopup.heightAnchor.constraint(equalToConstant: 28)])
        fontFamilyPopup.selectItem(withTitle: fonts.first(where: { values.fontFamily.hasPrefix($0.components(separatedBy: ",").first ?? $0) }) ?? fonts[0]); fontFamilyPopup.target = self; fontFamilyPopup.action = #selector(fontChanged)
        _ = addLabel("字号", to: root, y: 222)
        fontSizeSlider.doubleValue = values.fontSize; fontSizeSlider.numberOfTickMarks = 15; fontSizeSlider.allowsTickMarkValuesOnly = true; fontSizeSlider.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(fontSizeSlider); fontSizeSlider.target = self; fontSizeSlider.action = #selector(sizeChanged)
        fontSizeField.stringValue = String(values.fontSize); fontSizeField.alignment = .right; fontSizeField.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(fontSizeField); fontSizeField.target = self; fontSizeField.action = #selector(sizeFieldChanged)
        fontSizeStepper.minValue = 10; fontSizeStepper.maxValue = 24; fontSizeStepper.increment = 1; fontSizeStepper.doubleValue = values.fontSize; fontSizeStepper.target = self; fontSizeStepper.action = #selector(sizeStepperChanged); fontSizeStepper.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(fontSizeStepper)
        NSLayoutConstraint.activate([fontSizeSlider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), fontSizeSlider.trailingAnchor.constraint(equalTo: fontSizeField.leadingAnchor, constant: -10), fontSizeSlider.topAnchor.constraint(equalTo: root.topAnchor, constant: 244), fontSizeField.trailingAnchor.constraint(equalTo: fontSizeStepper.leadingAnchor, constant: -5), fontSizeField.centerYAnchor.constraint(equalTo: fontSizeSlider.centerYAnchor), fontSizeField.widthAnchor.constraint(equalToConstant: 42), fontSizeStepper.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18), fontSizeStepper.centerYAnchor.constraint(equalTo: fontSizeSlider.centerYAnchor)])
        let preview = NSTextField(labelWithString: "The quick brown fox · 终端预览"); preview.textColor = CorralAestheticTokens.text; preview.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(preview); fontPreviewLabel = preview; updatePreviewFont()
        NSLayoutConstraint.activate([preview.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), preview.topAnchor.constraint(equalTo: root.topAnchor, constant: 278), preview.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), preview.heightAnchor.constraint(equalToConstant: 42)])
        _ = addLabel("目录跟踪", to: root, y: 346)
        let trackingLabel = NSTextField(labelWithString: "根据终端目录变化更新工作区路径"); trackingLabel.font = .systemFont(ofSize: 11); trackingLabel.textColor = CorralAestheticTokens.textSecondary; trackingLabel.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(trackingLabel)
        directoryTrackingSwitch.state = values.directoryTracking ? .on : .off; directoryTrackingSwitch.target = self; directoryTrackingSwitch.action = #selector(trackingChanged); directoryTrackingSwitch.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(directoryTrackingSwitch)
        NSLayoutConstraint.activate([trackingLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), trackingLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 368), directoryTrackingSwitch.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), directoryTrackingSwitch.centerYAnchor.constraint(equalTo: trackingLabel.centerYAnchor)])
        let done = NSButton(title: "完成", target: self, action: #selector(close)); done.bezelStyle = .rounded; done.keyEquivalent = "\r"; done.translatesAutoresizingMaskIntoConstraints = false; stylePrimary(done); root.addSubview(done)
        NSLayoutConstraint.activate([done.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), done.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20), done.widthAnchor.constraint(equalToConstant: 84)])
        let saved = NSTextField(labelWithString: "✓  修改即时保存"); saved.font = .systemFont(ofSize: 10); saved.textColor = CorralAestheticTokens.success; saved.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(saved)
        NSLayoutConstraint.activate([saved.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), saved.centerYAnchor.constraint(equalTo: done.centerYAnchor)])
    }
    public func setTheme(_ theme: CorralThemeMode) { values.theme = theme; themeControl.selectedSegment = CorralThemeMode.allCases.firstIndex(of: theme) ?? 2; apply() }
    public func setFontFamily(_ family: String) { values.fontFamily = family; if fonts.contains(family) { fontFamilyPopup.selectItem(withTitle: family) }; updatePreviewFont(); apply() }
    public func setFontSize(_ size: Double) { values.fontSize = min(24, max(10, size)); updateFontSizeControls(); apply() }
    public func setDirectoryTracking(_ enabled: Bool) { values.directoryTracking = enabled; directoryTrackingSwitch.state = enabled ? .on : .off; apply() }
    @objc private func themeChanged() { values.theme = CorralThemeMode.allCases[themeControl.selectedSegment]; apply() }
    @objc private func fontChanged() { values.fontFamily = fontFamilyPopup.titleOfSelectedItem ?? fonts[0]; updatePreviewFont(); apply() }
    @objc private func sizeChanged() { values.fontSize = min(24, max(10, fontSizeSlider.doubleValue)); updateFontSizeControls(); apply() }
    @objc private func sizeFieldChanged() { values.fontSize = min(24, max(10, Double(fontSizeField.stringValue) ?? 13)); updateFontSizeControls(); apply() }
    @objc private func sizeStepperChanged() { values.fontSize = min(24, max(10, fontSizeStepper.doubleValue)); updateFontSizeControls(); apply() }
    private func updateFontSizeControls() { fontSizeSlider.doubleValue = values.fontSize; fontSizeStepper.doubleValue = values.fontSize; fontSizeField.stringValue = String(values.fontSize); updatePreviewFont() }
    private func updatePreviewFont() {
        let selectedFamily = fontFamilyPopup.titleOfSelectedItem ?? fonts[0]
        let preferredName = selectedFamily.split(separator: ",", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) ?? selectedFamily
        fontPreviewLabel?.font = NSFont(name: preferredName, size: CGFloat(values.fontSize)) ?? .monospacedSystemFont(ofSize: values.fontSize, weight: .regular)
    }
    @objc private func trackingChanged() { values.directoryTracking = directoryTrackingSwitch.state == .on; apply() }
    public override func handleEscape() { onClose?(); dismiss() }
    @objc private func close() { onClose?(); dismiss() }
    private func apply() { CorralAestheticTokens.themeMode = values.theme; onChange?(values) }
}

@MainActor
public final class ToastView: NSView {
    public enum Kind: String, Sendable { case info, success, warning, error }
    public let messageLabel = NSTextField(labelWithString: "")
    public init(message: String, kind: Kind = .info) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 44)); wantsLayer = true; layer?.cornerRadius = 8; layer?.backgroundColor = CorralAestheticTokens.surface2.cgColor; layer?.borderColor = CorralAestheticTokens.border.cgColor; layer?.borderWidth = 1
        let color: NSColor = switch kind { case .info: CorralAestheticTokens.text; case .success: CorralAestheticTokens.success; case .warning: CorralAestheticTokens.warning; case .error: CorralAestheticTokens.danger }
        messageLabel.stringValue = message; messageLabel.textColor = color; messageLabel.font = .systemFont(ofSize: 12); messageLabel.lineBreakMode = .byTruncatingTail; messageLabel.translatesAutoresizingMaskIntoConstraints = false; addSubview(messageLabel)
        NSLayoutConstraint.activate([messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    public required init?(coder: NSCoder) { nil }
}

@MainActor
public final class ToastManager {
    public static let shared = ToastManager()
    public private(set) var currentToast: ToastView?
    private var dismissal: DispatchWorkItem?
    public var duration: TimeInterval = 2.5
    private init() {}
    public func show(_ message: String, kind: ToastView.Kind = .info, in host: NSView? = nil) {
        dismissal?.cancel(); currentToast?.removeFromSuperview()
        let toast = ToastView(message: message, kind: kind); currentToast = toast
        if let host {
            toast.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(toast)
            NSLayoutConstraint.activate([toast.centerXAnchor.constraint(equalTo: host.centerXAnchor), toast.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -22), toast.widthAnchor.constraint(greaterThanOrEqualToConstant: 280), toast.widthAnchor.constraint(lessThanOrEqualToConstant: 420), toast.heightAnchor.constraint(equalToConstant: 44)])
        }
        let work = DispatchWorkItem { [weak self, weak toast] in toast?.removeFromSuperview(); if self?.currentToast === toast { self?.currentToast = nil } }
        dismissal = work; DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
    public func dismissCurrent() { dismissal?.cancel(); currentToast?.removeFromSuperview(); currentToast = nil }
}

public struct CorralAddDeviceRequest: Equatable, Sendable {
    public let name: String
    public let url: String
    public let token: String
    public let candidates: [String]
    public init(name: String, url: String, token: String, candidates: [String] = []) { self.name = name; self.url = url; self.token = token; self.candidates = candidates }
}

@MainActor
public final class AddDeviceDialogViewController: CorralDialogViewController {
    public required init?(coder: NSCoder) { nil }
    public override var initialFirstResponder: NSView? { addressField }
    public let nameField = NSTextField()
    public let addressField = NSTextField()
    public let tokenField = NSSecureTextField()
    public private(set) var candidates: [String] = []
    public private(set) var validationMessage: String?
    public var onSubmit: ((CorralAddDeviceRequest) -> Void)?
    public var onCancel: (() -> Void)?
    private let errorLabel = NSTextField(labelWithString: "")
    public init(onSubmit: ((CorralAddDeviceRequest) -> Void)? = nil, onCancel: (() -> Void)? = nil) { self.onSubmit = onSubmit; self.onCancel = onCancel; super.init() }
    public override func loadView() {
        let root = rootView(size: NSSize(width: 460, height: 430)); view = root
        _ = addHeader(to: root, title: "添加设备", subtitle: "填写 agentmirrord 打印的地址与配对 Token")
        _ = addLabel("显示名称（可选）", to: root, y: 86); nameField.placeholderString = "Mac Studio @ Home"; style(nameField); place(nameField, in: root, y: 107)
        _ = addLabel("WebSocket 地址", to: root, y: 147); addressField.placeholderString = "ws://192.168.31.116:9900/ws"; style(addressField); place(addressField, in: root, y: 168)
        _ = addLabel("配对 Token", to: root, y: 208); tokenField.placeholderString = "粘贴配对 Token"; style(tokenField); place(tokenField, in: root, y: 229)
        let hint = NSTextField(labelWithString: "粘贴配对二维码里的 JSON 可自动填充"); hint.font = .systemFont(ofSize: 10); hint.textColor = CorralAestheticTokens.textMuted; hint.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(hint); hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24).isActive = true; hint.topAnchor.constraint(equalTo: tokenField.bottomAnchor, constant: 8).isActive = true
        errorLabel.font = .systemFont(ofSize: 10); errorLabel.textColor = CorralAestheticTokens.danger; errorLabel.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(errorLabel); errorLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24).isActive = true; errorLabel.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 6).isActive = true
        addActionButtons(to: root, cancel: #selector(cancel), primary: #selector(submit), primaryTitle: "添加")
        root.registerForDraggedTypes([.string])
    }
    public override func handlePaste(_ text: String) -> Bool { acceptPairingJSON(text) }
    public func acceptPairingJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8), let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let url = payload["url"] as? String { addressField.stringValue = url }
        if let token = payload["token"] as? String { tokenField.stringValue = token }
        if let name = payload["name"] as? String { nameField.stringValue = name }
        candidates = payload["candidates"] as? [String] ?? []
        validate(); return true
    }
    @objc public func submit() {
        validate(); guard validationMessage == nil else { errorLabel.stringValue = validationMessage ?? ""; return }
        let url = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultName = URL(string: url)?.host ?? url
        onSubmit?(CorralAddDeviceRequest(name: nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultName : nameField.stringValue, url: url, token: tokenField.stringValue, candidates: candidates))
    }
    public override func handleEscape() { onCancel?(); dismiss() }
    @objc private func cancel() { onCancel?(); dismiss() }
    private func validate() {
        let url = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        validationMessage = url.hasPrefix("ws://") || url.hasPrefix("wss://") ? nil : "地址必须以 ws:// 或 wss:// 开头"
        if isViewLoaded { errorLabel.stringValue = validationMessage ?? "" }
    }
    private func style(_ field: NSTextField) { field.font = .systemFont(ofSize: 12); field.textColor = CorralAestheticTokens.text; field.backgroundColor = CorralAestheticTokens.surface0; field.isBezeled = true; field.bezelStyle = .roundedBezel; field.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(field) }
    private func place(_ field: NSTextField, in root: NSView, y: CGFloat) { NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), field.topAnchor.constraint(equalTo: root.topAnchor, constant: y), field.heightAnchor.constraint(equalToConstant: 32)]) }
}

public struct CorralPairingPayload: Equatable, Sendable {
    public let url: String
    public let token: String
    public let name: String?
    public let candidates: [String]
    public let hostID: String?
    public init(url: String, token: String = "", name: String? = nil, candidates: [String] = [], hostID: String? = nil) { self.url = url; self.token = token; self.name = name; self.candidates = candidates; self.hostID = hostID }
}

@MainActor
public final class PairingDialogViewController: CorralDialogViewController {
    public required init?(coder: NSCoder) { nil }
    public override var initialFirstResponder: NSView? { payload.token.isEmpty ? tokenField : (isLoopback(payload.url) ? hostField : copyButton) }
    public let tokenField = NSSecureTextField()
    public let hostField = NSTextField()
    public override var canDismissWithEscape: Bool { true }
    public private(set) var qrImage: NSImage?
    public private(set) var pairingText: String?
    public var payload: CorralPairingPayload
    public var onCopied: ((String) -> Void)?
    public var onSaveToken: ((String) -> Void)?
    public var onCancel: (() -> Void)?
    private let imageView = NSImageView()
    private let copyButton = NSButton(title: "复制配对链接 / Token", target: nil, action: nil)
    public init(payload: CorralPairingPayload, onCopied: ((String) -> Void)? = nil, onSaveToken: ((String) -> Void)? = nil, onCancel: (() -> Void)? = nil) { self.payload = payload; self.onCopied = onCopied; self.onSaveToken = onSaveToken; self.onCancel = onCancel; super.init() }
    public override func loadView() {
        let root = rootView(size: NSSize(width: 380, height: 570)); view = root
        _ = addHeader(to: root, title: "配对移动端", subtitle: payload.hostID == nil ? "用手机扫描二维码，即可连接这台 Mac" : "局域网已开启广播，用手机 App 扫码快速连接")
        tokenField.placeholderString = "粘贴 agentmirrord 配对 Token"; tokenField.isBezeled = true; tokenField.bezelStyle = .roundedBezel; tokenField.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(tokenField)
        hostField.placeholderString = "192.168.1.23，可用逗号分隔多个地址"; hostField.isBezeled = true; hostField.bezelStyle = .roundedBezel; hostField.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(hostField)
        let local = isLoopback(payload.url) && payload.hostID == nil
        tokenField.isHidden = !payload.token.isEmpty; hostField.isHidden = !local
        imageView.imageScaling = .scaleProportionallyUpOrDown; imageView.wantsLayer = true; imageView.layer?.backgroundColor = NSColor.white.cgColor; imageView.translatesAutoresizingMaskIntoConstraints = false; imageView.wantsLayer = true; imageView.layer?.cornerRadius = 10; root.addSubview(imageView)
        let help = NSTextField(labelWithString: payload.hostID.map { "主机 ID: \($0.prefix(8))…" } ?? "打开 Corral 移动端，选择扫码连接并对准此二维码"); help.font = .systemFont(ofSize: 10); help.textColor = CorralAestheticTokens.textMuted; help.alignment = .center; help.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(help)
        copyButton.target = self; copyButton.action = #selector(copyPairing); copyButton.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(copyButton)
        let done = NSButton(title: "完成", target: self, action: #selector(cancel)); done.bezelStyle = .rounded; done.translatesAutoresizingMaskIntoConstraints = false; stylePrimary(done); root.addSubview(done)
        let credentialTop: NSLayoutYAxisAnchor = payload.token.isEmpty ? tokenField.bottomAnchor : root.topAnchor
        let qrTop: CGFloat = payload.token.isEmpty ? 18 : 88
        NSLayoutConstraint.activate([tokenField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), tokenField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), tokenField.topAnchor.constraint(equalTo: root.topAnchor, constant: 78), tokenField.heightAnchor.constraint(equalToConstant: 32), hostField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), hostField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), hostField.topAnchor.constraint(equalTo: root.topAnchor, constant: payload.token.isEmpty ? 118 : 78), hostField.heightAnchor.constraint(equalToConstant: 32), imageView.centerXAnchor.constraint(equalTo: root.centerXAnchor), imageView.topAnchor.constraint(equalTo: local ? hostField.bottomAnchor : credentialTop, constant: qrTop), imageView.widthAnchor.constraint(equalToConstant: 260), imageView.heightAnchor.constraint(equalToConstant: 260), help.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), help.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), help.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 10), copyButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), copyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22), done.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), done.bottomAnchor.constraint(equalTo: copyButton.bottomAnchor), done.widthAnchor.constraint(equalToConstant: 84)])
        tokenField.target = self; tokenField.action = #selector(credentialsChanged); hostField.target = self; hostField.action = #selector(credentialsChanged)
        updateQR()
    }
    public func updateQR(token: String? = nil, hosts: String? = nil) {
        let actualToken = token ?? (payload.token.isEmpty ? tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : payload.token)
        let suppliedHosts = (hosts ?? hostField.stringValue).split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        let local = isLoopback(payload.url) && payload.hostID == nil
        guard !actualToken.isEmpty, !local || !suppliedHosts.isEmpty else { qrImage = nil; imageView.image = nil; pairingText = nil; return }
        let candidates = local ? suppliedHosts.map { reachableURL(host: $0, baseURL: payload.url) } : payload.candidates
        let url = candidates.first ?? payload.url
        var payloadObject: [String: Any] = ["v": 1, "url": url, "token": actualToken, "candidates": candidates]
        if let name = payload.name { payloadObject["name"] = name }
        if let hostID = payload.hostID { payloadObject["host_id"] = hostID }
        guard let data = try? JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys]) else { qrImage = nil; imageView.image = nil; pairingText = nil; return }
        let text = String(data: data, encoding: .utf8) ?? ""
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage, let cg = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { return }
        qrImage = NSImage(cgImage: cg, size: NSSize(width: 224, height: 224)); imageView.image = qrImage; pairingText = text
    }
    @objc private func credentialsChanged() { updateQR() }
    @objc public func copyPairing() {
        guard let pairingText else { return }
        if payload.token.isEmpty { onSaveToken?(tokenField.stringValue) }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(pairingText, forType: .string); onCopied?("配对信息已复制")
    }
    public override func handleEscape() { onCancel?(); dismiss() }
    @objc private func cancel() { onCancel?(); dismiss() }
    private func isLoopback(_ value: String) -> Bool {
        guard let host = URLComponents(string: value)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost")
    }
    private func reachableURL(host: String, baseURL: String) -> String {
        guard var components = URLComponents(string: baseURL) else { return host }
        components.host = host; return components.string ?? host
    }
}

@MainActor
public final class CloseAgentDialogViewController: CorralDialogViewController {
    public required init?(coder: NSCoder) { nil }
    public let agentName: String
    public override var canDismissWithEscape: Bool { !isLoading }
    public var isLoading = false { didSet { confirmButton.isEnabled = !isLoading; cancelButton?.isEnabled = !isLoading } }
    public var onConfirm: (() -> Void)?
    public var onCancel: (() -> Void)?
    private let confirmButton = NSButton(title: "关闭 Agent", target: nil, action: nil)
    private weak var cancelButton: NSButton?
    public init(agentName: String, onConfirm: (() -> Void)? = nil, onCancel: (() -> Void)? = nil) { self.agentName = agentName; self.onConfirm = onConfirm; self.onCancel = onCancel; super.init() }
    public override func loadView() {
        let root = rootView(size: NSSize(width: 400, height: 210)); view = root
        _ = addHeader(to: root, title: "关闭 Agent", subtitle: "确定要关闭「\(agentName)」吗？")
        let message = NSTextField(labelWithString: "这会终止当前 Agent 会话，未保存的工作可能会丢失。"); message.font = .systemFont(ofSize: 11); message.textColor = CorralAestheticTokens.danger; message.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(message)
        NSLayoutConstraint.activate([message.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), message.topAnchor.constraint(equalTo: root.topAnchor, constant: 98)])
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelAction)); cancel.bezelStyle = .rounded; cancel.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(cancel); cancelButton = cancel
        confirmButton.target = self; confirmButton.action = #selector(confirm); confirmButton.bezelStyle = .rounded; confirmButton.translatesAutoresizingMaskIntoConstraints = false; stylePrimary(confirmButton); confirmButton.wantsLayer = true; confirmButton.layer?.backgroundColor = CorralAestheticTokens.danger.cgColor; confirmButton.contentTintColor = .white; root.addSubview(confirmButton)
        NSLayoutConstraint.activate([cancel.trailingAnchor.constraint(equalTo: confirmButton.leadingAnchor, constant: -8), cancel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20), confirmButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), confirmButton.bottomAnchor.constraint(equalTo: cancel.bottomAnchor), confirmButton.widthAnchor.constraint(equalToConstant: 96)])
    }
    public override func handleEscape() { guard !isLoading else { return }; onCancel?(); dismiss() }
    @objc private func cancelAction() { guard !isLoading else { return }; onCancel?(); dismiss() }
    public func confirmAction() { guard !isLoading else { return }; onConfirm?(); dismiss() }
    @objc private func confirm() { confirmAction() }
}
