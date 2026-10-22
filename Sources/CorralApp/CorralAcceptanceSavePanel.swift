#if DEBUG
import ApplicationServices
import Foundation

/// Only the opt-in acceptance app's AX sheets; never global input or another application's UI.
/// macOS 26's remote NSSavePanel.ok: raises NSGenericException ("not implemented").
/// Run off the main actor so this process can service the real native AXPress request.
enum CorralAcceptanceSavePanel {
    enum Failure: Error { case permissionRequired, missingButton }

    static func press(prompt: String) throws {
        guard AXIsProcessTrusted(), !prompt.isEmpty else { throw Failure.permissionRequired }
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
            return result
        }
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 0.5)
        var queue = (value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).map { ($0, false) }
        var seen: [AXUIElement] = [], buttons: [AXUIElement] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !queue.isEmpty, seen.count < 256, ProcessInfo.processInfo.systemUptime < deadline {
            let (node, parentIsSheet) = queue.removeFirst()
            if seen.contains(where: { CFEqual($0, node) }) { continue }
            seen.append(node)
            AXUIElementSetMessagingTimeout(node, 0.5)
            let role = value(node, kAXRoleAttribute) as? String
            let inSheet = parentIsSheet || role == kAXSheetRole
            if inSheet, role == kAXButtonRole, value(node, kAXTitleAttribute) as? String == prompt { buttons.append(node) }
            queue.append(contentsOf: (value(node, kAXChildrenAttribute) as? [AXUIElement] ?? []).map { ($0, inSheet) })
        }
        guard queue.isEmpty, buttons.count == 1, AXUIElementPerformAction(buttons[0], kAXPressAction as CFString) == .success else { throw Failure.missingButton }
    }
}
#endif
