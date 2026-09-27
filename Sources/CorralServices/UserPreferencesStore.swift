import Foundation

public enum ThemePreference: String, Codable, Sendable {
    case dark
    case light
    case system
}

public struct UserPreferences: Codable, Equatable, Sendable {
    public static let defaultFontFamily = "Cascadia Code, Consolas, Fira Code, JetBrains Mono, Menlo, Monaco, \"AgentMirror Symbols\", \"Symbols Nerd Font Mono\", \"Symbols Nerd Font\", \"JetBrainsMono Nerd Font Mono\", \"JetBrainsMono NFM\", \"Apple Symbols\", \"Segoe UI Symbol\", monospace"
    public static let minimumFontSize = 11
    public static let maximumFontSize = 22

    public var theme: ThemePreference
    public var fontFamily: String
    public var fontSize: Int
    public var followDirectory: Bool
    public var sidebarCollapsed: Bool

    public init(
        theme: ThemePreference = .system,
        fontFamily: String = Self.defaultFontFamily,
        fontSize: Int = 13,
        followDirectory: Bool = false,
        sidebarCollapsed: Bool = false
    ) {
        self.theme = theme
        self.fontFamily = Self.normalizedFontFamily(fontFamily)
        self.fontSize = Self.clampedFontSize(fontSize)
        self.followDirectory = followDirectory
        self.sidebarCollapsed = sidebarCollapsed
    }

    private static func normalizedFontFamily(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultFontFamily : value
    }

    private static func clampedFontSize(_ value: Int) -> Int {
        min(maximumFontSize, max(minimumFontSize, value))
    }

    private enum CodingKeys: String, CodingKey { case theme, fontFamily, fontSize, followDirectory, sidebarCollapsed }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let themeRaw = (try? values.decode(String.self, forKey: .theme)) ?? ThemePreference.system.rawValue
        let fontFamily = (try? values.decode(String.self, forKey: .fontFamily)) ?? Self.defaultFontFamily
        let fontSize = (try? values.decode(Int.self, forKey: .fontSize)) ?? 13
        self.init(
            theme: ThemePreference(rawValue: themeRaw) ?? .system,
            fontFamily: fontFamily,
            fontSize: fontSize,
            followDirectory: (try? values.decode(Bool.self, forKey: .followDirectory)) ?? false,
            sidebarCollapsed: (try? values.decode(Bool.self, forKey: .sidebarCollapsed)) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(theme, forKey: .theme)
        try values.encode(fontFamily, forKey: .fontFamily)
        try values.encode(fontSize, forKey: .fontSize)
        try values.encode(followDirectory, forKey: .followDirectory)
        try values.encode(sidebarCollapsed, forKey: .sidebarCollapsed)
    }
}

/// Isolated 0600 store for native-only user settings; it never reads legacy localStorage.
public actor UserPreferencesStore {
    public static let storageFilename = "preferences.json"

    private let storageURL: URL
    private var value: UserPreferences

    public init(applicationSupportDirectory: URL? = nil) throws {
        let directory = try CorralPrivateStorage.directoryURL(applicationSupportDirectory: applicationSupportDirectory)
        let storageURL = directory.appendingPathComponent(Self.storageFilename)
        self.storageURL = storageURL
        if let data = try CorralPrivateStorage.readData(from: storageURL),
           let restored = try? JSONDecoder().decode(UserPreferences.self, from: data) {
            value = restored
        } else {
            value = UserPreferences()
            try Self.persist(value, to: storageURL)
        }
    }

    public func snapshot() -> UserPreferences { value }

    @discardableResult
    public func update(_ preferences: UserPreferences) throws -> UserPreferences {
        try save(UserPreferences(
            theme: preferences.theme,
            fontFamily: preferences.fontFamily,
            fontSize: preferences.fontSize,
            followDirectory: preferences.followDirectory,
            sidebarCollapsed: preferences.sidebarCollapsed
        ))
        return value
    }

    @discardableResult
    public func setTheme(_ theme: ThemePreference) throws -> UserPreferences {
        var next = value
        next.theme = theme
        try save(next)
        return value
    }

    @discardableResult
    public func setFontFamily(_ fontFamily: String) throws -> UserPreferences {
        var next = value
        next.fontFamily = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? UserPreferences.defaultFontFamily : fontFamily
        try save(next)
        return value
    }

    @discardableResult
    public func setFontSize(_ fontSize: Int) throws -> UserPreferences {
        var next = value
        next.fontSize = min(UserPreferences.maximumFontSize, max(UserPreferences.minimumFontSize, fontSize))
        try save(next)
        return value
    }

    @discardableResult
    public func setFollowDirectory(_ enabled: Bool) throws -> UserPreferences {
        var next = value
        next.followDirectory = enabled
        try save(next)
        return value
    }

    @discardableResult
    public func setSidebarCollapsed(_ collapsed: Bool) throws -> UserPreferences {
        var next = value
        next.sidebarCollapsed = collapsed
        try save(next)
        return value
    }

    private func save(_ next: UserPreferences) throws {
        guard next != value else { return }
        try Self.persist(next, to: storageURL)
        value = next
    }

    private static func persist(_ preferences: UserPreferences, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try CorralPrivateStorage.atomicallyWrite(encoder.encode(preferences), to: url)
    }
}
