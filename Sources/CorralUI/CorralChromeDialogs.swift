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
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard event.window !== window || !subviews.contains(where: { $0.frame.contains(point) }) else { return }
        onOutsideClick?()
    }
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
        // `.chr-btn-primary`: action-primary fill, 8px radius, no bezel.
        button.isBordered = false; button.wantsLayer = true; button.layer?.backgroundColor = CorralAestheticTokens.actionPrimaryBackground.cgColor; button.layer?.cornerRadius = 8; button.layer?.borderWidth = 0
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [.foregroundColor: CorralAestheticTokens.actionPrimaryForeground, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        button.contentTintColor = CorralAestheticTokens.actionPrimaryForeground
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
        let root = rootView(size: NSSize(width: 420, height: 360)); view = root
        var y = addHeader(to: root, title: "新建 Agent", subtitle: "在「\(spaceName)」中创建", top: 16)
        _ = addLabel("任务名称", to: root, y: y); y += 18
        nameField.placeholderString = "任务名称"; nameField.font = .systemFont(ofSize: 12); nameField.textColor = CorralAestheticTokens.text; nameField.backgroundColor = CorralAestheticTokens.surface0; nameField.isBezeled = true; nameField.bezelStyle = .roundedBezel; nameField.delegate = self; nameField.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(nameField)
        NSLayoutConstraint.activate([nameField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), nameField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), nameField.topAnchor.constraint(equalTo: root.topAnchor, constant: y), nameField.heightAnchor.constraint(equalToConstant: 28)])
        y += 44
        _ = addLabel("选择 Agent", to: root, y: y); y += 18
        launcherStack.orientation = .vertical; launcherStack.alignment = .width; launcherStack.distribution = .fillEqually; launcherStack.spacing = 8; launcherStack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(launcherStack)
        for start in stride(from: 0, to: launchers.count, by: 3) {
            let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.distribution = .fillEqually; row.spacing = 8
            for launcher in launchers[start..<min(start + 3, launchers.count)] {
                let button = NSButton(title: launcher.displayName, target: self, action: #selector(selectLauncher(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(launcher.provider); button.setButtonType(.pushOnPushOff); button.isBordered = false
                button.wantsLayer = true; button.layer?.cornerRadius = 8; button.layer?.borderWidth = 1
                button.font = .systemFont(ofSize: 11, weight: .medium)
                button.image = CorralProviderIconView(provider: launcher.provider, size: 18, active: true).image
                button.image?.size = NSSize(width: 18, height: 18)
                button.imagePosition = .imageLeading; button.imageHugsTitle = true; button.imageScaling = .scaleNone; button.tag = launcher.supportsBypass ? 1 : 0
                button.toolTip = launcher.displayName; button.heightAnchor.constraint(equalToConstant: 38).isActive = true
                row.addArrangedSubview(button); launcherButtons.append(button)
            }
            for _ in row.arrangedSubviews.count..<3 { row.addArrangedSubview(NSView()) }
            launcherStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: launcherStack.widthAnchor).isActive = true
        }
        let rows = max(1, (launchers.count + 2) / 3)
        let launcherHeight = CGFloat(rows * 38 + (rows - 1) * 8)
        NSLayoutConstraint.activate([launcherStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), launcherStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), launcherStack.topAnchor.constraint(equalTo: root.topAnchor, constant: y), launcherStack.heightAnchor.constraint(equalToConstant: launcherHeight)])
        y += launcherHeight + 16
        let bypassLabel = NSTextField(labelWithString: "Bypass permissions"); bypassLabel.font = .systemFont(ofSize: 12, weight: .medium); bypassLabel.textColor = CorralAestheticTokens.text; bypassLabel.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(bypassLabel)
        let description = NSTextField(labelWithString: "允许 Agent 不经确认执行 shell 命令"); description.font = .systemFont(ofSize: 10); description.textColor = CorralAestheticTokens.textMuted; description.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(description)
        bypassSwitch.target = self; bypassSwitch.action = #selector(toggleBypass); bypassSwitch.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(bypassSwitch)
        NSLayoutConstraint.activate([bypassLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), bypassLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: y), description.leadingAnchor.constraint(equalTo: bypassLabel.leadingAnchor), description.topAnchor.constraint(equalTo: bypassLabel.bottomAnchor, constant: 4), bypassSwitch.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), bypassSwitch.centerYAnchor.constraint(equalTo: bypassLabel.centerYAnchor)])
        y += 36
        errorLabel.textColor = CorralAestheticTokens.danger; errorLabel.font = .systemFont(ofSize: 10); errorLabel.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(errorLabel); errorLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: y).isActive = true; errorLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24).isActive = true
        let buttons = addActionButtons(to: root, cancel: #selector(cancel), primary: #selector(create), primaryTitle: "创建")
        buttons.cancel.isBordered = false; buttons.cancel.font = .systemFont(ofSize: 13, weight: .semibold); buttons.cancel.contentTintColor = CorralAestheticTokens.text
        buttons.cancel.wantsLayer = true; buttons.cancel.layer?.backgroundColor = CorralAestheticTokens.fillSubtle.cgColor; buttons.cancel.layer?.cornerRadius = 8
        NSLayoutConstraint.activate([buttons.cancel.heightAnchor.constraint(equalToConstant: 32), buttons.primary.heightAnchor.constraint(equalToConstant: 32)])
        cancelButton = buttons.cancel; createButton = buttons.primary
        root.setFrameSize(NSSize(width: 420, height: y + 80))
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
        for button in launcherButtons {
            button.isEnabled = !isLoading; button.state = button.identifier?.rawValue == selectedProvider ? .on : .off
            let selected = button.state == .on
            button.contentTintColor = selected ? CorralAestheticTokens.choiceSelectedForeground : CorralAestheticTokens.text
            button.layer?.backgroundColor = (selected ? CorralAestheticTokens.choiceSelectedBackground : CorralAestheticTokens.surface0).cgColor
            button.layer?.borderColor = (selected ? CorralAestheticTokens.choiceSelectedBorder : CorralAestheticTokens.borderSubtle).cgColor
        }
        nameField.isEnabled = !isLoading
        cancelButton?.isEnabled = !isLoading
        createButton?.isEnabled = isCreateEnabled
        createButton?.title = isLoading ? "创建中…" : "创建"
        if let createButton { stylePrimary(createButton) }
    }
    private func providerSymbol(_ provider: String) -> String { switch provider.lowercased() { case "claude": "sparkle"; case "codex": "chevron.left.forwardslash.chevron.right"; case "pi": "p.circle"; default: "terminal" } }
}

