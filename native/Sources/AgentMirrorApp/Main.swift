import AppKit

/// SwiftPM does not provide an Xcode storyboard to wire the delegate. Keep the
/// application bootstrap explicit so the same executable works in a hand-built
/// isolated .app bundle and under `swift run`.
@main
@MainActor
struct AgentMirrorMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
