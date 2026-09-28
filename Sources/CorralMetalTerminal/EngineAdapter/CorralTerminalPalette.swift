import SwiftTerm

/// ANSI palette shared by the native terminal view and terminal engine.
public enum CorralTerminalPalette {
    /// SwiftTerm palette derived from Corral's dark theme; SwiftTerm expands it to 256 colors.
    public static var darkANSI16: [SwiftTerm.Color] {
        TerminalThemePalette.dark.ansi16.map {
            SwiftTerm.Color(red8: UInt16($0.red), green8: UInt16($0.green), blue8: UInt16($0.blue))
        }
    }
}
