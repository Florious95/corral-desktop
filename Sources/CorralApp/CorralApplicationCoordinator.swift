import AppKit
import CorralContracts
import CorralProtocol
import CorralServices
import CorralUI
import Foundation
@preconcurrency import SwiftTerm

public protocol DeviceCredentialVault: Sendable {
    func store(_ secret: String, for handle: CredentialHandle) async throws
    func resolve(_ handle: CredentialHandle) async throws -> String?
    func delete(_ handle: CredentialHandle) async throws
}

public struct CorralApplicationTelemetry: Codable, Equatable, Sendable {
    public let pid: Int32
    public let connected: Bool
    public let sessionCount: Int
    public let subscribedSessionIDs: [String]
    public let terminalViewCount: Int
    public let visiblePaneCount: Int
    public let nonEmptyLineCount: Int
    public let discardedAutoReplyByteCount: Int
}

@MainActor
private final class NewAgentSheetDelegate: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose?()
        return false
    }
}

@MainActor
public final class CorralApplicationCoordinator: @preconcurrency TerminalViewDelegate {
    public let windowController: CorralWindowController
    public let workspaceView: CorralWorkspaceView
    public let backgroundMode: Bool
    private let terminalStageView: NativeTerminalStageView
    private let terminalRegistry = TerminalSessionRegistry()
    public let workspaceStore: CorralWorkspaceStore
    public let userPreferencesStore: UserPreferencesStore

    public private(set) var workspaceState: CorralWorkspaceState
    public private(set) var userPreferences: UserPreferences
    public private(set) var connected = false
    public private(set) var sessionCount = 0
    public private(set) var subscribedSessionIDs: [String] = []
    public private(set) var lastConnectionError: String?
    public private(set) var discardedAutoReplyByteCount = 0
    private(set) var devicesCardPanel: CorralAnchoredCardPanel?

    private struct TabPresentation {
        let title: String
        let descriptor: SessionDescriptor?
    }

    private struct RuntimeSession {
        var descriptor: SessionDescriptor
        var subscribed = false
        var subscriptionPending = false
        var lastAppliedReceiveOrdinal = ReceiveOrdinal(0)
        var desiredGrid: GridSize?
        var hasMobile = false
        var mobileCount: UInt32 = 0
        var desktopCount: UInt32 = 0
    }

    private struct ConnectionConfiguration {
        let endpoint: ApprovedEndpoint
        let token: String
        let deviceID: DeviceID
        let deviceName: String
    }

    private struct PendingCreateAgent {
        let request: CreateAgentRequest
        var result: CreateAgentResult?
    }

    private struct PendingCloseSession {
        let request: CloseSessionRequest
        let session: SessionKey
        var result: CloseSessionResult?
        var removedFromListing = false
    }

    private struct SessionOpenIntent {
        let key: SessionKey
        let gesture: SessionOpenGesture
    }

    private let deviceRepository: any DeviceRepositoryProtocol
    private let credentialVault: any DeviceCredentialVault
    private let sessionLink: any SessionLinkProtocol
    private let deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle
    private let inputRouter: SessionLinkInputRouter
    private let environment: [String: String]
    private let telemetryURL: URL?
    private let telemetryWriter = AtomicTelemetryWriter()
    private let maximumVisiblePanes: Int
    private let noResizeMode: Bool
    private var sidebarDeviceIDs: [DeviceID: UUID] = [:]
    private var activeWorkspaceTabID: UUID
    private var connection: AuthenticatedConnection?
    private var activeConnectionConfiguration: ConnectionConfiguration?
    private var eventStreamTask: Task<Void, Never>?
    private var eventStreamClaimed = false
    private var telemetryTask: Task<Void, Never>?
    private var cachedDevices: [DeviceRecord] = []
    private var spaceIDsByDirectory: [String: UUID] = [:]
    private var directoriesBySpaceID: [UUID: String] = [:]
    /// Live divider-drag layout: moves Metal viewports without resizing any server pane until the ratio commits.
    private var layoutPreview: WorkspaceLayoutNode?
    private var sessionUIIDs: [SessionID: UUID] = [:]
    private var sessionUIIDsByIdentity: [WorkspaceSessionIdentity: UUID] = [:]
    private var selectedSidebarSpaceID = CorralSidebarSpace.allSpacesID
    private var selectedDeviceIDs = Set<DeviceID>()
    private var activeDialog: CorralDialogViewController?
    private var settingsDialog: SettingsDialogViewController?
    private var newAgentDialog: NewAgentDialogViewController?
    private var newAgentSheet: NSPanel?
    private var newAgentSheetDelegate: NewAgentSheetDelegate?
    private var addDeviceDialog: AddDeviceDialogViewController?
    private var isAddingDevice = false
    private var closingSessionKeys = Set<SessionKey>()
    private var started = false
    private var sequence = 0
    private var listingSequence: UInt64 = 0
    private var listingRequestedEpoch: ConnectionEpoch?
    private var nextRequestID: UInt32 = 1
    private var pendingCreateAgentRequests: [UInt32: PendingCreateAgent] = [:]
    private var pendingCloseSessionRequests: [UInt32: PendingCloseSession] = [:]
    private var actionTimeoutTasks: [UInt32: Task<Void, Never>] = [:]
    public var onAgentCreated: ((SessionKey) -> Void)?
    public var onAgentCreationFailed: ((String) -> Void)?
    public var onAgentClosed: ((SessionKey) -> Void)?
    public var onAgentCloseFailed: ((SessionKey, String) -> Void)?
    public var onAgentRemoteCloseUnsupported: ((SessionKey) -> Void)?
    public private(set) var lastCreatedSessionKey: SessionKey?
    public private(set) var availableAgentLaunchers: [AgentLauncher] = []
    public private(set) var lastCreateAgentResult: CreateAgentResult?
    public private(set) var lastCloseSessionResult: CloseSessionResult?
    private(set) var lastInputAcknowledgement: (sequence: UInt32, succeeded: Bool)?
    private var configuredDeviceID: DeviceID?
    private var configuredDeviceName = "Development endpoint"
    private var sessionOrder: [SessionKey] = []
    private var sessions: [SessionKey: RuntimeSession] = [:]
    private var uiSessionKeys: [UUID: SessionKey] = [:]
    private var pendingSessionOpenIntents: [SessionOpenIntent] = []
    private var drainingSessionOpenIntents = false
    private var activeSession: SessionKey?