@MainActor
public final class SettingsDialogViewController: CorralDialogViewController {
    public required init?(coder: NSCoder) { nil }
    public private(set) var values: CorralSettingsValues
    public var onChange: ((CorralSettingsValues) -> Void)?
    public var onClose: (() -> Void)?
    /// `TERMINAL_FONT_FAMILIES` presets; each pill is labelled with its primary family.
    public static let fontPresets = ["Cascadia Code, Consolas", "JetBrains Mono, \"Andale Mono\", Menlo, \"Lucida Console\"", "Fira Code, Monaco, \"Courier New\"", "Menlo, \"Segoe UI Mono\"", "Consolas, \"Andale Mono\"", "Courier New"]
    public private(set) var themeButtons: [NSButton] = []
    public private(set) var fontPresetButtons: [NSButton] = []
    public let fontFamilyField = NSTextField(string: "")
    public let fontSizeSlider = NSSlider(value: 13, minValue: 10, maxValue: 24, target: nil, action: nil)
    public let fontSizeField = NSTextField(string: "13")
    public let fontSizeDecrementButton = NSButton(title: "−", target: nil, action: nil)
    public let fontSizeIncrementButton = NSButton(title: "+", target: nil, action: nil)
    public let directoryTrackingSwitch = NSSwitch()
    public private(set) var fontPreviewLabel: NSTextField?
    private let previewSizeCaption = NSTextField(labelWithString: "")
    public static let width: CGFloat = 560

