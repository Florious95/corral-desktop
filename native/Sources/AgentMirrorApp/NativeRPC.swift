import Foundation
import WebKit

/// A1 seam only. Capability implementations land in the next phase; keeping
/// the envelope and handler name here prevents transport-specific drift.
@MainActor
final class NativeRPC: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "native"
    private static let maxIDLength = 128
    private static let maxMethodLength = 128

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "agentmirror",
              message.frameInfo.securityOrigin.host == "app"
        else {
            replyHandler(nil, "native RPC origin rejected")
            return
        }

        guard let body = message.body as? [String: Any] else {
            replyHandler(nil, "native RPC body must be an object")
            return
        }
        guard let version = (body["v"] as? NSNumber)?.intValue, version == 1 else {
            replyHandler(nil, "native RPC version unsupported")
            return
        }
        guard let id = body["id"] as? String,
              !id.isEmpty,
              id.utf8.count <= Self.maxIDLength
        else {
            replyHandler(nil, "native RPC id invalid")
            return
        }
        guard let method = body["method"] as? String,
              !method.isEmpty,
              method.utf8.count <= Self.maxMethodLength
        else {
            replyHandler(response(id: id, ok: false, error: [
                "code": "invalid_request",
                "message": "native RPC method invalid",
            ]), nil)
            return
        }

        // Both names are accepted during the seam transition. The target
        // frontend currently sends `args`; `params` is retained as the locked
        // envelope alias for clients that adopted the newer wording.
        if let args = body["args"] ?? body["params"], !(args is [String: Any]) {
            replyHandler(response(id: id, ok: false, error: [
                "code": "invalid_request",
                "message": "native RPC args must be an object",
            ]), nil)
            return
        }

        NSLog("AgentMirror native RPC unavailable in A1: %@", method)
        replyHandler(response(id: id, ok: false, error: [
            "code": "unsupported_method",
            "message": "native capability is not implemented in A1",
        ]), nil)
    }

    private func response(
        id: String,
        ok: Bool,
        result: Any? = nil,
        error: [String: String]? = nil
    ) -> [String: Any] {
        var value: [String: Any] = ["v": 1, "id": id, "ok": ok]
        if let result { value["result"] = result }
        if let error { value["error"] = error }
        return value
    }
}
