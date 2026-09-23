import AppKit
import WebKit

public enum ShellError: String, Error, Sendable {
    case invalidRequest = "invalid_request"
    case staleGeometry = "stale_geometry"
    case unsupported, unavailable, timeout, cancelled
    case tooLarge = "too_large"
    case permissionDenied = "permission_denied"
    case storageFailed = "storage_failed"
    case unauthorized, unreachable
    case httpStatus = "http_status"
    case invalidResponse = "invalid_response"
}

/// I1 injects concrete services. No global registry and no success fallback.
@MainActor
public protocol ShellServiceHandling: AnyObject {
    var availableMethods: Set<String> { get }
    func handle(method: String, params: [String: Any]) async throws -> Any
}

struct WindowStateSnapshot: Equatable, Sendable {
    let fullscreen: Bool
    let minimized: Bool
    let geometryGeneration: Int
}

struct WindowStateDeduper: Sendable {
    private var previous: WindowStateSnapshot?

    mutating func reset() { previous = nil }

    mutating func shouldEmit(_ next: WindowStateSnapshot) -> Bool {
        guard previous != next else { return false }
        previous = next
        return true
    }
}

private extension WindowStateSnapshot {
    init?(windowState: [String: Any]) {
        guard let fullscreen = windowState["fullscreen"] as? Bool,
              let minimized = windowState["minimized"] as? Bool,
              let geometryGeneration = windowState["geometryGeneration"] as? Int else {
            return nil
        }
        self.init(fullscreen: fullscreen, minimized: minimized, geometryGeneration: geometryGeneration)
    }
}

