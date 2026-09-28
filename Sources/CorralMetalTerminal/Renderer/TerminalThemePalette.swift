import Foundation

public enum TerminalThemeAppearance: Equatable, Sendable {
    case dark
    case light
}

public struct TerminalPaletteColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: Float

    public var hexRGB: String {
        String(format: "#%02x%02x%02x", red, green, blue)
    }

    public var components: SIMD4<Float> {
        SIMD4(Float(red) / 255, Float(green) / 255, Float(blue) / 255, alpha)
    }

    fileprivate init(hex: String, alpha: Float = 1) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        red = UInt8((value >> 16) & 0xFF)
        green = UInt8((value >> 8) & 0xFF)
        blue = UInt8(value & 0xFF)
        self.alpha = alpha
    }

    fileprivate init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        alpha = 1
    }
}

public struct TerminalThemePalette: Equatable, Sendable {
    public let background: TerminalPaletteColor
    public let foreground: TerminalPaletteColor
    public let cursor: TerminalPaletteColor
    public let cursorAccent: TerminalPaletteColor
    public let selectionBackground: TerminalPaletteColor
    public let selectionForeground: TerminalPaletteColor?
    public let ansi16: [TerminalPaletteColor]

    public static let dark = TerminalThemePalette(
        background: .init(hex: "#0f1115"),
        foreground: .init(hex: "#D5DCE6"),
        cursor: .init(hex: "#D5DCE6"),
        cursorAccent: .init(hex: "#0f1115"),
        selectionBackground: .init(hex: "#7aa2f7", alpha: 0.3),
        selectionForeground: .init(hex: "#ffffff"),
        ansi16: [
            "#414868", "#f7768e", "#9ece6a", "#e0af68",
            "#7aa2f7", "#bb9af7", "#7dcfff", "#282f39",
            "#787c99", "#ff899d", "#b9f27c", "#ffc777",
            "#82aaff", "#c099ff", "#86e1fc", "#282f39"
        ].map { TerminalPaletteColor(hex: $0) }
    )

    public static let light = TerminalThemePalette(
        background: .init(hex: "#fbfaf8"),
        foreground: .init(hex: "#3a3835"),
        cursor: .init(hex: "#3a3835"),
        cursorAccent: .init(hex: "#fbfaf8"),
        selectionBackground: .init(red: 0, green: 0, blue: 0, alpha: 0.12),
        selectionForeground: nil,
        ansi16: [
            "#343b58", "#8c2438", "#2b6a4a", "#8c5a1e",
            "#2e5898", "#6f3b89", "#1f687a", "#fbfaf8",
            "#68707a", "#a83446", "#387a56", "#a86c24",
            "#3a68b0", "#8448a4", "#28788c", "#3a3835"
        ].map { TerminalPaletteColor(hex: $0) }
    )

    public func color(forANSIIndex index: UInt8) -> TerminalPaletteColor {
        let value = Int(index)
        if value < ansi16.count { return ansi16[value] }
        if value < 232 {
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            let cube = value - 16
            return TerminalPaletteColor(red: levels[cube / 36], green: levels[(cube / 6) % 6], blue: levels[cube % 6])
        }
        let gray = UInt8(8 + (value - 232) * 10)
        return TerminalPaletteColor(red: gray, green: gray, blue: gray)
    }

    fileprivate init(
        background: TerminalPaletteColor,
        foreground: TerminalPaletteColor,
        cursor: TerminalPaletteColor,
        cursorAccent: TerminalPaletteColor,
        selectionBackground: TerminalPaletteColor,
        selectionForeground: TerminalPaletteColor?,
        ansi16: [TerminalPaletteColor]
    ) {
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.cursorAccent = cursorAccent
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.ansi16 = ansi16
    }
}

extension TerminalPaletteColor {
    fileprivate init(red: UInt8, green: UInt8, blue: UInt8, alpha: Float) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}