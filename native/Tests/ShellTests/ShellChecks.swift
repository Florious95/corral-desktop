// Standalone executable checks until G0 registers ShellTests in Package.swift.
// Compile alongside Sources/Shell with -D SHELL_STANDALONE_TEST_RUNNER.
#if SHELL_STANDALONE_TEST_RUNNER
import AppKit
import Darwin
import WebKit

@main
struct ShellChecks {
    @MainActor static var checks = 0
    @MainActor static func expect(_ condition: Bool, _ label: String) {
        guard condition else { print("FAIL \(label)"); exit(1) }
        checks += 1
        print("PASS \(label)")
    }
    @MainActor static func rejects(_ label: String, _ action: () throws -> Void) {
        do { try action(); expect(false, label) } catch { expect(true, label) }
    }
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); print("executed=\(checks) failed=0"); exit(0) }
            catch { print("FAIL unexpected \((error as NSError).domain) code=\((error as NSError).code)"); exit(1) }
        }
        app.run()
    }
    @MainActor static func javascript(_ source: String, in webView: WKWebView) async throws -> Any? {
        try await webView.evaluateJavaScript(source)
    }
    @MainActor static func run() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        func rectangle(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [String: Double] {
            ["x": x, "y": y, "width": w, "height": h]
        }
        func report(_ generation: Int, _ revision: Int) -> [String: Any] {
            ["phase": "arm", "geometryGeneration": generation, "revision": revision,
             "viewportCSS": ["width": 800, "height": 600], "devicePixelRatio": 2,
             "dragRects": [rectangle(0, 0, 800, 40)],
             "exclusionRects": [rectangle(40, 0, 120, 40)],
             "chromeRect": rectangle(0, 0, 800, 40)]
        }
        var params = report(0, 1)
        var geometry = SurfaceGeometry()
        expect(!geometry.isDraggable(.zero, bounds: bounds, backingScale: 2, flipped: true), "uninitialized rejects")
        try geometry.update(params, bounds: bounds, backingScale: 2)
        expect(geometry.isDraggable(CGPoint(x: 20, y: 20), bounds: bounds, backingScale: 2, flipped: true), "CSS not multiplied by DPR")
        expect(!geometry.isDraggable(CGPoint(x: 80, y: 20), bounds: bounds, backingScale: 2, flipped: true), "button exclusion wins")
        expect(!geometry.isDraggable(CGPoint(x: 20, y: 100), bounds: bounds, backingScale: 2, flipped: true), "terminal excluded")
        expect(geometry.isDraggable(CGPoint(x: 20, y: 580), bounds: bounds, backingScale: 2, flipped: false), "unflipped conversion")
        expect(!geometry.isDraggable(CGPoint(x: 20, y: 20), bounds: bounds, backingScale: 1, flipped: true), "screen scale invalidates")
        expect(!geometry.isDraggable(CGPoint(x: 20, y: 20), bounds: CGRect(x: 0, y: 0, width: 801, height: 600), backingScale: 2, flipped: true), "resize invalidates")
        rejects("replay revision rejects") { try geometry.update(params, bounds: bounds, backingScale: 2) }
        for (field, value) in [("revision", Double.nan as Any), ("revision", true as Any), ("devicePixelRatio", 1 as Any), ("dragRects", [rectangle(0, 50, 100, 40)] as Any)] {
            var bad = params; bad["revision"] = 2; bad[field] = value
            rejects("malformed \(field)") { try geometry.update(bad, bounds: bounds, backingScale: 2) }
        }
        geometry.invalidate()
        expect(!geometry.isDraggable(CGPoint(x: 20, y: 20), bounds: bounds, backingScale: 2, flipped: true), "explicit invalidation")
        geometry.reset()
        params = report(geometry.geometryGeneration, 1)
        try geometry.update(params, bounds: bounds, backingScale: 2)
        expect(geometry.revision == 1, "new page resets revision")
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let content = try LocalContent(distURL: fixture)
        expect(try content.file(for: LocalContent.entryURL).lastPathComponent == "index.html", "bundled entry resolves")
        rejects("external origin rejected") { _ = try content.file(for: URL(string: "https://app/index.html")!) }
        rejects("path traversal rejected") { _ = try content.file(for: URL(string: "agentmirror://app/../outside.html")!) }
        rejects("symlink escape rejected") { _ = try content.file(for: URL(string: "agentmirror://app/escape.html")!) }
        expect(!LocalContent.isEntry(URL(string: "agentmirror://app/index.html?other=1")), "entry query rejects")
        expect(LocalContent.isEntry(URL(string: "agentmirror://app/index.html#route")), "entry fragment allowed")
        let controller = try MainWindowController(distURL: fixture, websiteDataStore: .nonPersistent())
        guard let root = controller.window?.contentView,
              let frameView = root.superview else {
            expect(false, "content root has frame view")
            return
        }
        let dragSurface = root.subviews.first(where: { $0 is DragSurfaceView })
        let titlebarDragSurface = (frameView.subviews + root.subviews).first(where: { $0 is TitlebarDragSurfaceView })
        expect(dragSurface != nil, "drag surface is installed")
        expect(dragSurface?.superview === root, "drag surface stays in content root")
        expect(dragSurface?.frame == root.bounds,
               "drag surface matches content geometry")
        expect(titlebarDragSurface?.superview === frameView || titlebarDragSurface?.superview === root,
               "titlebar drag surface is installed in the native overlay hierarchy")
        if let dragSurface,
           let titlebarDragSurface,
           let closeButton = controller.window?.standardWindowButton(.closeButton) {
            var titlebarContainer = closeButton.superview
            while let candidate = titlebarContainer, candidate.superview !== frameView {
                titlebarContainer = candidate.superview
            }
            if let titlebarContainer,
               let titlebarIndex = frameView.subviews.firstIndex(where: { $0 === titlebarContainer }),
               let contentIndex = frameView.subviews.firstIndex(where: { $0 === root }),
               let titlebarHost = titlebarDragSurface.superview {
                expect(titlebarIndex > contentIndex,
                       "titlebar container stays above web content")
                if titlebarHost === frameView {
                    let dragIndex = frameView.subviews.firstIndex(where: { $0 === titlebarDragSurface })
                    expect(dragIndex.map { $0 > titlebarIndex } == true,
                           "titlebar drag surface is above native titlebar")
                    expect(titlebarDragSurface.frame == titlebarContainer.frame,
                           "titlebar drag surface matches native titlebar")
                } else {
                    expect(titlebarHost === root,
                           "titlebar drag surface uses content fallback host")
                    expect(titlebarDragSurface.frame == root.convert(titlebarContainer.bounds, from: titlebarContainer),
                           "titlebar drag surface matches native titlebar")
                }

                let width = root.bounds.width
                let height = root.bounds.height
                let rect: [String: Double] = ["x": 0, "y": 0, "width": width, "height": 80]
                let chromeRect: [String: Double] = ["x": 0, "y": 0, "width": width, "height": height]
                let closeRect = root.convert(closeButton.frame, from: closeButton.superview)
                let closeExclusion: [String: Double] = [
                    "x": Double(closeRect.minX), "y": 0,
                    "width": Double(closeRect.width), "height": 80,
                ]
                _ = try controller.updateSurface([
                    "phase": "arm", "geometryGeneration": controller.geometryGeneration,
                    "revision": 1,
                    "viewportCSS": ["width": width, "height": height],
                    "devicePixelRatio": controller.window?.backingScaleFactor ?? 1,
                    "dragRects": [rect], "exclusionRects": [closeExclusion], "chromeRect": chromeRect,
                ])
                let topbarPoint = NSPoint(x: titlebarContainer.frame.minX + 200,
                                          y: titlebarContainer.frame.midY)
                expect(frameView.hitTest(topbarPoint) === titlebarDragSurface,
                       "armed titlebar routes to native drag surface")
                let closeFrame = frameView.convert(closeButton.frame, from: closeButton.superview)
                let closePoint = NSPoint(x: closeFrame.midX, y: closeFrame.midY)
                expect(frameView.hitTest(closePoint) === closeButton,
                       "traffic-light exclusion still reaches native button")
            }
        }
        let requiredMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        expect(controller.window?.styleMask.isSuperset(of: requiredMask) == true, "window style mask keeps native controls")
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = controller.window?.standardWindowButton(buttonType),
                  let titlebarView = button.superview else {
                expect(false, "traffic light exists")
                continue
            }
            expect(titlebarView.bounds.contains(button.frame), "traffic light remains visible")
            expect(abs(button.frame.midY - 16.0) < 0.6, "traffic light aligns at y=16")
        }
        let initialFrame = controller.window?.frame
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification))
        expect(controller.window?.frame == initialFrame, "resize state callback preserves frame")
        var finished = false
        controller.onLoadFinished = { finished = true }
        for _ in 0..<100 where !finished { try await Task.sleep(for: .milliseconds(100)) }
        expect(finished && controller.acceptsMessages, "real WK local scheme loads")
        let loaded = try await javascript("document.body.dataset.moduleReady === 'yes'", in: controller.webView) as? Bool
        expect(loaded == true, "real WK custom-scheme entry executes")
        // JS owns only test calls; no synthetic system input or user data.
        _ = try await javascript("window.callNative = async (method, params={}, epoch) => window.webkit.messageHandlers.native.postMessage({v:1,id:crypto.randomUUID(),method,params,...(epoch ? {epoch}: {})}); window.callNative('bootstrap').then(x => window.boot = x); true", in: controller.webView)
        try await Task.sleep(for: .milliseconds(300))
        let bootOK = try await javascript("window.boot?.ok === true && window.boot.result.runtime === 'swift'", in: controller.webView) as? Bool
        expect(bootOK == true, "real WK reply bootstrap")
        _ = try await javascript("window.callNative('window.startDragging').then(x => window.dragReply = x); true", in: controller.webView)
        try await Task.sleep(for: .milliseconds(200))
        expect(try await javascript("window.dragReply?.error?.code === 'unsupported'", in: controller.webView) as? Bool == true, "async drag RPC rejected")
        _ = try await javascript("window.location.href = 'https://example.invalid/'", in: controller.webView)
        try await Task.sleep(for: .milliseconds(200))
        expect(LocalContent.isEntry(controller.webView.url), "external navigation denied")
        let oldEpoch = try await javascript("window.boot.result.epoch", in: controller.webView) as? String
        finished = false
        controller.reload()
        for _ in 0..<100 where !finished { try await Task.sleep(for: .milliseconds(100)) }
        expect(controller.window?.frame == initialFrame, "reload preserves frame")
        _ = try await javascript("window.webkit.messageHandlers.native.postMessage({v:1,id:'reload-bootstrap',method:'bootstrap',params:{}}).then(x => window.boot = x); true", in: controller.webView)
        try await Task.sleep(for: .milliseconds(200))
        let newEpoch = try await javascript("window.boot.result.epoch", in: controller.webView) as? String
        expect(oldEpoch != nil && newEpoch != nil && oldEpoch != newEpoch, "reload rotates epoch")
        controller.dispose()
        expect(!controller.acceptsMessages, "dispose closes bridge")
        controller.close()
    }
}
#endif
