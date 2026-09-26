import AppKit

@MainActor
public final class SessionContextMenuController: NSObject {
    public let sessionID: UUID
    public let menu: NSMenu
    private let favorite: (UUID, Bool) -> Void
    private let close: (UUID) -> Void
    private let isFavorite: Bool

    public init(sessionID: UUID, isFavorite: Bool, onFavorite: @escaping (UUID, Bool) -> Void, onClose: @escaping (UUID) -> Void) {
        self.sessionID = sessionID
        self.isFavorite = isFavorite
        favorite = onFavorite
        close = onClose
        menu = NSMenu(title: "Agent")
        super.init()
        menu.autoenablesItems = false
        let favoriteItem = menu.addItem(withTitle: isFavorite ? "取消收藏" : "收藏", action: #selector(toggleFavorite), keyEquivalent: "")
        favoriteItem.target = self
        favoriteItem.image = CorralLegacyIcon.image(isFavorite ? .star : .starOutline, size: 15)
        menu.addItem(.separator())
        let closeItem = menu.addItem(withTitle: "关闭", action: #selector(closeSession), keyEquivalent: "")
        closeItem.target = self
        closeItem.image = CorralLegacyIcon.image(.trash, size: 15)
    }

    @objc private func toggleFavorite() { favorite(sessionID, !isFavorite) }
    @objc private func closeSession() { close(sessionID) }
}

@MainActor
public enum SessionContextMenuBuilder {
    public static func makeMenu(
        for sessionID: UUID,
        isFavorite: Bool = false,
        onFavorite: @escaping (UUID, Bool) -> Void,
        onClose: @escaping (UUID) -> Void
    ) -> SessionContextMenuController {
        SessionContextMenuController(sessionID: sessionID, isFavorite: isFavorite, onFavorite: onFavorite, onClose: onClose)
    }
}