    public init(values: CorralSettingsValues = CorralSettingsValues(), onChange: ((CorralSettingsValues) -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.values = values; self.onChange = onChange; self.onClose = onClose; super.init()
    }

    // Mirrors `SettingsDialog.jsx`: header, three titled cards (界面外观 / 终端外观 / 工作区行为), footer.
    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 600))
        root.wantsLayer = true; root.layer?.backgroundColor = CorralAestheticTokens.dialogBackground.cgColor; root.layer?.cornerRadius = 18
        root.setAccessibilityIdentifier("corral.settings.dialog")

        let title = label("设置", size: 20, weight: .semibold, color: CorralAestheticTokens.text)
        let subtitle = label("微调终端外观，让工作区更顺手。", size: 12, color: CorralAestheticTokens.textSecondary)
        let heading = vertical([title, subtitle], spacing: 6)
        let closeButton = NSButton(image: CorralLegacyIcon.image(.close, size: 12) ?? NSImage(), target: self, action: #selector(close))
        closeButton.isBordered = false; closeButton.focusRingType = .none; closeButton.contentTintColor = CorralAestheticTokens.textSecondary; closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = CorralAestheticTokens.fillSubtle.cgColor; closeButton.layer?.cornerRadius = 15
        closeButton.setAccessibilityLabel("关闭设置"); closeButton.setAccessibilityIdentifier("corral.settings.close")
        pin(closeButton, width: 30, height: 30)
        let header = horizontal([heading, spacer(), closeButton], alignment: .top)

        let modes: [(CorralThemeMode, String, CorralLegacyIcon)] = [(.light, "浅色", .sun), (.dark, "深色", .moon), (.system, "跟随系统", .monitor)]
        themeButtons = modes.map { mode, title, icon in
            let button = NSButton(title: title, image: CorralLegacyIcon.image(icon, size: 14) ?? NSImage(), target: self, action: #selector(themeButtonPressed(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(mode.rawValue); button.setAccessibilityIdentifier("corral.settings.theme.\(mode.rawValue)")
            button.isBordered = false; button.imagePosition = .imageLeading; button.imageHugsTitle = true; button.wantsLayer = true; button.layer?.cornerRadius = 6
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            return button
        }
        let segmented = horizontal(themeButtons, spacing: 4, distribution: .fillEqually)
        segmented.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        segmented.wantsLayer = true; segmented.layer?.backgroundColor = CorralAestheticTokens.surface0.cgColor; segmented.layer?.cornerRadius = 8
        segmented.layer?.borderWidth = 1; segmented.layer?.borderColor = CorralAestheticTokens.borderSubtle.cgColor
        let themeCard = card([fieldHeading("主题模式", hint: "浅色、深色或跟随系统外观"), segmented])

        fontPresetButtons = Self.fontPresets.map { preset in
            let name = Self.primaryFamily(preset)
            let button = NSButton(title: name, target: self, action: #selector(fontPresetPressed(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(preset); button.setAccessibilityIdentifier("corral.settings.font.\(name)")
            button.isBordered = false; button.wantsLayer = true; button.layer?.cornerRadius = 14; button.layer?.borderWidth = 1
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            return button
        }
        let presetRows = stride(from: 0, to: fontPresetButtons.count, by: 3).map { horizontal(Array(fontPresetButtons[$0..<min($0 + 3, fontPresetButtons.count)]), spacing: 7, distribution: .fillEqually) }
        let customLabel = label("自定义字体栈", size: 11, color: CorralAestheticTokens.textSecondary)
        fontFamilyField.font = .monospacedSystemFont(ofSize: 11, weight: .regular); fontFamilyField.textColor = CorralAestheticTokens.text
        fontFamilyField.isBezeled = false; fontFamilyField.drawsBackground = false; fontFamilyField.lineBreakMode = .byTruncatingTail; fontFamilyField.cell?.usesSingleLineMode = true
        fontFamilyField.target = self; fontFamilyField.action = #selector(fontFieldCommitted); fontFamilyField.setAccessibilityIdentifier("corral.settings.font.custom")
        let fontInput = inputBox(fontFamilyField, insets: NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10))

        fontSizeSlider.target = self; fontSizeSlider.action = #selector(sizeChanged); fontSizeSlider.setAccessibilityIdentifier("corral.settings.fontsize.slider")
        for (button, action, name) in [(fontSizeDecrementButton, #selector(decrementSize), "减小字号"), (fontSizeIncrementButton, #selector(incrementSize), "增大字号")] {
            button.isBordered = false; button.font = .systemFont(ofSize: 15); button.target = self; button.action = action; button.setAccessibilityLabel(name)
            pin(button, width: 26, height: 26)
        }
        fontSizeField.isBezeled = false; fontSizeField.drawsBackground = false; fontSizeField.alignment = .center; fontSizeField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        fontSizeField.textColor = CorralAestheticTokens.text; fontSizeField.target = self; fontSizeField.action = #selector(sizeFieldChanged); fontSizeField.setAccessibilityIdentifier("corral.settings.fontsize")
        fontSizeField.widthAnchor.constraint(equalToConstant: 26).isActive = true
        let unit = label("px", size: 11, color: CorralAestheticTokens.textSecondary)
        let stepper = inputBox(horizontal([fontSizeDecrementButton, fontSizeField, unit, fontSizeIncrementButton], spacing: 2), insets: NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2))
        stepper.setContentHuggingPriority(.required, for: .horizontal)
        let sizeRow = horizontal([fontSizeSlider, stepper], spacing: 20)
        let divider = NSView(); divider.wantsLayer = true; divider.layer?.backgroundColor = CorralAestheticTokens.border.cgColor
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let previewTitle = label("即时预览", size: 10, color: CorralAestheticTokens.previewCaption)
        previewSizeCaption.font = .systemFont(ofSize: 10); previewSizeCaption.textColor = CorralAestheticTokens.previewCaption
        let sample = NSTextField(labelWithString: ""); sample.lineBreakMode = .byTruncatingTail; fontPreviewLabel = sample
        let preview = vertical([horizontal([previewTitle, spacer(), previewSizeCaption]), sample], spacing: 8, insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
        preview.wantsLayer = true; preview.layer?.backgroundColor = CorralAestheticTokens.previewBackground.cgColor; preview.layer?.cornerRadius = 8
        preview.layer?.borderWidth = 1; preview.layer?.borderColor = CorralAestheticTokens.borderSubtle.cgColor
        preview.setAccessibilityIdentifier("corral.settings.preview")

        let typographyCard = card([fieldHeading("字体", hint: "使用本机已安装的字体"), vertical(presetRows, spacing: 7), customLabel, fontInput, divider, fieldHeading("字号", hint: "10–24 px"), sizeRow, preview],
                                  spacing: [10, 10, 6, 10, 10, 8, 10])

        let trackingTitle = label("目录跟踪", size: 13, weight: .semibold, color: CorralAestheticTokens.text)
        let trackingHint = label("切换 Agent 时，自动定位并展开左侧目录。", size: 11, color: CorralAestheticTokens.textSecondary)
        directoryTrackingSwitch.target = self; directoryTrackingSwitch.action = #selector(trackingChanged); directoryTrackingSwitch.setAccessibilityIdentifier("corral.settings.tracking")
        let trackingCard = card([horizontal([vertical([trackingTitle, trackingHint], spacing: 4), spacer(), directoryTrackingSwitch])])

        let body = vertical([section("界面外观", themeCard), section("终端外观", typographyCard), section("工作区行为", trackingCard)], spacing: 12)
        let top = vertical([header, body], spacing: 14, insets: NSEdgeInsets(top: 18, left: 24, bottom: 14, right: 24))

        let savedIcon = NSImageView(image: CorralLegacyIcon.image(.check, size: 12) ?? NSImage()); savedIcon.contentTintColor = CorralAestheticTokens.success
        let saved = horizontal([savedIcon, label("修改即时保存", size: 11, color: CorralAestheticTokens.textSecondary)], spacing: 6)
        let done = NSButton(title: "完成", target: self, action: #selector(close)); done.keyEquivalent = "\r"; done.setAccessibilityIdentifier("corral.settings.done")
        stylePrimary(done); pin(done, width: 76, height: 32)
        let footer = horizontal([saved, spacer(), done])
        footer.edgeInsets = NSEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
        let footerBorder = NSView(); footerBorder.wantsLayer = true; footerBorder.layer?.backgroundColor = CorralAestheticTokens.borderSubtle.cgColor
        footerBorder.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let content = vertical([top, footerBorder, footer], spacing: 0)
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: root.leadingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor), content.topAnchor.constraint(equalTo: root.topAnchor), content.widthAnchor.constraint(equalToConstant: Self.width)])
        root.setFrameSize(NSSize(width: Self.width, height: ceil(content.fittingSize.height)))
        view = root
        syncControls()
    }

    public func setTheme(_ theme: CorralThemeMode) { values.theme = theme; syncControls(); apply() }
    public func setFontFamily(_ family: String) { values.fontFamily = family; syncControls(); apply() }
    public func setFontSize(_ size: Double) { values.fontSize = min(24, max(10, size.rounded())); syncControls(); apply() }
    public func setDirectoryTracking(_ enabled: Bool) { values.directoryTracking = enabled; syncControls(); apply() }

    public static func primaryFamily(_ stack: String) -> String {
        (stack.split(separator: ",", maxSplits: 1).first.map(String.init) ?? stack).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
    public var selectedFontPreset: String? { Self.fontPresets.first { Self.primaryFamily($0).lowercased() == Self.primaryFamily(values.fontFamily).lowercased() } }

    @objc private func themeButtonPressed(_ sender: NSButton) { setTheme(CorralThemeMode(rawValue: sender.identifier?.rawValue ?? "") ?? .system) }
    @objc private func fontPresetPressed(_ sender: NSButton) { setFontFamily(sender.identifier?.rawValue ?? Self.fontPresets[0]) }
    @objc private func fontFieldCommitted() { let stack = fontFamilyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); if !stack.isEmpty { setFontFamily(stack) } }
    @objc private func sizeChanged() { setFontSize(fontSizeSlider.doubleValue) }
    @objc private func sizeFieldChanged() { setFontSize(Double(fontSizeField.stringValue) ?? values.fontSize) }
    @objc private func decrementSize() { setFontSize(values.fontSize - 1) }
    @objc private func incrementSize() { setFontSize(values.fontSize + 1) }
    @objc private func trackingChanged() { setDirectoryTracking(directoryTrackingSwitch.state == .on) }
    public override func handleEscape() { onClose?(); dismiss() }
    @objc private func close() { onClose?(); dismiss() }
    private func apply() { CorralAestheticTokens.themeMode = values.theme; onChange?(values) }

    private func syncControls() {
        for button in themeButtons {
            let active = button.identifier?.rawValue == values.theme.rawValue
            button.layer?.backgroundColor = active ? CorralAestheticTokens.surface3.cgColor : NSColor.clear.cgColor
            button.layer?.borderWidth = active ? 1 : 0; button.layer?.borderColor = CorralAestheticTokens.borderSubtle.cgColor
            let color = active ? CorralAestheticTokens.text : CorralAestheticTokens.textSecondary
            button.contentTintColor = color; button.state = active ? .on : .off; button.setAccessibilitySelected(active)
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 12.5, weight: active ? .semibold : .regular)])
        }
        let selectedPreset = selectedFontPreset
        for button in fontPresetButtons {
            let preset = button.identifier?.rawValue ?? ""
            let active = preset == selectedPreset
            button.state = active ? .on : .off; button.setAccessibilitySelected(active)
            button.layer?.backgroundColor = (active ? CorralAestheticTokens.choiceSelectedBackground : CorralAestheticTokens.fieldBackground).cgColor
            button.layer?.borderColor = (active ? CorralAestheticTokens.choiceSelectedBorder : CorralAestheticTokens.inputBorder).cgColor
            let font = NSFont(name: Self.primaryFamily(preset), size: 11).map { active ? NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) : $0 } ?? .monospacedSystemFont(ofSize: 11, weight: active ? .semibold : .regular)
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [.foregroundColor: active ? CorralAestheticTokens.choiceSelectedForeground : CorralAestheticTokens.text, .font: font])
        }
        if fontFamilyField.currentEditor() == nil { fontFamilyField.stringValue = values.fontFamily }
        fontSizeSlider.doubleValue = values.fontSize
        fontSizeField.stringValue = String(Int(values.fontSize))
        fontSizeDecrementButton.isEnabled = values.fontSize > 10; fontSizeIncrementButton.isEnabled = values.fontSize < 24
        previewSizeCaption.stringValue = "\(Int(values.fontSize)) px"
        directoryTrackingSwitch.state = values.directoryTracking ? .on : .off
        let previewFont = NSFont(name: Self.primaryFamily(values.fontFamily), size: CGFloat(values.fontSize)) ?? .monospacedSystemFont(ofSize: values.fontSize, weight: .regular)
        let sample = NSMutableAttributedString(string: "❯ ", attributes: [.foregroundColor: CorralAestheticTokens.success, .font: previewFont])
        sample.append(NSAttributedString(string: "Aa Bb 012345 · 清晰可见", attributes: [.foregroundColor: CorralAestheticTokens.previewForeground, .font: previewFont]))
        fontPreviewLabel?.attributedStringValue = sample
        fontPreviewLabel?.font = previewFont
    }

    // MARK: Layout helpers (`.settings-*` tokens)
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color; return field
    }
    private func spacer() -> NSView { let view = NSView(); view.setContentHuggingPriority(.init(1), for: .horizontal); return view }
    private func pin(_ view: NSView, width: CGFloat, height: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: width), view.heightAnchor.constraint(equalToConstant: height)])
    }
    private func horizontal(_ views: [NSView], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .centerY, distribution: NSStackView.Distribution = .fill) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.alignment = alignment; stack.spacing = spacing; stack.distribution = distribution; return stack
    }
    private func vertical(_ views: [NSView], spacing: CGFloat, insets: NSEdgeInsets = NSEdgeInsets()) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing; stack.edgeInsets = insets
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true }
        return stack
    }
    private func fieldHeading(_ title: String, hint: String) -> NSView {
        horizontal([label(title, size: 13, weight: .semibold, color: CorralAestheticTokens.text), spacer(), label(hint, size: 11, color: CorralAestheticTokens.textSecondary)])
    }
    private func section(_ title: String, _ card: NSView) -> NSView {
        let heading = label(title, size: 12, weight: .semibold, color: CorralAestheticTokens.textSecondary)
        let stack = vertical([heading, card], spacing: 9)
        return stack
    }
    private func card(_ rows: [NSView], spacing: [CGFloat] = []) -> NSView {
        let stack = NSStackView(views: rows); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        for (index, value) in spacing.enumerated() where index < rows.count - 1 { stack.setCustomSpacing(value, after: rows[index]) }
        stack.wantsLayer = true; stack.layer?.backgroundColor = CorralAestheticTokens.cardBackground.cgColor; stack.layer?.cornerRadius = 12
        stack.layer?.borderWidth = 1; stack.layer?.borderColor = CorralAestheticTokens.borderSubtle.cgColor
        stack.shadow = NSShadow(); stack.layer?.shadowColor = NSColor.black.cgColor; stack.layer?.shadowOpacity = 0.08; stack.layer?.shadowRadius = 1; stack.layer?.shadowOffset = NSSize(width: 0, height: -1)
        return stack
    }
    private func inputBox(_ content: NSView, insets: NSEdgeInsets) -> NSStackView {
        let box = NSStackView(views: [content]); box.orientation = .horizontal; box.edgeInsets = insets
        box.wantsLayer = true; box.layer?.backgroundColor = CorralAestheticTokens.fieldBackground.cgColor; box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1; box.layer?.borderColor = CorralAestheticTokens.inputBorder.cgColor
        return box
    }
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
