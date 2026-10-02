# Corral Terminal Symbols

`CorralTerminalSymbols.ttf` is a project-owned, two-glyph terminal fallback, not a subset of an external font.

- U+1F5AB reuses the existing project's `public/fonts/AgentMirrorSymbols.ttf` outline from the legacy client (commit `733f5da354ccb8879ea1f4069ee90f73fb224891`, Issue #277). Its horizontal coordinates are scaled by 0.6 to fit a single monospace cell.
- U+E0A0 is an original Git-branch outline: a vertical stem, curved fork, and three outlined nodes. No third-party font outlines are used.
- Both advances are 600 units at 1,000 units/em. The unique PostScript name is `CorralTerminalSymbols-Regular` to avoid colliding with the legacy font.

The bundled font is registered only within the Corral process. Its descriptor precedes the terminal font's existing/system cascade; it does not replace the selected text font, install a system font, or rewrite terminal output.
