import AppKit
import CorralContracts
import CorralMetalTerminal
import CorralProtocol
import CorralServices
import CorralUI

public enum CorralAppIdentity {
    public static let bundleIdentifier = "com.corral.native.dev"
}

@MainActor
private final class MetalStageView: NSView {
    private let renderer: SharedMetalTerminalRenderer
    private let stageID: UUID
    private var layoutGeneration: LayoutGeneration
    private let metricsGeneration: MetricsGeneration
    private var lastSize: NSSize?
    private var lastBackingScale: CGFloat?

    init(renderer: SharedMetalTerminalRenderer, presentation: StagePresentation) {
        self.renderer = renderer
        self.stageID = presentation.viewportStageID
        self.layoutGeneration = presentation.layoutGeneration
        self.metricsGeneration = presentation.metricsGeneration
        super.init(frame: .zero)
        wantsLayer = true
        layer = renderer.stageLayer
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateStageGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateStageGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateStageGeometry()
    }

    private func updateStageGeometry() {
        let size = bounds.size
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        guard size.width > 0, size.height > 0, scale > 0,
              size != lastSize || scale != lastBackingScale else { return }

        if size != lastSize, layoutGeneration.rawValue < UInt64.max {
            layoutGeneration = LayoutGeneration(layoutGeneration.rawValue + 1)
        }
        lastSize = size
        lastBackingScale = scale
        renderer.configureStage(sizeInPoints: size, backingScale: scale)

        let visibility: StageVisibility = isHidden ? .tabHidden : (window?.isMiniaturized == true ? .windowMinimized : .visible)
        let request = StageFrameRequest(
            stageID: stageID,
            layoutGeneration: layoutGeneration,
            metricsGeneration: metricsGeneration,
            visibility: visibility,
            panes: []
        )
        Task { @MainActor [renderer] in _ = await renderer.render(request) }
    }
}

@MainActor
private final class AppCompositionRoot {
    let windowController: CorralWindowController
    private let deviceRepository: DeviceRepository
    private let sessionLink: any SessionLinkProtocol
    private let renderer: SharedMetalTerminalRenderer
    private let stageID: UUID
    private let workspace: CorralWorkspaceView

    init() throws {
        let codec: any WireCodecProtocol = ProtocolV1Codec()
        let deviceRepository = try DeviceRepository()
        let sessionLink: any SessionLinkProtocol = URLSessionSessionLink(codec: codec)
        let renderer = try SharedMetalTerminalRenderer()
        let stageID = UUID()
        let initialStage = StagePresentation(
            viewportStageID: stageID,
            viewport: StageViewportRect(x: 0, y: 0, width: 0, height: 0),
            layoutGeneration: LayoutGeneration(0),
            metricsGeneration: MetricsGeneration(0),
            visibility: .visible,
            applicationActivity: .inactive,
            sleepState: .paused
        )
        let stageView = MetalStageView(renderer: renderer, presentation: initialStage)
        let workspace = CorralWorkspaceView(tabs: [CorralTab(title: "Terminal", contentView: stageView)])

        self.deviceRepository = deviceRepository
        self.sessionLink = sessionLink
        self.renderer = renderer
        self.stageID = stageID
        self.workspace = workspace
        self.windowController = CorralWindowController(workspaceView: workspace)
    }

    func refreshDevices() async {
        guard let records = try? await deviceRepository.listDevices() else { return }
        workspace.sidebar.setDevices(records.map { CorralSidebarDevice(name: $0.name) })
    }

    func setApplicationActive(_ active: Bool) {
        let state: RenderSleepState = active ? .active : .applicationInactive
        Task { await renderer.setSleepState(state, for: stageID) }
    }

    func disconnect() async {
        await sessionLink.disconnect()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var compositionRoot: AppCompositionRoot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let root = try AppCompositionRoot()
            compositionRoot = root
            root.windowController.showWindow(self)
            Task { await root.refreshDevices() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Corral Native could not start"
            alert.informativeText = String(describing: error)
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        compositionRoot?.setApplicationActive(true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        compositionRoot?.setApplicationActive(false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let compositionRoot else { return }
        Task { await compositionRoot.disconnect() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
@main
private enum CorralAppMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
