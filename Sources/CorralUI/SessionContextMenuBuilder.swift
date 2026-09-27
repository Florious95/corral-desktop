import AppKit

@MainActor
public final class SessionContextMenuController: NSObject {
    public let sessionID: UUID
    public let menu: NSMenu
    private let rename: (UUID) -> Void
    private let favorite: (UUID, Bool) -> Void
    private let close: (UUID) -> Void
    private let isFavorite: Bool

    public init(
        sessionID: UUID,
        isFavorite: Bool,
        onFavorite: @escaping (UUID, Bool) -> Void,
        onClose: @escaping (UUID) -> Void,
        onRename: @escaping (UUID) -> Void = { _ in }
    ) {
        self.sessionID = sessionID
        self.isFavorite = isFavorite
        rename = onRename
        favorite = onFavorite
        close = onClose
        menu = NSMenu(title: "Agent")
        super.init()
        menu.autoenablesItems = false
        let renameItem = menu.addItem(withTitle: "重命名", action: #selector(renameSession), keyEquivalent: "")
        renameItem.target = self
        renameItem.image = CorralLegacyIcon.image(.edit, size: 15)
        let favoriteItem = menu.addItem(withTitle: isFavorite ? "取消收藏" : "收藏", action: #selector(toggleFavorite), keyEquivalent: "")
        favoriteItem.target = self
        favoriteItem.image = CorralLegacyIcon.image(isFavorite ? .star : .starOutline, size: 15)
        menu.addItem(.separator())
        let closeItem = menu.addItem(withTitle: "关闭", action: #selector(closeSession), keyEquivalent: "")
        closeItem.target = self
        closeItem.image = CorralLegacyIcon.image(.trash, size: 15)
        let copyItem = menu.addItem(withTitle: "复制会话 ID", action: #selector(copySessionID), keyEquivalent: "")
        copyItem.target = self
    }

    @objc private func renameSession() { rename(sessionID) }
    @objc private func toggleFavorite() { favorite(sessionID, !isFavorite) }
    @objc private func closeSession() { close(sessionID) }
    @objc private func copySessionID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sessionID.uuidString, forType: .string)
    }
}

@MainActor
public enum SessionContextMenuBuilder {
    public static func makeMenu(
        for sessionID: UUID,
        isFavorite: Bool = false,
        onFavorite: @escaping (UUID, Bool) -> Void,
        onClose: @escaping (UUID) -> Void,
        onRename: @escaping (UUID) -> Void = { _ in }
    ) -> SessionContextMenuController {
        SessionContextMenuController(sessionID: sessionID, isFavorite: isFavorite, onFavorite: onFavorite, onClose: onClose, onRename: onRename)
    }
}
