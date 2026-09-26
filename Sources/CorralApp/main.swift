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
private struct AppCompositionRoot {
    let wireCodec: any WireCodecProtocol = ProtocolV1Codec()
    let geometryPolicy: any GeometryPolicy = DefaultGeometryPolicy()
    let initialConnectionState = ConnectionState.disconnected
    let stageID = UUID()
    let initialStage: StagePresentation

    init() {
        initialStage = StagePresentation(
            viewportStageID: stageID,
            viewport: StageViewportRect(x: 0, y: 0, width: 0, height: 0),
            layoutGeneration: LayoutGeneration(0),
            metricsGeneration: MetricsGeneration(0),
            visibility: .visible,
            applicationActivity: .inactive,
            sleepState: .paused
        )
        _ = CorralAppIdentity.bundleIdentifier
        _ = initialConnectionState
        _ = initialStage
        _ = wireCodec
        _ = geometryPolicy
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let compositionRoot = AppCompositionRoot()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Corral Native — Development"
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        _ = compositionRoot
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
