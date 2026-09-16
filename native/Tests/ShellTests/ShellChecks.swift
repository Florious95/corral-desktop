// Standalone executable checks until G0 registers ShellTests in Package.swift.
// Compile alongside Sources/Shell with -D SHELL_STANDALONE_TEST_RUNNER.
#if SHELL_STANDALONE_TEST_RUNNER
import AppKit
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
        let params: [String: Any] = ["revision": 1, "viewportCSS": ["width": 800, "height": 600], "devicePixelRatio": 2,
            "dragRects": [rectangle(0, 0, 800, 40)], "exclusionRects": [rectangle(40, 0, 120, 40)], "chromeRect": rectangle(0, 0, 800, 40)]
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
        var finished = false
        controller.onLoadFinished = { finished = true }
        for _ in 0..<100 where !finished { try await Task.sleep(for: .milliseconds(100)) }
        expect(finished && controller.acceptsMessages, "real WK local scheme loads")
        let loaded = try await javascript("document.body.dataset.moduleReady === 'yes'", in: controller.webView) as? Bool
        expect(loaded == true, "real WK module executes")
        // JS owns only test calls; no synthetic system input or user data.
        _ = try await javascript("window.callNative = async (method, params={}, epoch) => window.webkit.messageHandlers.native.postMessage({v:1,id:crypto.randomUUID(),method,params,...(epoch ? {epoch}: {})}); window.callNative('bootstrap').then(x => window.boot = x); void 0", in: controller.webView)
        try await Task.sleep(for: .milliseconds(300))
        let bootOK = try await javascript("window.boot?.ok === true && window.boot.result.runtime === 'swift'", in: controller.webView) as? Bool
        expect(bootOK == true, "real WK reply bootstrap")
        _ = try await javascript("window.callNative('window.startDragging').then(x => window.dragReply = x); void 0", in: controller.webView)
        try await Task.sleep(for: .milliseconds(200))
        expect(try await javascript("window.dragReply?.error?.code === 'unsupported'", in: controller.webView) as? Bool == true, "async drag RPC rejected")
        _ = try await javascript("window.location.href = 'https://example.invalid/'", in: controller.webView)
        try await Task.sleep(for: .milliseconds(200))
        expect(LocalContent.isEntry(controller.webView.url), "external navigation denied")
        let oldEpoch = try await javascript("window.boot.result.epoch", in: controller.webView) as? String
        finished = false
        controller.reload()
        for _ in 0..<100 where !finished { try await Task.sleep(for: .milliseconds(100)) }
        _ = try await javascript("window.webkit.messageHandlers.native.postMessage({v:1,id:'reload-bootstrap',method:'bootstrap',params:{}}).then(x => window.boot = x); void 0", in: controller.webView)
        try await Task.sleep(for: .milliseconds(200))
        let newEpoch = try await javascript("window.boot.result.epoch", in: controller.webView) as? String
        expect(oldEpoch != nil && newEpoch != nil && oldEpoch != newEpoch, "reload rotates epoch")
        controller.dispose()
        expect(!controller.acceptsMessages, "dispose closes bridge")
        controller.close()
    }
}
#endif