@MainActor
public final class ShellBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: MainWindowController?
    let services: (any ShellServiceHandling)?
    private(set) var epoch = UUID().uuidString
    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    private struct PendingRequest {
        let work: Task<Void, Never>
        let timeout: Task<Void, Never>
        let reply: @MainActor @Sendable (Any?, String?) -> Void
    }
    private var pending: [String: PendingRequest] = [:]
    private var ready = false
    private var sequence = 0
    private var stateDeduper = WindowStateDeduper()
    private var stateTask: Task<Void, Never>?
    private var stateChange = 0

    static let windowMethods: Set<String> = [
        "bootstrap", "window.getState", "window.isFullscreen", "window.setFullscreen",
        "window.toggleFullscreen", "window.minimize", "window.close", "surface.update"
    ]
    static let serviceMethods: Set<String> = [
        "devices.load", "devices.save", "secureStore.get", "secureStore.set",
        "clipboard.text", "clipboard.readText", "clipboard.image", "clipboard.readImage",
        "clipboard.files", "clipboard.readFiles", "upload", "upload.http",
        "migration.loadUI", "migration.saveUI"
    ]

    init(services: (any ShellServiceHandling)?) { self.services = services }

    func reset() {
        stateTask?.cancel()
        stateTask = nil
        let old = pending
        pending.removeAll()
        for (id, request) in old {
            request.work.cancel()
            request.timeout.cancel()
            request.reply(failure(id: id, code: .cancelled), nil)
        }
        epoch = UUID().uuidString
        seen.removeAll()
        seenOrder.removeAll()
        ready = false
        sequence = 0
        stateDeduper.reset()
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame,
              LocalContent.isEntry(message.frameInfo.request.url),
              let owner,
              let webView = message.webView,
              webView === owner.webView,
              owner.acceptsMessages else {
            replyHandler(nil, "permission_denied")
            return
        }
        guard let request = message.body as? [String: Any],
              let id = request["id"] as? String,
              !id.isEmpty,
              id.utf8.count <= 128 else {
            replyHandler(nil, "invalid_request")
            return
        }
        do {
            guard Set(request.keys).isSubset(of: ["v", "id", "epoch", "method", "params", "args"]),
                  let version = request["v"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(),
                  version == 1,
                  !(request["params"] != nil && request["args"] != nil),
                  let method = request["method"] as? String,
                  let params = (request["params"] ?? request["args"]) as? [String: Any],
                  JSONSerialization.isValidJSONObject(request) else {
                throw ShellError.invalidRequest
            }
            if method != "bootstrap" && (Self.serviceMethods.contains(method) || method == "surface.update") {
                guard request["epoch"] as? String == epoch else { throw ShellError.staleGeometry }
            }
            let maxPayloadSize = (method == "upload" || method == "upload.http")
                ? 15_728_640
                : 1_048_576
            guard try JSONSerialization.data(withJSONObject: request).count <= maxPayloadSize else {
                throw ShellError.tooLarge
            }
            guard !seen.contains(id),
                  pending.count < 64,
                  method == "window.startDragging" || Self.windowMethods.contains(method) || Self.serviceMethods.contains(method) else {
                throw ShellError.invalidRequest
            }
            remember(id)
            let generation = epoch
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.dispatch(method, params: params)
                    guard !Task.isCancelled, generation == self.epoch else { return }
                    self.finish(id, response: ["v": 1, "epoch": generation, "id": id, "ok": true, "result": result])
                } catch {
                    guard generation == self.epoch else { return }
                    self.finish(id, response: self.failure(id: id, code: error as? ShellError ?? .unavailable))
                }
            }
            let timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(method == "upload" || method == "upload.http" ? 20 : 5))
                guard let self, generation == self.epoch,
                      let request = self.pending[id] else { return }
                request.work.cancel()
                self.finish(id, response: self.failure(id: id, code: .timeout))
            }
            pending[id] = PendingRequest(work: task, timeout: timeout, reply: replyHandler)
        } catch {
            replyHandler(failure(id: id, code: error as? ShellError ?? .invalidRequest), nil)
        }
    }

    private func remember(_ id: String) {
        seen.insert(id)
        seenOrder.append(id)
        if seenOrder.count > 4096, let oldest = seenOrder.first {
            seenOrder.removeFirst()
            seen.remove(oldest)
        }
    }

    private func finish(_ id: String, response: [String: Any]) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.work.cancel()
        request.timeout.cancel()
        request.reply(response, nil)
    }

    private func failure(id: String, code: ShellError) -> [String: Any] {
        ["v": 1, "epoch": epoch, "id": id, "ok": false,
         "error": ["code": code.rawValue, "message": code.rawValue]]
    }

    private func dispatch(_ method: String, params: [String: Any]) async throws -> Any {
        guard let owner else { throw ShellError.unavailable }
        if Self.serviceMethods.contains(method) {
            guard let services, services.availableMethods.contains(method) else { throw ShellError.unavailable }
            return try await services.handle(method: method, params: params)
        }
        switch method {
        case "bootstrap":
            guard params.isEmpty else { throw ShellError.invalidRequest }
            ready = true
            if let state = WindowStateSnapshot(windowState: owner.windowState) {
                _ = stateDeduper.shouldEmit(state)
            }
            return ["v": 1, "epoch": epoch, "runtime": "swift",
                    "methods": Array(Self.windowMethods.union((services?.availableMethods ?? []).intersection(Self.serviceMethods))).sorted(),
                    "window": owner.windowState,
                    "accessibility": [
                        "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                        "increaseContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
                    ]] as [String: Any]
        case "surface.update":
            guard ready else { throw ShellError.unavailable }
            return try owner.updateSurface(params)
        case "window.setFullscreen":
            let key = params["fullscreen"] != nil ? "fullscreen" : "flag"
            guard Set(params.keys) == [key],
                  let flag = params[key] as? NSNumber,
                  CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw ShellError.invalidRequest }
            try owner.setFullscreen(flag.boolValue)
            return NSNull()
        default:
            guard params.isEmpty else { throw ShellError.invalidRequest }
            switch method {
            case "window.getState": return owner.windowState
            case "window.isFullscreen": return owner.isFullscreen
            case "window.toggleFullscreen": try owner.setFullscreen(!owner.isFullscreen)
            case "window.minimize": owner.window?.miniaturize(nil)
            case "window.close":
                // Reply settles before close tears down the page and bridge.
                Task { @MainActor [weak owner] in owner?.close() }
            default: throw ShellError.unsupported
            }
            return NSNull()
        }
    }

    func emitWindowState() {
        guard ready, owner?.acceptsMessages == true else { return }
        stateChange += 1
        guard stateTask == nil else { return }
        let eventEpoch = epoch
        // Native hit maps are invalidated synchronously. Only their replacement
        // metadata crosses WK after geometry settles, with one delivery in flight.
        stateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.epoch == eventEpoch { self.stateTask = nil } }
            while !Task.isCancelled {
                let change = self.stateChange
                do { try await Task.sleep(for: .milliseconds(120)) }
                catch { return }
                guard self.epoch == eventEpoch, let owner = self.owner,
                      owner.acceptsMessages else { return }
                if change != self.stateChange { continue }
                let payload = owner.windowState
                if let state = WindowStateSnapshot(windowState: payload),
                   self.stateDeduper.shouldEmit(state) {
                    self.sequence += 1
                    let event: [String: Any] = ["v": 1, "epoch": eventEpoch, "event": "window.state",
                                                "seq": self.sequence, "payload": payload]
                    _ = try? await owner.webView.callAsyncJavaScript(
                        "window.dispatchEvent(new CustomEvent('agentmirror:native', {detail: event}))",
                        arguments: ["event": event], in: nil, contentWorld: .page
                    )
                }
                if change == self.stateChange { return }
            }
        }
    }
}