    public init(
        deviceRepository: any DeviceRepositoryProtocol,
        credentialVault: any DeviceCredentialVault,
        sessionLink: any SessionLinkProtocol,
        deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle,
        workspaceStore: CorralWorkspaceStore,
        userPreferencesStore: UserPreferencesStore,
        initialWorkspaceState: CorralWorkspaceState,
        initialUserPreferences: UserPreferences,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maximumVisiblePanes: Int = .max
    ) {
        precondition(maximumVisiblePanes > 0)
        self.deviceRepository = deviceRepository
        self.credentialVault = credentialVault
        self.sessionLink = sessionLink
        self.deviceSessionLifecycle = deviceSessionLifecycle
        self.inputRouter = SessionLinkInputRouter(sessionLink: sessionLink)
        self.workspaceStore = workspaceStore
        self.userPreferencesStore = userPreferencesStore
        self.workspaceState = initialWorkspaceState
        self.userPreferences = initialUserPreferences
        self.activeWorkspaceTabID = initialWorkspaceState.activeTabID
        self.environment = environment
        self.maximumVisiblePanes = maximumVisiblePanes
        self.noResizeMode = environment["CORRAL_NATIVE_NO_RESIZE"] == "1"
        self.backgroundMode = environment["CORRAL_NATIVE_BACKGROUND"] == "1"
        if let output = environment["CORRAL_NATIVE_TELEMETRY_OUT"], !output.isEmpty {
            telemetryURL = URL(fileURLWithPath: output).standardizedFileURL
        } else {
            telemetryURL = nil
        }

        let tabs = initialWorkspaceState.tabs.map { state in
            CorralTab(
                id: state.id,
                title: state.title.isEmpty ? "Terminal" : state.title,
                contentView: NSView(),
                isPinned: state.pinned,
                isCustomTitle: state.isCustomTitle,
                isBlankWorkspace: state.isBlank
            )
        }
        let workspaceView = CorralWorkspaceView(tabs: tabs)
        let terminalStageView = NativeTerminalStageView(frame: .zero)
        terminalStageView.maximumVisiblePanes = maximumVisiblePanes
        terminalStageView.translatesAutoresizingMaskIntoConstraints = false
        workspaceView.stageContainer.addTabContent(terminalStageView)
        NSLayoutConstraint.activate([
            terminalStageView.leadingAnchor.constraint(equalTo: workspaceView.stageContainer.leadingAnchor),
            terminalStageView.trailingAnchor.constraint(equalTo: workspaceView.stageContainer.trailingAnchor),
            terminalStageView.topAnchor.constraint(equalTo: workspaceView.stageContainer.topAnchor),
            terminalStageView.bottomAnchor.constraint(equalTo: workspaceView.stageContainer.bottomAnchor)
        ])
        self.terminalStageView = terminalStageView
        self.workspaceView = workspaceView
        self.windowController = CorralWindowController(workspaceView: workspaceView)
        workspaceView.selectTab(id: initialWorkspaceState.activeTabID)
        applyPreferences(initialUserPreferences)
        workspaceView.tabBar.onSelectTab = { [weak self] id in
            Task { @MainActor in await self?.selectWorkspaceTab(id: id) }
        }
        workspaceView.tabBar.onCloseTab = { [weak self] id in
            Task { @MainActor in await self?.closeWorkspaceTab(id: id) }
        }
        workspaceView.onCreateTab = { [weak self] in
            Task { @MainActor in await self?.createWorkspaceTab() }
        }
        workspaceView.onClosePreview = { [weak self] in
            guard let self, let previewID = self.workspaceState.previewUID else { return }
            Task { @MainActor in await self.closeWorkspacePane(previewID) }
        }
        workspaceView.onCreateAgent = { [weak self] spaceID in
            self?.presentNewAgentDialog(for: spaceID)
        }
        workspaceView.onSettings = { [weak self] in self?.presentSettingsDialog() }
        workspaceView.onToggleSidebar = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.persistSidebarVisibility() }
        }
        workspaceView.onDevices = { [weak self] in self?.presentDevicesPopover() }
        workspaceView.onSelectAgent = { [weak self] sessionID, gesture in
            self?.enqueueSessionOpen(sessionID, gesture: gesture)
        }
        workspaceView.onFocusSession = { [weak self] id, tabID in
            guard let self, let key = self.uiSessionKeys[id] else { return }
            let sessionID = self.workspaceSessionID(for: key)
            Task { @MainActor in await self.focusWorkspacePane(sessionID, in: tabID) }
        }
        workspaceView.sidebar.onSelectSpace = { [weak self] id in self?.selectedSidebarSpaceID = id }
        workspaceView.sidebar.onToggleFavorite = { [weak self] id, isFavorite in
            guard let self, let key = self.uiSessionKeys[id], let descriptor = self.sessions[key]?.descriptor else { return }
            Task { @MainActor in await self.setWorkspaceFavorite(self.favoriteKey(for: descriptor), isFavorite: isFavorite) }
        }
        workspaceView.sidebar.onCloseAgent = { [weak self] id in self?.confirmCloseAgent(id: id) }
        workspaceView.sidebar.onRenameAgent = { [weak self] id in self?.presentRenameAgent(id: id) }
        workspaceView.tabBar.onRenameTab = { [weak self] id, title in
            Task { @MainActor in await self?.renameWorkspaceTab(id, to: title) }
        }
        workspaceView.tabBar.onReorderTabs = { [weak self] id, index in
            guard let self, let source = self.workspaceState.tabs.firstIndex(where: { $0.id == id }) else { return }
            Task { @MainActor in await self.reorderWorkspaceTabs(from: source, to: index) }
        }
        workspaceView.tabBar.onContextAction = { [weak self] id, action in
            Task { @MainActor in await self?.handleTabContextAction(id, action: action) }
        }
        let stage = workspaceView.stageContainer
        stage.onDropSession = { [weak self] source, target, edge in
            guard let self, let key = self.sessionKey(for: source) else { return }
            Task { @MainActor in await self.splitWorkspacePane(key, target: target, edge: edge) }
        }
        stage.onDropTab = { [weak self] source, target, edge in
            Task { @MainActor in await self?.dropTab(source, onto: target, edge: edge) }
        }
        stage.splitView.onFocusPane = { [weak self] id in
            Task { @MainActor in await self?.focusWorkspacePane(id) }
        }
        stage.splitView.onClosePane = { [weak self] id in
            Task { @MainActor in await self?.closeWorkspacePane(id) }
        }
        stage.splitView.onLayoutPreview = { [weak self] preview in
            guard let self else { return }
            self.layoutPreview = preview
            self.updateTerminalStage()
        }
        stage.splitView.onRatioChange = { [weak self] path, ratio in
            Task { @MainActor in await self?.updateWorkspaceSplitRatio(path: path, ratio: ratio) }
        }
        onAgentCreated = { [weak self] key in
            guard let self else { return }
            self.dismissNewAgentSheet(returnCode: .OK)
            self.showToast("Agent 已创建：\(self.sessions[key]?.descriptor.name ?? key.reference.rawValue)", kind: .success)
        }
        onAgentCreationFailed = { [weak self] message in
            self?.newAgentDialog?.isLoading = false
            self?.showToast(message, kind: .error)
        }
        onAgentClosed = { [weak self] key in
            guard let self else { return }
            self.closingSessionKeys.remove(key)
            self.updateSidebar(devices: self.cachedDevices)
            self.showToast("Agent 已关闭", kind: .success)
        }
        onAgentCloseFailed = { [weak self] key, message in
            self?.closingSessionKeys.remove(key)
            self?.updateSidebar(devices: self?.cachedDevices ?? [])
            self?.showToast(message, kind: .error)
        }
        onAgentRemoteCloseUnsupported = { [weak self] key in
            self?.closingSessionKeys.remove(key)
            self?.updateSidebar(devices: self?.cachedDevices ?? [])
            self?.showToast("远端不支持关闭 Agent；本地工作区保持不变", kind: .warning)
        }
    }

    public func start() async {
        guard !started else { return }
        started = true
        await deviceSessionLifecycle.configure(
            disconnect: { [weak self] id in try await self?.disconnectSessions(on: id) },
            remove: { [weak self] id in try await self?.removeSessions(on: id) }
        )
        applyPreferences(await userPreferencesStore.snapshot())
        await applyWorkspaceState(await workspaceStore.snapshot())
        startTelemetryTimer()
        do {
            let devices = try await deviceRepository.listDevices()
            cachedDevices = devices
            if selectedDeviceIDs.count != 1 || devices.first(where: { selectedDeviceIDs.contains($0.id) }) == nil {
                selectedDeviceIDs = Set(devices.prefix(1).map(\.id))
            }
            updateSidebar(devices: devices)
            guard let configuration = try await connectionConfiguration(devices: devices) else {
                await writeTelemetry()
                return
            }
            try await connect(configuration: configuration)
            await writeTelemetry()
        } catch {
            if connection != nil { await sessionLink.disconnect() }
            connection = nil
            connected = false
            lastConnectionError = String(describing: error)
            await deviceSessionLifecycle.markDisconnected()
            updateSidebar(devices: cachedDevices)
            await writeTelemetry()
        }
    }

    public func stop() async {
        telemetryTask?.cancel()
        telemetryTask = nil
        devicesCardPanel?.orderOut(nil)
        devicesCardPanel = nil
        terminalRegistry.removeAll()
        actionTimeoutTasks.values.forEach { $0.cancel() }
        actionTimeoutTasks.removeAll()
        pendingCreateAgentRequests.removeAll()
        pendingCloseSessionRequests.removeAll()
        eventStreamTask?.cancel()
        eventStreamTask = nil
        await sessionLink.disconnect()
        connection = nil
        connected = false
        await deviceSessionLifecycle.markDisconnected()
        await writeTelemetry()
    }

    public func selectSidebarSession(id: UUID) {
        guard let key = uiSessionKeys[id], sessions[key] != nil else { return }
        let sessionID = workspaceSessionID(for: key)
        let tabID = workspaceState.tabs.first(where: { $0.sessionIDs.contains(sessionID) })?.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let tabID {
                await self.focusWorkspacePane(sessionID, in: tabID)
            } else {
                await self.openSession(key, gesture: .singleClick)
            }
        }
    }

    private func enqueueSessionOpen(_ sessionID: SessionID, gesture: SessionOpenGesture) {
        guard let key = sessionKey(for: sessionID) else {
            lastConnectionError = "The selected Agent no longer maps to a live session."
            showToast("无法打开会话：Agent 状态已过期，请刷新列表", kind: .error)
            return
        }
        pendingSessionOpenIntents.append(SessionOpenIntent(key: key, gesture: gesture))
        guard !drainingSessionOpenIntents else { return }
        drainingSessionOpenIntents = true
        Task { @MainActor [weak self] in await self?.drainSessionOpenIntents() }
    }

    private func drainSessionOpenIntents() async {
        while !pendingSessionOpenIntents.isEmpty {
            let intent = pendingSessionOpenIntents.removeFirst()
            await openSession(intent.key, gesture: intent.gesture)
        }
        drainingSessionOpenIntents = false
    }

    public func openSession(
        _ key: SessionKey,
        gesture: SessionOpenGesture = .singleClick,
        in tabID: UUID? = nil
    ) async {
        guard let descriptor = sessions[key]?.descriptor else {
            lastConnectionError = "The selected session is no longer in the device listing."
            showToast("无法打开会话：会话已从设备列表移除", kind: .warning)
            return
        }
        do {
            var targetTabWasStale = false
            if let tabID {
                let state = try await workspaceStore.switchTab(tabID)
                targetTabWasStale = state.activeTabID != tabID
            }
            _ = try await workspaceStore.smartOpenSession(descriptor, gesture: gesture)
            await applyWorkspaceState(await workspaceStore.snapshot())
            if targetTabWasStale {
                lastConnectionError = "The requested workspace Tab no longer exists; opened in the active Tab."
                showToast("目标标签页已失效，会话已在当前标签页打开", kind: .warning)
            }
        } catch {
            lastConnectionError = String(describing: error)
            showToast("会话打开失败：\(error)", kind: .error)
            await writeTelemetry()
        }
    }

    public func createWorkspaceTab() async {
        do {
            _ = try await workspaceStore.createTab()
            await applyWorkspaceState(await workspaceStore.snapshot())
        } catch { lastConnectionError = String(describing: error) }
    }

    public func selectWorkspaceTab(id: UUID) async {
        do {
            let state = try await workspaceStore.switchTab(id)
            await applyWorkspaceState(state)
        } catch { lastConnectionError = String(describing: error) }
    }

    public func closeWorkspaceTab(id: UUID) async {
        do {
            let state = try await workspaceStore.closeTab(id)
            await applyWorkspaceState(state)
        } catch { lastConnectionError = String(describing: error) }
    }

    public func closeWorkspacePane(_ sessionID: SessionID) async {
        do {
            let state = try await workspaceStore.closePane(sessionID)
            await applyWorkspaceState(state)
        } catch { lastConnectionError = String(describing: error) }
    }

    public func focusWorkspacePane(_ sessionID: SessionID) async {
        await focusWorkspacePane(sessionID, in: nil)
    }

    private func focusWorkspacePane(_ sessionID: SessionID, in tabID: UUID?) async {
        do {
            if let tabID, workspaceState.activeTabID != tabID { _ = try await workspaceStore.switchTab(tabID) }
            await applyWorkspaceState(try await workspaceStore.focusPane(sessionID))
        } catch { lastConnectionError = String(describing: error) }
    }

    public func closeOtherWorkspaceTabs(keeping id: UUID) async {
        do { await applyWorkspaceState(try await workspaceStore.closeOtherTabs(keeping: id)) }
        catch { lastConnectionError = String(describing: error) }
    }

    public func closeWorkspaceTabsToRight(of id: UUID) async {
        do { await applyWorkspaceState(try await workspaceStore.closeRightTabs(of: id)) }
        catch { lastConnectionError = String(describing: error) }
    }

    public func removeSessionFromWorkspace(_ key: SessionKey) async {
        do {
            let state = try await workspaceStore.removeClosedSession(workspaceSessionID(for: key))
            await applyWorkspaceState(state)
        } catch { lastConnectionError = String(describing: error) }
    }

    public func renameWorkspaceTab(_ id: UUID, to title: String) async {
        do { await applyWorkspaceState(try await workspaceStore.renameTab(id, to: title)) }
        catch { lastConnectionError = String(describing: error) }
    }

    public func pinWorkspaceTab(_ id: UUID, pinned: Bool) async {
        do { await applyWorkspaceState(try await workspaceStore.pinTab(id, pinned: pinned)) }
        catch { lastConnectionError = String(describing: error) }
    }

    public func reorderWorkspaceTabs(from source: Int, to destination: Int) async {
        do { await applyWorkspaceState(try await workspaceStore.reorderTabs(from: source, to: destination)) }
        catch { lastConnectionError = String(describing: error) }
    }

    public func updateWorkspaceSplitRatio(tabID: UUID? = nil, path: String, ratio: Double) async {
        do {
            let state = try await workspaceStore.updateSplitRatio(tabID: tabID, path: path, ratio: ratio)
            layoutPreview = nil
            await applyWorkspaceState(state)
        } catch {
            layoutPreview = nil
            lastConnectionError = String(describing: error)
            updateTerminalStage()
        }
    }

    public func setWorkspaceFavorite(_ key: String, isFavorite: Bool) async {
        do { await applyWorkspaceState(try await workspaceStore.setFavorite(key, isFavorite: isFavorite)) }
        catch { lastConnectionError = String(describing: error) }
    }

    public func splitWorkspacePane(_ session: SessionKey, target: SessionID?, edge: WorkspaceDropZone) async {
        guard let descriptor = sessions[session]?.descriptor else { return }
        do {
            let state = try await workspaceStore.splitSession(descriptor, target: target, edge: edge)
            await applyWorkspaceState(state)
        } catch { lastConnectionError = String(describing: error) }
    }

    public func updateUserPreferences(_ preferences: UserPreferences) async throws {
        let stored = try await userPreferencesStore.update(preferences)
        applyPreferences(stored)
        await writeTelemetry()
    }

    private func applyPreferences(_ preferences: UserPreferences) {
        userPreferences = preferences
        let appearance: NSAppearance?
        switch preferences.theme {
        case .dark: appearance = NSAppearance(named: .darkAqua)
        case .light: appearance = NSAppearance(named: .aqua)
        case .system: appearance = nil
        }
        windowController.window?.appearance = appearance
        workspaceView.appearance = appearance
        workspaceView.setTheme(CorralThemeMode(rawValue: preferences.theme.rawValue) ?? .system)
        workspaceView.setSidebarCollapsed(preferences.sidebarCollapsed)
        applyTerminalStageAppearance()
        for (_, view) in terminalRegistry.allViews {
            view.setTerminalFont(family: preferences.fontFamily, size: preferences.fontSize)
            view.setTerminalColors(foreground: terminalStageForeground, background: terminalStageBackground)
        }
    }

    private var terminalStageBackground: NSColor { CorralNativeTerminalView.defaultBackgroundColor }
    private var terminalStageForeground: NSColor { CorralNativeTerminalView.defaultForegroundColor }

    private func applyTerminalStageAppearance() {
        let darkAppearance = NSAppearance(named: .darkAqua)
        let background = terminalStageBackground.cgColor
        workspaceView.stageContainer.appearance = darkAppearance
        workspaceView.stageContainer.wantsLayer = true
        workspaceView.stageContainer.layer?.backgroundColor = background
        terminalStageView.appearance = darkAppearance
        terminalStageView.wantsLayer = true
        terminalStageView.layer?.backgroundColor = background
    }

    private func applyWorkspaceState(_ state: CorralWorkspaceState) async {
        guard state.isValid else { return }
        workspaceState = state
        activeWorkspaceTabID = state.activeTabID
        let oldTabs = Dictionary(uniqueKeysWithValues: workspaceView.tabs.map { ($0.id, $0) })
        let tabs = state.tabs.map { stateTab in
            let presentation = tabPresentation(for: stateTab, in: state)
            let descriptor = presentation.descriptor
            let tab = oldTabs[stateTab.id] ?? CorralTab(
                id: stateTab.id,
                title: presentation.title,
                contentView: NSView(),
                status: statusIndicator(for: descriptor),
                isPinned: stateTab.pinned,
                isCustomTitle: stateTab.isCustomTitle,
                isBlankWorkspace: stateTab.isBlank,
                provider: descriptor?.provider
            )
            tab.title = presentation.title
            tab.status = statusIndicator(for: descriptor)
            tab.provider = descriptor?.provider
            tab.isPinned = stateTab.pinned
            tab.isCustomTitle = stateTab.isCustomTitle
            tab.sessionIDs = Set(stateTab.sessionIDs.map(uiSessionID(for:)))
            tab.activeSessionID = stateTab.activeSessionID.map(uiSessionID(for:))
            tab.isBlankWorkspace = stateTab.isBlank
            return tab
        }
        workspaceView.synchronizeWorkspaceTabs(
            tabs,
            selectedTabID: state.activeTabID,
            previewSessionID: state.previewUID.map(uiSessionID(for:))
        )
        workspaceView.stageContainer.splitView.update(root: state.visibleRoot, focusedSessionID: state.visibleSessionID)
        activeSession = state.visibleSessionID.flatMap(sessionKey(for:))
        updateTerminalStage()
        await subscribeVisibleSessions()
        updateSidebar(devices: cachedDevices)
        updateWorkspaceTitle(count: sessionCount)
        focusVisibleTerminal()
    }

    private func ensureTerminalView(for key: SessionKey) -> CorralNativeTerminalView? {
        guard sessions[key] != nil else { return nil }
        if let view = terminalRegistry.view(for: key) { return view }
        let view = CorralNativeTerminalView(frame: .zero)
        view.terminalDelegate = self
        view.onDiscardedAutomaticReply = { [weak self] byteCount in
            self?.discardedAutoReplyByteCount += byteCount
        }
        view.setTerminalFont(family: userPreferences.fontFamily, size: userPreferences.fontSize)
        view.setTerminalColors(foreground: terminalStageForeground, background: terminalStageBackground)
        terminalRegistry.insert(view, for: key)
        return view
    }

    private func updateTerminalStage() {
        var views: [SessionID: CorralNativeTerminalView] = [:]
        for (key, view) in terminalRegistry.allViews {
            if let runtime = sessions[key] { views[runtime.descriptor.id] = view }
        }
        terminalStageView.update(
            root: layoutPreview ?? workspaceState.visibleRoot,
            focusedSessionID: workspaceState.visibleSessionID,
            views: views
        )
    }

    private func focusVisibleTerminal() {
        guard let sessionID = workspaceState.visibleSessionID,
              let key = sessionKey(for: sessionID),
              let view = terminalRegistry.view(for: key), !view.isHidden else { return }
        windowController.window?.makeFirstResponder(view)
    }

    private func sessionKey(for sessionID: SessionID) -> SessionKey? {
        sessions.first(where: { $0.value.descriptor.id == sessionID })?.key
    }

    private func uiSessionID(for sessionID: SessionID) -> UUID {
        if let existing = sessionUIIDs[sessionID] {
            if let key = sessionKey(for: sessionID), let descriptor = sessions[key]?.descriptor {
                sessionUIIDsByIdentity[WorkspaceSessionIdentity(descriptor)] = existing
                uiSessionKeys[existing] = key
            }
            return existing
        }
        let id: UUID
        if let key = sessionKey(for: sessionID), let descriptor = sessions[key]?.descriptor {
            let identity = WorkspaceSessionIdentity(descriptor)
            let currentID = sessionUIIDsByIdentity[identity]
            if let currentID, uiSessionKeys[currentID] == nil || uiSessionKeys[currentID] == key {
                id = currentID
            } else {
                id = UUID()
            }
            sessionUIIDsByIdentity[identity] = id
            uiSessionKeys[id] = key
        } else {
            id = UUID()
        }
        sessionUIIDs[sessionID] = id
        return id
    }

    private func statusIndicator(for descriptor: SessionDescriptor?) -> CorralStatusIndicatorView.Status {
        guard let descriptor else { return .idle }
        return switch descriptor.activity?.lowercased() {
        case "working": .working
        case "blocked": .blocked
        case "done": .done
        case "idle": descriptor.state == .done || descriptor.state == .exited ? .done : .idle
        case "unknown": .unknown
        default:
            switch descriptor.state {
            case .running: .unknown
            case .done, .exited: .done
            case .unknown: .unknown
            }
        }
    }

    private func favoriteKey(for descriptor: SessionDescriptor) -> String {
        let device = descriptor.key.deviceID.rawValue
        let directory = descriptor.workingDirectory
        let name = descriptor.name
        return "\(device.utf8.count):\(device)\(directory.utf8.count):\(directory)\(name.utf8.count):\(name)"
    }

    @discardableResult
    public func createAgent(workspace: String, anchorReference: SessionReference?, provider: String, name: String, bypass: Bool) async throws -> UInt32 {
        guard connected else { throw SessionLinkFailure.disconnected }
        guard anchorReference != nil else {
            throw SessionLinkFailure.protocolViolation("create_agent requires an active anchor")
        }
        let requestID = try allocateRequestID()
        let request = CreateAgentRequest(requestID: requestID, workspace: workspace, anchorReference: anchorReference, provider: provider, name: name, bypass: bypass)
        pendingCreateAgentRequests[requestID] = PendingCreateAgent(request: request)
        do {
            let receipt = try await sessionLink.send(.createAgent(request))
            guard receipt.socketWritten else { throw SessionLinkFailure.disconnected }
            if pendingCreateAgentRequests[requestID] != nil { scheduleActionTimeout(requestID) }
            return requestID
        } catch {
            pendingCreateAgentRequests.removeValue(forKey: requestID)
            throw error
        }
    }

    @discardableResult
    public func closeAgent(_ session: SessionKey) async throws -> UInt32 {
        guard connected, connection?.deviceID == session.deviceID else { throw SessionLinkFailure.disconnected }
        guard !pendingCloseSessionRequests.values.contains(where: { $0.session == session }) else {
            throw SessionLinkFailure.protocolViolation("close request already pending")
        }
        let requestID = try allocateRequestID()
        let request = CloseSessionRequest(requestID: requestID, reference: session.reference)
        pendingCloseSessionRequests[requestID] = PendingCloseSession(request: request, session: session)
        do {
            let receipt = try await sessionLink.send(.closeSession(request))
            guard receipt.socketWritten else { throw SessionLinkFailure.disconnected }
            if pendingCloseSessionRequests[requestID] != nil { scheduleActionTimeout(requestID) }
            return requestID
        } catch {
            pendingCloseSessionRequests.removeValue(forKey: requestID)
            throw error
        }
    }

    public func flushTelemetry() async { await writeTelemetry() }

    var activeTerminalSessionKey: SessionKey? { activeSession }

    func terminalView(for key: SessionKey) -> CorralNativeTerminalView? { terminalRegistry.view(for: key) }

    func terminalView(for reference: SessionReference) -> CorralNativeTerminalView? {
        guard let key = sessionOrder.first(where: { $0.reference == reference }) else { return nil }
        return terminalRegistry.view(for: key)
    }

    public var telemetry: CorralApplicationTelemetry {
        let visibleViews = visibleSessionKeys().compactMap { terminalRegistry.view(for: $0) }
        return CorralApplicationTelemetry(
            pid: ProcessInfo.processInfo.processIdentifier,
            connected: connected,
            sessionCount: sessionCount,
            subscribedSessionIDs: subscribedSessionIDs,
            terminalViewCount: terminalRegistry.count,
            visiblePaneCount: terminalStageView.visibleSessionIDs.count,
            nonEmptyLineCount: Self.nonEmptyLineCount(in: visibleViews),
            discardedAutoReplyByteCount: discardedAutoReplyByteCount
        )
    }

    private func persistSidebarVisibility() async {
        var preferences = userPreferences
        preferences.sidebarCollapsed = workspaceView.isSidebarCollapsed
        do { try await updateUserPreferences(preferences) }
        catch { showToast("偏好设置保存失败：\(error)", kind: .error) }
    }

    private func presentSettingsDialog() {
        settingsDialog?.dismiss()
        let values = CorralSettingsValues(
            theme: CorralThemeMode(rawValue: userPreferences.theme.rawValue) ?? .system,
            fontFamily: userPreferences.fontFamily,
            fontSize: Double(userPreferences.fontSize),
            directoryTracking: userPreferences.followDirectory
        )
        let dialog = SettingsDialogViewController(values: values, onChange: { [weak self] values in
            guard let self else { return }
            var preferences = self.userPreferences
            preferences.theme = ThemePreference(rawValue: values.theme.rawValue) ?? .system
            preferences.fontFamily = values.fontFamily
            preferences.fontSize = Int(values.fontSize.rounded())
            preferences.followDirectory = values.directoryTracking
            Task { @MainActor in
                do { try await self.updateUserPreferences(preferences) }
                catch { self.showToast("偏好设置保存失败：\(error)", kind: .error) }
            }
        }, onClose: { [weak self] in
            self?.settingsDialog = nil
            self?.activeDialog = nil
        })
        settingsDialog = dialog
        activeDialog = dialog
        dialog.present(over: windowController.window)
    }

    public func showNewAgentDialog() {
        if let newAgentSheet {
            newAgentSheet.makeKeyAndOrderFront(nil)
            return
        }
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        presentNewAgentDialog(for: selectedSidebarSpaceID)
    }

    private func presentNewAgentDialog(for spaceID: UUID?) {
        guard connected else { showToast("请先连接开发设备", kind: .warning); return }
        guard !availableAgentLaunchers.isEmpty else { showToast("当前设备未提供可用 Agent 启动器", kind: .warning); return }
        let directory = spaceID.flatMap { directoriesBySpaceID[$0] }
        let spaceName = directory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "All Spaces"
        let launchers = availableAgentLaunchers.map {
            CorralAgentLauncher(provider: $0.provider, displayName: $0.displayName, supportsBypass: $0.supportsBypass)
        }
        let dialog = NewAgentDialogViewController(spaceName: spaceName, launchers: launchers, onCreate: { [weak self] request in
            guard let self else { return }
            let anchor = directory.flatMap { target in
                self.sessionOrder.compactMap { self.sessions[$0]?.descriptor }.first { $0.workingDirectory == target }
            } ?? self.activeSession.flatMap { self.sessions[$0]?.descriptor }
            guard let anchor else {
                self.showToast("新建 Agent 需要先选择一个活动 Agent", kind: .warning)
                return
            }
            let workspace = directory ?? anchor.workingDirectory
            guard !workspace.isEmpty else { self.showToast("无法确定目标 Space", kind: .error); return }
            self.newAgentDialog?.isLoading = true
            Task { @MainActor in
                do {
                    _ = try await self.createAgent(
                        workspace: workspace,
                        anchorReference: anchor.key.reference,
                        provider: request.provider,
                        name: request.name,
                        bypass: request.bypass
                    )
                    self.showToast("正在创建 Agent…", kind: .info)
                } catch {
                    self.newAgentDialog?.isLoading = false
                    self.showToast("创建 Agent 失败：\(error)", kind: .error)
                }
            }
        }, onCancel: { [weak self] in
            self?.dismissNewAgentSheet(returnCode: .cancel)
        })
        dialog.loadViewIfNeeded()
        guard let parent = windowController.window else { return }
        let sheet = NSPanel(
            contentRect: dialog.view.bounds,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        sheet.title = "新建 Agent"
        sheet.identifier = NSUserInterfaceItemIdentifier("corral.newagent.window")
        sheet.isReleasedWhenClosed = false
        sheet.contentViewController = dialog
        let sheetDelegate = NewAgentSheetDelegate()
        sheetDelegate.onClose = { [weak self] in
            guard self?.newAgentDialog?.canDismissWithEscape == true else { return }
            self?.dismissNewAgentSheet(returnCode: .cancel)
        }
        sheet.delegate = sheetDelegate
        newAgentDialog = dialog
        newAgentSheet = sheet
        newAgentSheetDelegate = sheetDelegate
        activeDialog = dialog
        parent.beginSheet(sheet) { [weak self, weak dialog] _ in
            guard let self, self.newAgentDialog === dialog else { return }
            self.newAgentDialog = nil
            self.newAgentSheet = nil
            self.newAgentSheetDelegate = nil
            if self.activeDialog === dialog { self.activeDialog = nil }
        }
        sheet.makeFirstResponder(dialog.nameField)
    }

    private func dismissNewAgentSheet(returnCode: NSApplication.ModalResponse) {
        let dialog = newAgentDialog
        if let sheet = newAgentSheet {
            if let parent = sheet.sheetParent { parent.endSheet(sheet, returnCode: returnCode) }
            else { sheet.orderOut(nil) }
        }
        newAgentDialog = nil
        newAgentSheet = nil
        newAgentSheetDelegate?.onClose = nil
        newAgentSheetDelegate = nil
        if let dialog, activeDialog === dialog { activeDialog = nil }
    }

    private func presentAddDeviceDialog() {
        let dialog = AddDeviceDialogViewController(onSubmit: { [weak self] request in
            guard let self else { return }
            Task { @MainActor in await self.addDevice(request) }
        }, onCancel: { [weak self] in
            self?.addDeviceDialog = nil
            self?.activeDialog = nil
        })
        addDeviceDialog = dialog
        activeDialog = dialog
        dialog.present(over: windowController.window)
    }

    private func presentPairingDialog() {
        showToast("移动端配对需要可被手机访问的网络；开发版仅允许本机回环端点", kind: .warning)
    }

    private func confirmCloseAgent(id: UUID) {
        guard let key = uiSessionKeys[id], let descriptor = sessions[key]?.descriptor else { return }
        let dialog = CloseAgentDialogViewController(agentName: descriptor.name, onConfirm: { [weak self] in
            guard let self else { return }
            self.activeDialog = nil
            Task { @MainActor in
                self.closingSessionKeys.insert(key)
                self.updateSidebar(devices: self.cachedDevices)
                do {
                    _ = try await self.closeAgent(key)
                    self.showToast("已发送关闭请求；等待设备确认…", kind: .info)
                } catch {
                    self.closingSessionKeys.remove(key)
                    self.updateSidebar(devices: self.cachedDevices)
                    self.showToast("关闭 Agent 失败：\(error)", kind: .error)
                }
            }
        }, onCancel: { [weak self] in self?.activeDialog = nil })
        activeDialog = dialog
        dialog.present(over: windowController.window)
    }

    private func handleTabContextAction(_ id: UUID, action: String) async {
        switch action {
        case "pin":
            let pinned = workspaceState.tabs.first(where: { $0.id == id })?.pinned == false
            await pinWorkspaceTab(id, pinned: pinned)
        case "close": await closeWorkspaceTab(id: id)
        case "closeOthers": await closeOtherWorkspaceTabs(keeping: id)
        case "closeRight": await closeWorkspaceTabsToRight(of: id)
        case "resetTitle":
            do { await applyWorkspaceState(try await workspaceStore.resetTabTitle(id)) }
            catch { showToast("标签标题重置失败：\(error)", kind: .error) }
            updateSidebar(devices: cachedDevices)
        case "splitRight": await splitWorkspaceTab(id, edge: .right)
        case "splitDown": await splitWorkspaceTab(id, edge: .bottom)
        default: break
        }
    }

    private func splitWorkspaceTab(_ tabID: UUID, edge: WorkspaceDropZone) async {
        guard let sourceTab = workspaceState.tabs.first(where: { $0.id == tabID }),
              let sourceID = sourceTab.activeSessionID ?? sourceTab.sessionIDs.first,
              let targetTab = workspaceState.activeTab else {
            showToast("请先打开另一个会话以创建分屏", kind: .warning)
            return
        }
        let targetID = sourceTab.id == workspaceState.activeTabID
            ? sourceTab.sessionIDs.first(where: { $0 != sourceID })
            : targetTab.activeSessionID ?? targetTab.sessionIDs.first
        guard let targetID, targetID != sourceID, let key = sessionKey(for: sourceID) else {
            showToast("分屏需要两个不同的已打开会话", kind: .warning)
            return
        }
        await splitWorkspacePane(key, target: targetID, edge: edge)
    }

    private func presentRenameAgent(id: UUID) {
        guard let key = uiSessionKeys[id], let runtime = sessions[key] else { return }
        let field = NSTextField(string: runtime.descriptor.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.setAccessibilityIdentifier("corral.renameAgent.name")
        let alert = NSAlert()
        alert.messageText = "Rename Agent"
        alert.informativeText = "This name is saved in the current workspace."
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename").setAccessibilityIdentifier("corral.renameAgent.submit")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in await renameAgent(key, to: field.stringValue) }
    }

    func renameAgent(_ key: SessionKey, to proposedTitle: String) async {
        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let runtime = sessions[key] else { return }
        let sessionID = runtime.descriptor.id
        if !workspaceState.tabs.contains(where: { $0.sessionIDs.contains(sessionID) }) {
            await openSession(key, gesture: .doubleClick)
        }
        guard let tab = workspaceState.tabs.first(where: { $0.sessionIDs.contains(sessionID) }) else {
            showToast("无法在工作区中重命名此 Agent", kind: .error)
            return
        }
        await focusWorkspacePane(sessionID, in: tab.id)
        await renameWorkspaceTab(tab.id, to: title)
        updateSidebar(devices: cachedDevices)
    }

    /// A Tab dragged onto a pane moves that Tab's focused session into the visible layout.
    private func dropTab(_ sourceID: UUID, onto target: SessionID?, edge: WorkspaceDropZone) async {
        guard let sourceSession = workspaceState.tabs.first(where: { $0.id == sourceID })?.activeSessionID,
              let key = sessionKey(for: sourceSession) else { return }
        await splitWorkspacePane(key, target: target, edge: edge)
    }

    private func showToast(_ message: String, kind: ToastView.Kind) {
        ToastManager.shared.show(message, kind: kind, in: workspaceView)
    }

    private func devicesChanged(_ devices: [DeviceRecord]) async {
        let retainedHandles = Set(devices.map(\.credential))
        for removed in cachedDevices where !devices.contains(where: { $0.id == removed.id }) && !retainedHandles.contains(removed.credential) {
            try? await credentialVault.delete(removed.credential)
        }
        cachedDevices = devices
        if let configuredDeviceID, !devices.contains(where: { $0.id == configuredDeviceID }), configuredDeviceID.rawValue != "corral-native-development-endpoint" {
            self.configuredDeviceID = nil
            activeConnectionConfiguration = nil
        }
        updateSidebar(devices: devices)
    }

    private func addDevice(_ request: CorralAddDeviceRequest) async {
        guard !isAddingDevice else { return }
        isAddingDevice = true
        defer { isAddingDevice = false }
        do {
            guard let url = URL(string: request.url) else { throw EndpointSafetyError.invalidEndpoint }
            let endpoint = try ApprovedEndpoint(url: url)
            guard !request.token.isEmpty else { throw SessionLinkFailure.protocolViolation("device token is empty") }
            let existing = cachedDevices.first(where: { $0.endpoint == endpoint })
            let deviceID = existing?.id ?? DeviceID(UUID().uuidString)
            let handle = CredentialHandle(UUID().uuidString)
            try await credentialVault.store(request.token, for: handle)
            let device = DeviceRecord(id: deviceID, name: request.name, endpoint: endpoint, credential: handle)
            do {
                try await deviceRepository.save(device)
            } catch {
                try? await credentialVault.delete(handle)
                throw error
            }
            if let oldHandle = existing?.credential, oldHandle != handle { try? await credentialVault.delete(oldHandle) }
            cachedDevices = try await deviceRepository.listDevices()
            addDeviceDialog?.dismiss()
            addDeviceDialog = nil
            activeDialog = nil
            selectedDeviceIDs = [deviceID]
            await selectDevice(deviceID)
        } catch {
            showToast("添加设备失败：\(error)", kind: .error)
        }
    }

    private func selectDevice(_ id: DeviceID) async {
        guard let device = cachedDevices.first(where: { $0.id == id }) else { return }
        do {
            guard let token = try await credentialVault.resolve(device.credential), !token.isEmpty else {
                throw SessionLinkFailure.protocolViolation("device credential is unavailable")
            }
            let configuration = ConnectionConfiguration(endpoint: device.endpoint, token: token, deviceID: device.id, deviceName: device.name)
            try await connect(configuration: configuration)
            selectedDeviceIDs = [id]
            updateSidebar(devices: cachedDevices)
            showToast("已连接设备：\(device.name)", kind: .success)
        } catch {
            connected = false
            lastConnectionError = String(describing: error)
            showToast("连接设备失败：\(error)", kind: .error)
        }
    }

    private func presentDevicesPopover() {
        if devicesCardPanel?.isVisible == true {
            devicesCardPanel?.orderOut(nil)
            devicesCardPanel = nil
            return
        }
        let controller = DevicesPopoverViewController(repository: deviceRepository)
        controller.onDevicesChanged = { [weak self] devices in
            Task { @MainActor in await self?.devicesChanged(devices) }
        }
        controller.onSelectionChanged = { [weak self] ids in
            guard let self else { return }
            self.selectedDeviceIDs = ids
            guard ids.count == 1, let id = ids.first, id != self.configuredDeviceID else { return }
            Task { @MainActor in await self.selectDevice(id) }
        }
        controller.onAddDevice = { [weak self] in
            self?.devicesCardPanel?.orderOut(nil)
            self?.devicesCardPanel = nil
            self?.presentAddDeviceDialog()
        }
        controller.onPairMobile = { [weak self] in
            self?.devicesCardPanel?.orderOut(nil)
            self?.devicesCardPanel = nil
            self?.presentPairingDialog()
        }
        let panel = CorralAnchoredCardPanel(contentViewController: controller, anchoredTo: workspaceView.tabBar.devicesButton)
        devicesCardPanel = panel
        panel.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            do {
                try await controller.reloadDevices()
                controller.setReadyDevices(connected ? Set([configuredDeviceID].compactMap { $0 }) : [])
                if let configuredDeviceID { controller.setDevice(configuredDeviceID, selected: true) }
                self.selectedDeviceIDs = controller.selectedDeviceIDs
                panel.updateContentSizeAndPosition(anchoredTo: self.workspaceView.tabBar.devicesButton)
            } catch {
                self.showToast("设备列表读取失败：\(error)", kind: .error)
            }
        }
    }

    private func scheduleActionTimeout(_ requestID: UInt32) {
        actionTimeoutTasks[requestID]?.cancel()
        actionTimeoutTasks[requestID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.actionRequestTimedOut(requestID)
        }
    }

    private func cancelActionTimeout(_ requestID: UInt32) {
        actionTimeoutTasks.removeValue(forKey: requestID)?.cancel()
    }

    private func actionRequestTimedOut(_ requestID: UInt32) async {
        actionTimeoutTasks.removeValue(forKey: requestID)
        if let pending = pendingCreateAgentRequests.removeValue(forKey: requestID) {
            let message = pending.result == nil ? "Agent 创建请求超时" : "Agent 已创建，但等待会话列表确认超时"
            lastConnectionError = message
            onAgentCreationFailed?(message)
        } else if let pending = pendingCloseSessionRequests.removeValue(forKey: requestID) {
            let message = "关闭请求超时，状态待核"
            lastConnectionError = message
            onAgentCloseFailed?(pending.session, message)
        }
        await writeTelemetry()
    }

    private func resolveCreatedAgents<S: Sequence>(in sessions: S) async where S.Element == SessionKey {
        let available = Set(sessions)
        guard let deviceID = connection?.deviceID else { return }
        for (requestID, pending) in Array(pendingCreateAgentRequests) {
            guard let reference = pending.result?.reference else { continue }
            let key = SessionKey(deviceID: deviceID, reference: reference)
            guard available.contains(key), let descriptor = self.sessions[key]?.descriptor else { continue }
            pendingCreateAgentRequests.removeValue(forKey: requestID)
            cancelActionTimeout(requestID)
            do {
                let state = try await workspaceStore.smartOpenSession(descriptor, gesture: .doubleClick)
                await applyWorkspaceState(state)
                lastCreatedSessionKey = key
                onAgentCreated?(key)
            } catch {
                let message = "Agent 已出现在列表，但无法打开工作区：\(error)"
                lastConnectionError = message
                onAgentCreationFailed?(message)
            }
        }
    }

    private func markCloseRequestsRemoved(_ removed: Set<SessionKey>) async {
        for (requestID, var pending) in Array(pendingCloseSessionRequests) where removed.contains(pending.session) {
            pending.removedFromListing = true
            pendingCloseSessionRequests[requestID] = pending
            if pending.result?.ok == true { await finishCloseRequest(requestID) }
        }
    }

    private func finishCloseRequest(_ requestID: UInt32) async {
        guard let pending = pendingCloseSessionRequests.removeValue(forKey: requestID) else { return }
        cancelActionTimeout(requestID)
        do {
            let state = try await workspaceStore.removeClosedSession(workspaceSessionID(for: pending.session))
            await applyWorkspaceState(state)
        } catch {
            lastConnectionError = String(describing: error)
        }
        onAgentClosed?(pending.session)
    }

    private func workspaceSessionID(for key: SessionKey) -> SessionID {
        let deviceID = key.deviceID.rawValue
        return SessionID("\(deviceID.utf8.count):\(deviceID)\(key.reference.rawValue)")
    }

    private func reconcileWorkspaceListing() async {
        let descriptors = sessionOrder.compactMap { sessions[$0]?.descriptor }
        guard !descriptors.isEmpty else { return }
        do {
            var state = try await workspaceStore.reconcileListing(descriptors)
            let visibleSessionIsLive = state.visibleSessionID.flatMap(sessionKey(for:)).map { $0.deviceID == configuredDeviceID } ?? false
            if !visibleSessionIsLive, let firstSession = descriptors.first {
                state = try await workspaceStore.smartOpenSession(firstSession, gesture: .singleClick)
            }
            await applyWorkspaceState(state)
        } catch {
            lastConnectionError = String(describing: error)
        }
    }

    private func allocateRequestID() throws -> UInt32 {
        guard nextRequestID > 0 else { throw SessionLinkFailure.protocolViolation("request id exhausted") }
        let requestID = nextRequestID
        nextRequestID = requestID == UInt32.max ? 0 : requestID + 1
        return requestID
    }

    private func requestListing(for authenticated: AuthenticatedConnection) async {
        guard listingRequestedEpoch != authenticated.connectionEpoch else { return }
        let requestID: UInt32
        do { requestID = try allocateRequestID() }
        catch {
            lastConnectionError = String(describing: error)
            return
        }
        listingRequestedEpoch = authenticated.connectionEpoch
        listingSequence = 0
        do {
            let receipt = try await sessionLink.send(.list(requestID: requestID))
            guard receipt.socketWritten else { throw SessionLinkFailure.disconnected }
        } catch {
            listingRequestedEpoch = nil
            connected = false
            lastConnectionError = String(describing: error)
            updateSidebar(devices: cachedDevices)
        }
    }

    private func connect(configuration: ConnectionConfiguration) async throws {
        listingRequestedEpoch = nil
        listingSequence = 0
        let authenticated = try await sessionLink.connect(
            to: configuration.endpoint,
            deviceID: configuration.deviceID,
            credential: CredentialHandle(configuration.token)
        )
        connection = authenticated
        activeConnectionConfiguration = configuration
        configuredDeviceID = configuration.deviceID
        configuredDeviceName = configuration.deviceName
        connected = true
        lastConnectionError = nil
        updateSidebar(devices: cachedDevices)
        await deviceSessionLifecycle.markConnected(configuration.deviceID)
        if !eventStreamClaimed {
            let stream = try await sessionLink.eventStream()
            eventStreamClaimed = true
            eventStreamTask = Task { [weak self] in await self?.consume(stream) }
        }
        await requestListing(for: authenticated)
        await writeTelemetry()
    }

    private func connectionConfiguration(devices: [DeviceRecord]) async throws -> ConnectionConfiguration? {
        let environmentToken = environment["CORRAL_NATIVE_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text = environment["CORRAL_NATIVE_ENDPOINT"], !text.isEmpty {
            guard let url = URL(string: text) else { throw EndpointSafetyError.invalidEndpoint }
            let endpoint = try ApprovedEndpoint(url: url)
            let existing = devices.first { $0.endpoint == endpoint }
            let storedToken: String?
            if let existing { storedToken = try await credentialVault.resolve(existing.credential) }
            else { storedToken = nil }
            guard let token = environmentToken.flatMap({ $0.isEmpty ? nil : $0 })
                ?? storedToken.flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
            return ConnectionConfiguration(
                endpoint: endpoint,
                token: token,
                deviceID: existing?.id ?? DeviceID("corral-native-development-endpoint"),
                deviceName: existing?.name ?? "Development endpoint"
            )
        }
        let selected = selectedDeviceIDs.count == 1 ? selectedDeviceIDs.first : nil
        guard let device = devices.first(where: { $0.id == selected }) ?? devices.first else { return nil }
        let storedToken = try await credentialVault.resolve(device.credential)
        guard let token = environmentToken.flatMap({ $0.isEmpty ? nil : $0 })
            ?? storedToken.flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
        return ConnectionConfiguration(endpoint: device.endpoint, token: token, deviceID: device.id, deviceName: device.name)
    }

    private func consume(_ stream: any SessionEventStream) async {
        do {
            while !Task.isCancelled, let envelope = try await stream.next() {
                await receive(envelope)
            }
        } catch {
            connected = false
            lastConnectionError = String(describing: error)
            await deviceSessionLifecycle.markDisconnected()
            updateSidebar(devices: cachedDevices)
            await writeTelemetry()
        }
    }

    private func receive(_ envelope: SessionEventEnvelope) async {
        if case let .connectionChanged(state) = envelope.event,
           let current = connection,
           envelope.origin.linkInstanceID == current.linkInstanceID,
           envelope.origin.deviceID == current.deviceID {
            switch state {
            case let .authenticatedReady(epoch):
                if epoch != current.connectionEpoch,
                   let updated = try? AuthenticatedConnection(
                    linkInstanceID: envelope.origin.linkInstanceID,
                    deviceID: envelope.origin.deviceID,
                    connectionEpoch: epoch
                   ) {
                    connection = updated
                    listingRequestedEpoch = nil
                    listingSequence = 0
                }
                connected = true
                await deviceSessionLifecycle.markConnected(envelope.origin.deviceID)
                if let connection { await requestListing(for: connection) }
            case .disconnected, .failed:
                connected = false
                await deviceSessionLifecycle.markDisconnected()
            case .transportOpen, .authenticating:
                if envelope.origin.connectionEpoch != current.connectionEpoch { connected = false }
            }
            updateSidebar(devices: cachedDevices)
            await writeTelemetry()
            return
        }
        guard let connection, envelope.origin.belongs(to: connection) else { return }
        switch envelope.event {
        case .connectionChanged:
            break
        case let .failed(error):
            connected = false
            lastConnectionError = String(describing: error)
            await deviceSessionLifecycle.markDisconnected()
            updateSidebar(devices: cachedDevices)
            await writeTelemetry()
        case let .control(control):
            switch control {
            case let .authAck(ok, reason, launchers):
                availableAgentLaunchers = ok ? launchers : []
                lastConnectionError = ok ? nil : reason
                await writeTelemetry()
            case let .listing(listing): await applyListing(listing, origin: envelope.origin)
            case let .listDelta(delta): await applyListDelta(delta, origin: envelope.origin)
            case let .createAgentResult(result):
                guard var pending = pendingCreateAgentRequests[result.requestID] else { return }
                lastCreateAgentResult = result
                guard result.ok, let reference = result.reference else {
                    pendingCreateAgentRequests.removeValue(forKey: result.requestID)
                    cancelActionTimeout(result.requestID)
                    let message = "create_agent failed: \(result.reason?.rawValue ?? "missing reference")"
                    lastConnectionError = message
                    onAgentCreationFailed?(message)
                    await writeTelemetry()
                    return
                }
                pending.result = result
                pendingCreateAgentRequests[result.requestID] = pending
                await resolveCreatedAgents(in: sessions.keys)
                await writeTelemetry()
                _ = reference
            case let .closeSessionResult(result):
                guard var pending = pendingCloseSessionRequests[result.requestID] else { return }
                lastCloseSessionResult = result
                guard result.ok else {
                    pendingCloseSessionRequests.removeValue(forKey: result.requestID)
                    cancelActionTimeout(result.requestID)
                    let message = "close_session failed: \(result.reason?.rawValue ?? "unknown")"
                    lastConnectionError = message
                    onAgentCloseFailed?(pending.session, message)
                    await writeTelemetry()
                    return
                }
                pending.result = result
                pendingCloseSessionRequests[result.requestID] = pending
                if pending.removedFromListing { await finishCloseRequest(result.requestID) }
                await writeTelemetry()
            case let .presenceUpdate(reference, hasMobile, mobileCount, desktopCount):
                let key = SessionKey(deviceID: envelope.origin.deviceID, reference: reference)
                if var runtime = sessions[key] {
                    runtime.hasMobile = hasMobile
                    runtime.mobileCount = mobileCount
                    runtime.desktopCount = desktopCount
                    sessions[key] = runtime
                }
                await writeTelemetry()
            case .error(.unsupportedType, let reason):
                if pendingCreateAgentRequests.isEmpty,
                   pendingCloseSessionRequests.count == 1,
                   let requestID = pendingCloseSessionRequests.keys.first {
                    let session = pendingCloseSessionRequests[requestID]!.session
                    pendingCloseSessionRequests.removeValue(forKey: requestID)
                    cancelActionTimeout(requestID)
                    lastConnectionError = reason ?? "远端不支持关闭 Agent"
                    onAgentRemoteCloseUnsupported?(session)
                } else if pendingCloseSessionRequests.isEmpty,
                          pendingCreateAgentRequests.count == 1,
                          let requestID = pendingCreateAgentRequests.keys.first {
                    pendingCreateAgentRequests.removeValue(forKey: requestID)
                    cancelActionTimeout(requestID)
                    let message = reason ?? "服务端不支持创建 Agent"
                    lastConnectionError = message
                    onAgentCreationFailed?(message)
                } else {
                    lastConnectionError = reason
                }
                await writeTelemetry()
            case let .error(_, reason):
                lastConnectionError = reason
                await writeTelemetry()
            case let .inputAck(sequence, ok, reason):
                lastInputAcknowledgement = (sequence, ok)
                if !ok { lastConnectionError = "input_ack failed: \(reason?.rawValue ?? "unknown")" }
                await writeTelemetry()
            case .level2Frame, .level2Heartbeat, .overlayFrame, .paneModeChanged:
                await writeTelemetry()
            }
        case let .frame(frame): await applyFrame(frame, origin: envelope.origin)
        }
    }

    private func discardSessionRuntimes(_ keys: Set<SessionKey>) async {
        for key in keys {
            if sessions[key]?.subscribed == true {
                do {
                    let receipt = try await sessionLink.send(.unsubscribe(reference: key.reference))
                    if !receipt.socketWritten { lastConnectionError = "unsubscribe was not written for \(key.reference.rawValue)" }
                } catch {
                    lastConnectionError = String(describing: error)
                }
            }
            sessions.removeValue(forKey: key)
            _ = terminalRegistry.remove(key)
            let removedUIID = sessionUIIDs.removeValue(forKey: workspaceSessionID(for: key))
            if let removedUIID { uiSessionKeys.removeValue(forKey: removedUIID) }
            uiSessionKeys = uiSessionKeys.filter { $0.value != key }
            if activeSession == key { activeSession = nil }
        }
        updateTerminalStage()
    }

    private func applyListing(_ listing: SessionListing, origin: SessionEventOrigin) async {
        guard listing.isValid, listing.sequence > listingSequence else { return }
        listingSequence = listing.sequence
        var order: [SessionKey] = []
        for workspace in listing.workspaces {
            for record in workspace.sessions {
                let key = upsert(record, deviceID: origin.deviceID, origin: origin)
                if !order.contains(key) { order.append(key) }
            }
        }
        let currentSessions = Set(order)
        let removedSessions = Set(sessions.keys).subtracting(currentSessions)
        await markCloseRequestsRemoved(removedSessions)
        await discardSessionRuntimes(removedSessions)
        sessionOrder = order
        sessionCount = order.count
        await reconcileWorkspaceListing()
        await resolveCreatedAgents(in: order)
        subscribedSessionIDs = sessionOrder.compactMap { sessions[$0]?.subscribed == true ? $0.reference.rawValue : nil }
        updateWorkspaceTitle(count: sessionCount)
        await subscribeVisibleSessions()
        updateSidebar(devices: (try? await deviceRepository.listDevices()) ?? [])
        updateTerminalStage()
        await writeTelemetry()
    }

    private func applyListDelta(_ delta: SessionListDelta, origin: SessionEventOrigin) async {
        guard delta.isValid, delta.sequence > listingSequence else { return }
        listingSequence = delta.sequence
        let removed = Set(delta.removedReferences)
        let removedSessions = Set(removed.map { SessionKey(deviceID: origin.deviceID, reference: $0) })
        sessionOrder.removeAll { $0.deviceID == origin.deviceID && removed.contains($0.reference) }
        await markCloseRequestsRemoved(removedSessions)
        await discardSessionRuntimes(removedSessions)
        for record in delta.addedSessions + delta.changedSessions {
            let key = upsert(record, deviceID: origin.deviceID, origin: origin)
            if !sessionOrder.contains(key) { sessionOrder.append(key) }
        }
        for workspace in delta.changedWorkspaces {
            for record in workspace.sessions {
                let key = upsert(record, deviceID: origin.deviceID, origin: origin)
                if !sessionOrder.contains(key) { sessionOrder.append(key) }
            }
        }
        sessionCount = sessionOrder.count
        await reconcileWorkspaceListing()
        await resolveCreatedAgents(in: sessionOrder)
        updateWorkspaceTitle(count: sessionCount)
        await subscribeVisibleSessions()
        updateSidebar(devices: (try? await deviceRepository.listDevices()) ?? [])
        updateTerminalStage()
        await writeTelemetry()
    }

    private func upsert(_ record: WireSessionRecord, deviceID: DeviceID, origin: SessionEventOrigin) -> SessionKey {
        let key = SessionKey(deviceID: deviceID, reference: record.reference)
        let size = GridSize(rows: Int(record.rows), columns: Int(record.columns))
        let lifecycle: SessionLifecycleState = switch record.state {
        case .working, .idle, .blocked: .running
        case .done: .done
        case .unknown: .unknown
        }
        let descriptor = SessionDescriptor(
            id: workspaceSessionID(for: key), key: key, name: record.name,
            workingDirectory: record.workingDirectory, provider: record.provider, activity: record.activity,
            state: lifecycle, size: size,
            freshness: SessionFreshness(connectionEpoch: origin.connectionEpoch, receiveOrdinal: origin.receiveOrdinal)
        )
        if var runtime = sessions[key] {
            if runtime.descriptor.freshness?.connectionEpoch != origin.connectionEpoch {
                runtime.subscribed = false
                runtime.subscriptionPending = false
                runtime.lastAppliedReceiveOrdinal = origin.receiveOrdinal
            }
            runtime.descriptor = descriptor
            runtime.lastAppliedReceiveOrdinal = origin.receiveOrdinal
            sessions[key] = runtime
        } else {
            sessions[key] = RuntimeSession(descriptor: descriptor, lastAppliedReceiveOrdinal: origin.receiveOrdinal)
        }
        _ = uiSessionID(for: descriptor.id)
        return key
    }

    private func subscribeVisibleSessions() async {
        guard connection != nil else { return }
        for key in visibleSessionKeys() { _ = ensureTerminalView(for: key) }
        updateTerminalStage()
        focusVisibleTerminal()
        for key in visibleSessionKeys() {
            guard let runtime = sessions[key], !runtime.subscribed, !runtime.subscriptionPending else { continue }
            do {
                // Accept an immediate server SNAPSHOT while the WebSocket send receipt is still in flight.
                sessions[key]?.subscriptionPending = true
                // Use the server-advertised live grid; inspection mode never substitutes local view dimensions.
                let receipt = try await sessionLink.send(.subscribe(reference: key.reference, size: runtime.descriptor.size))
                sessions[key]?.subscriptionPending = false
                guard receipt.socketWritten else { continue }
                sessions[key]?.subscribed = true
                if !noResizeMode, let grid = sessions[key]?.desiredGrid { await resizeSessionIfNeeded(key, to: grid) }
            } catch {
                sessions[key]?.subscriptionPending = false
                lastConnectionError = String(describing: error)
            }
        }
        if activeSession == nil {
            activeSession = visibleSessionKeys().first(where: { sessions[$0]?.subscribed == true })
        }
        subscribedSessionIDs = sessionOrder.compactMap { key in sessions[key]?.subscribed == true ? key.reference.rawValue : nil }
        updateTerminalStage()
    }

    private func applyFrame(_ frame: BinaryFrame, origin: SessionEventOrigin) async {
        let reference: SessionReference
        switch frame {
        case let .snapshot(ref, _), let .delta(ref, _), let .scrollback(ref, _, _): reference = ref
        }
        let key = SessionKey(deviceID: origin.deviceID, reference: reference)
        guard var runtime = sessions[key], runtime.subscribed || runtime.subscriptionPending,
              runtime.descriptor.freshness?.connectionEpoch == origin.connectionEpoch,
              runtime.lastAppliedReceiveOrdinal < origin.receiveOrdinal,
              let view = terminalRegistry.view(for: key) else { return }
        runtime.lastAppliedReceiveOrdinal = origin.receiveOrdinal
        sessions[key] = runtime
        switch frame {
        case let .snapshot(_, bytes): view.replaceSnapshot(bytes)
        case let .delta(_, bytes): view.feedRemoteANSI(Array(bytes)[...])
        case .scrollback: return
        }
        await writeTelemetry()
    }

    private func visibleSessionKeys() -> [SessionKey] {
        guard let root = workspaceState.visibleRoot else { return [] }
        return root.leafIDs.compactMap(sessionKey(for:)).prefix(maximumVisiblePanes).map { $0 }
    }

    private func resizeSessionIfNeeded(_ key: SessionKey, to grid: GridSize) async {
        guard !noResizeMode,
              connection != nil, var runtime = sessions[key], runtime.subscribed,
              runtime.descriptor.size != grid,
              terminalStageView.visibleSessionIDs.contains(runtime.descriptor.id) else { return }
        let previous = runtime.descriptor.size
        runtime.descriptor.size = grid
        runtime.desiredGrid = grid
        sessions[key] = runtime
        do {
            let receipt = try await sessionLink.send(.resize(reference: key.reference, size: grid))
            guard receipt.socketWritten else {
                if sessions[key]?.descriptor.size == grid { sessions[key]?.descriptor.size = previous }
                return
            }
        } catch {
            if sessions[key]?.descriptor.size == grid { sessions[key]?.descriptor.size = previous }
            lastConnectionError = String(describing: error)
        }
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard !noResizeMode,
              newCols > 0, newRows > 0,
              newCols <= Int(UInt16.max), newRows <= Int(UInt16.max),
              newRows <= 1_000_000 / newCols,
              let key = terminalRegistry.key(for: source), var runtime = sessions[key] else { return }
        let grid = GridSize(rows: newRows, columns: newCols)
        runtime.desiredGrid = grid
        sessions[key] = runtime
        guard runtime.subscribed else { return }
        Task { @MainActor [weak self] in await self?.resizeSessionIfNeeded(key, to: grid) }
    }

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !noResizeMode,
              let key = terminalRegistry.key(for: source), sessions[key]?.subscribed == true else { return }
        let bytes = Data(data)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { _ = try await inputRouter.routeBytes(bytes, to: key) }
            catch { lastConnectionError = String(describing: error) }
        }
    }

    public func setTerminalTitle(source: TerminalView, title: String) {}
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard userPreferences.followDirectory, let key = terminalRegistry.key(for: source),
              let directory, !directory.isEmpty else { return }
        sessions[key]?.descriptor.workingDirectory = directory
        updateSidebar(devices: cachedDevices)
        updateWorkspaceTitle(count: sessionCount)
    }
    public func scrolled(source: TerminalView, position: Double) {}
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    public func bell(source: TerminalView) {}
    public func clipboardCopy(source: TerminalView, content: Data) {}
    public func clipboardRead(source: TerminalView) -> Data? { nil }
    public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    private func updateSidebar(devices: [DeviceRecord]) {
        cachedDevices = devices
        var sidebarDevices = devices.map { device in
            let id = self.sidebarDeviceIDs[device.id] ?? UUID()
            self.sidebarDeviceIDs[device.id] = id
            let deviceSessions = sessionOrder.compactMap { key -> CorralSidebarSession? in
                guard key.deviceID == device.id, let runtime = sessions[key] else { return nil }
                return CorralSidebarSession(id: uiSessionID(for: runtime.descriptor.id), name: runtime.descriptor.name)
            }
            let isOnline = connected && configuredDeviceID == device.id
            return CorralSidebarDevice(id: id, name: device.name, sessions: deviceSessions, isOnline: isOnline)
        }
        if let configuredDeviceID, !devices.contains(where: { $0.id == configuredDeviceID }) {
            let id = sidebarDeviceIDs[configuredDeviceID] ?? UUID()
            sidebarDeviceIDs[configuredDeviceID] = id
            let deviceSessions = sessionOrder.compactMap { key -> CorralSidebarSession? in
                guard key.deviceID == configuredDeviceID, let runtime = sessions[key] else { return nil }
                return CorralSidebarSession(id: uiSessionID(for: runtime.descriptor.id), name: runtime.descriptor.name)
            }
            sidebarDevices.append(CorralSidebarDevice(id: id, name: configuredDeviceName, sessions: deviceSessions, isOnline: connected))
        }
        workspaceView.sidebar.setDevices(sidebarDevices)

        let liveDescriptors = sessionOrder.compactMap { sessions[$0]?.descriptor }
        var spacesByDirectory: [String: CorralSidebarSpace] = [:]
        let agents = liveDescriptors.map { descriptor -> CorralSidebarAgent in
            let directory = descriptor.workingDirectory
            let spaceID: UUID?
            if directory.isEmpty { spaceID = nil }
            else {
                let id = spaceIDsByDirectory[directory] ?? UUID()
                spaceIDsByDirectory[directory] = id
                directoriesBySpaceID[id] = directory
                if spacesByDirectory[directory] == nil {
                    let label = URL(fileURLWithPath: directory).lastPathComponent
                    spacesByDirectory[directory] = CorralSidebarSpace(id: id, name: label.isEmpty ? directory : label)
                }
                spaceID = id
            }
            let id = uiSessionID(for: descriptor.id)
            let isOpen = workspaceState.previewUID == descriptor.id || workspaceState.tabs.contains(where: { $0.sessionIDs.contains(descriptor.id) })
            return CorralSidebarAgent(
                id: id,
                name: descriptor.name,
                status: statusIndicator(for: descriptor),
                provider: descriptor.provider,
                deviceName: devices.first(where: { $0.id == descriptor.key.deviceID })?.name ?? (descriptor.key.deviceID == configuredDeviceID ? configuredDeviceName : nil),
                spaceID: spaceID,
                isFavorite: workspaceState.favorites.contains(favoriteKey(for: descriptor)),
                isOpen: isOpen,
                isActive: workspaceState.visibleSessionID == descriptor.id,
                isClosing: closingSessionKeys.contains(descriptor.key),
                sessionID: descriptor.id
            )
        }
        workspaceView.sidebar.setSpaces(Array(spacesByDirectory.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        workspaceView.sidebar.setAgents(agents)
        workspaceView.sidebar.selectSpace(id: selectedSidebarSpaceID)
    }

    private func updateWorkspaceTitle(count: Int) {
        guard let stateTab = workspaceState.activeTab,
              let tab = workspaceView.tabs.first(where: { $0.id == stateTab.id }) else { return }
        let presentation = tabPresentation(for: stateTab, in: workspaceState)
        tab.title = presentation.title
        tab.status = statusIndicator(for: presentation.descriptor)
        tab.provider = presentation.descriptor?.provider
        tab.isPinned = stateTab.pinned
        tab.isCustomTitle = stateTab.isCustomTitle
        tab.badge = count > 0 ? String(count) : nil
        workspaceView.tabBar.setTabs(workspaceView.tabs, selectedTabID: workspaceState.activeTabID)
    }

    private func tabPresentation(for tab: WorkspaceTab, in state: CorralWorkspaceState) -> TabPresentation {
        let sessionID = tab.activeSessionID
        let descriptor = sessionID.flatMap(sessionKey(for:)).flatMap { sessions[$0]?.descriptor }
        let savedIdentity = sessionID.flatMap { id in state.sessionBindings.first { $0.sessionID == id }?.identity }
        let customTitle = tab.isCustomTitle ? nonEmpty(tab.title) : nil
        let title = customTitle
            ?? nonEmpty(descriptor?.name)
            ?? nonEmpty(savedIdentity?.name)
            ?? directoryTitle(descriptor?.workingDirectory ?? savedIdentity?.workingDirectory)
            ?? "Terminal"
        return TabPresentation(title: title, descriptor: descriptor)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func directoryTitle(_ path: String?) -> String? {
        guard let path = nonEmpty(path) else { return nil }
        let component = URL(fileURLWithPath: path).lastPathComponent
        return component == "/" ? nil : nonEmpty(component)
    }

    private func disconnectSessions(on deviceID: DeviceID) async throws {
        guard connection?.deviceID == deviceID else { return }
        await sessionLink.disconnect()
        connection = nil
        connected = false
        await deviceSessionLifecycle.markDisconnected()
        updateSidebar(devices: cachedDevices)
        await writeTelemetry()
    }

    private func removeSessions(on deviceID: DeviceID) async throws {
        let removed = sessions.keys.filter { $0.deviceID == deviceID }
        for key in removed {
            sessions.removeValue(forKey: key)
            _ = terminalRegistry.remove(key)
        }
        sessionOrder.removeAll { $0.deviceID == deviceID }
        uiSessionKeys = uiSessionKeys.filter { $0.value.deviceID != deviceID }
        if activeSession?.deviceID == deviceID { activeSession = nil }
        updateTerminalStage()
        sessionCount = sessionOrder.count
        subscribedSessionIDs = sessionOrder.compactMap { sessions[$0]?.subscribed == true ? $0.reference.rawValue : nil }
        updateSidebar(devices: (try? await deviceRepository.listDevices()) ?? [])
        updateTerminalStage()
        await writeTelemetry()
    }

    private func startTelemetryTimer() {
        guard telemetryURL != nil, telemetryTask == nil else { return }
        telemetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                await self?.writeTelemetry()
            }
        }
    }

    private func writeTelemetry() async {
        guard let telemetryURL else { return }
        await telemetryWriter.write(telemetry, to: telemetryURL)
    }

    private static func nonEmptyLineCount(in views: [CorralNativeTerminalView]) -> Int {
        views.reduce(0) { count, view in
            count + (0..<view.getTerminal().rows).filter { row in
                guard let line = view.getTerminal().getLine(row: row) else { return false }
                return !line.translateToString(trimRight: true).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
        }
    }
}

actor SessionLinkInputRouter {
    private let sessionLink: any SessionLinkProtocol
    private var sequence: UInt32 = 0

    init(sessionLink: any SessionLinkProtocol) { self.sessionLink = sessionLink }

    func routeBytes(_ bytes: Data, to session: SessionKey) async throws -> UInt32 {
        guard sequence < UInt32.max else { throw SessionLinkFailure.protocolViolation("Input sequence exhausted") }
        sequence += 1
        let request = try ClientInputRequest(sequence: sequence, reference: session.reference, payload: .bytes(bytes))
        let receipt = try await sessionLink.send(.input(request))
        guard receipt.socketWritten else { throw SessionLinkFailure.disconnected }
        return sequence
    }

}

public actor CoordinatorDeviceSessionLifecycle: DeviceSessionLifecycle {
    private let sessionLink: any SessionLinkProtocol
    private var connectedDeviceID: DeviceID?
    private var disconnectAction: (@Sendable (DeviceID) async throws -> Void)?
    private var removeAction: (@Sendable (DeviceID) async throws -> Void)?

    init(sessionLink: any SessionLinkProtocol) { self.sessionLink = sessionLink }

    func configure(
        disconnect: @escaping @Sendable (DeviceID) async throws -> Void,
        remove: @escaping @Sendable (DeviceID) async throws -> Void
    ) {
        disconnectAction = disconnect
        removeAction = remove
    }

    func markConnected(_ deviceID: DeviceID) { connectedDeviceID = deviceID }
    func markDisconnected() { connectedDeviceID = nil }

    public func disconnectSessions(on deviceID: DeviceID) async throws {
        guard connectedDeviceID == deviceID else { return }
        if let disconnectAction { try await disconnectAction(deviceID) }
        else { await sessionLink.disconnect() }
        connectedDeviceID = nil
    }

    public func removeSessions(on deviceID: DeviceID) async throws {
        try await removeAction?(deviceID)
    }
}

public struct AppKitDeviceDeletionConfirmer: DeviceDeletionConfirming {
    public init() {}
    public func confirmFirstDeletion(of device: DeviceRecord) async -> Bool {
        await confirm(device, message: "Disconnect and remove this device?")
    }

    public func confirmFinalDeletion(of device: DeviceRecord) async -> Bool {
        await confirm(device, message: "This permanently removes the device and its local session state. Continue?")
    }

    private func confirm(_ device: DeviceRecord, message: String) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = device.name
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }
}

private actor AtomicTelemetryWriter {
    func write(_ receipt: CorralApplicationTelemetry, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(receipt).write(to: url, options: .atomic)
        } catch {
            // Telemetry is observational and must not interfere with terminal IO or app startup.
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
