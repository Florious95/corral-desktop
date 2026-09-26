import AppKit

@MainActor
public final class SessionContextMenuController: NSObject {
    public let sessionID: UUID
    public let menu: NSMenu

    private let rename: (UUID) -> Void
    private let close: (UUID) -> Void

    public init(sessionID: UUID, onRename: @escaping (UUID) -> Void, onClose: @escaping (UUID) -> Void) {
        self.sessionID = sessionID
        self.rename = onRename
        self.close = onClose
        self.menu = NSMenu(title: "Session")
        super.init()

        menu.autoenablesItems = false
        let renameItem = menu.addItem(withTitle: "Rename Session…", action: #selector(renameSession), keyEquivalent: "")
        renameItem.target = self
        let closeItem = menu.addItem(withTitle: "Close Session", action: #selector(closeSession), keyEquivalent: "")
        closeItem.target = self
    }

    @objc private func renameSession() { rename(sessionID) }
    @objc private func closeSession() { close(sessionID) }
}

@MainActor
public enum SessionContextMenuBuilder {
    public static func makeMenu(
        for sessionID: UUID,
        onRename: @escaping (UUID) -> Void,
        onClose: @escaping (UUID) -> Void
    ) -> SessionContextMenuController {
        SessionContextMenuController(sessionID: sessionID, onRename: onRename, onClose: onClose)
    }
}
