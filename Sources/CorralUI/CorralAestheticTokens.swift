import AppKit
import CorralContracts

@MainActor
public enum CorralAestheticTokens {
    public static func color(_ rgb: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    public static let background = color(DesignTokens.Color.background)
    public static let surface0 = color(DesignTokens.Color.surface0)
    public static let surface1 = color(DesignTokens.Color.surface1)
    public static let surface2 = color(DesignTokens.Color.surface2)
    public static let surface3 = color(DesignTokens.Color.surface3)
    public static let text = color(DesignTokens.Color.text)
    public static let textSecondary = color(DesignTokens.Color.textSecondary)
    public static let textMuted = color(DesignTokens.Color.textMuted)
    public static let borderSubtle = color(DesignTokens.Color.borderSubtle)
    public static let border = color(DesignTokens.Color.border)
    public static let accent = color(DesignTokens.Color.accent)
    public static let success = color(DesignTokens.Color.success)
    public static let warning = color(DesignTokens.Color.warning)
    public static let danger = color(DesignTokens.Color.danger)

    public static let multiDeviceBadgeMaximumWidth = CGFloat(DesignTokens.multiDeviceBadgeMaximumWidthPixels)
}
