/// Native design constants aligned with desktop Issue #296 dark-mode tokens.
public enum DesignTokens {
    public enum Color {
        public static let background: UInt32 = 0x0F1115
        public static let surface0: UInt32 = 0x171B22
        public static let surface1: UInt32 = 0x1E242D
        public static let surface2: UInt32 = 0x272F3A
        public static let surface3: UInt32 = 0x323D4B
        public static let text: UInt32 = 0xE5E7EB
        public static let textSecondary: UInt32 = 0xB7C0CD
        public static let textMuted: UInt32 = 0x9DAABB
        public static let borderSubtle: UInt32 = 0x2A323E
        public static let border: UInt32 = 0x3A4554
        public static let accent: UInt32 = 0x8FAADC
        public static let success: UInt32 = 0x72BE93
        public static let warning: UInt32 = 0xD8B57B
        public static let danger: UInt32 = 0xF08A93
    }

    public enum Typography {
        public static let uiFontFallbacks = ["-apple-system", "SF Pro Text", "PingFang SC", "Segoe UI", "sans-serif"]
        public static let monospaceFontFallbacks = ["ui-monospace", "SF Mono", "Menlo", "monospace"]
        public static let sizesInPoints: [Double] = [10, 10.5, 11, 11.5, 12, 12.5, 13, 13.5, 15]
    }

    public enum Spacing {
        public static let scaleInPoints: [Double] = [2, 3, 4, 6, 7, 8, 10, 11, 12, 14, 16, 18, 20, 28]
    }

    /// Multi-device badges are compact and never exceed the legacy 64 px cap.
    public static let multiDeviceBadgeMaximumWidthPixels = 64.0
}
