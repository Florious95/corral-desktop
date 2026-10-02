# Corral Terminal Git Branch Symbols

`CorralTerminalSymbols.ttf` contains only U+F418, the Git branch character emitted by Pi's status bar (`nf-oct-git_branch`). Its three-node branch outline is original Corral artwork, reused from the project's historical Git branch asset; no third-party font outlines are included.

- PostScript name: `CorralTerminalGitBranchSymbols-Regular`.
- One symbol glyph; 600-unit advance at 1,000 units/em.
- No U+1F5AB or U+E0A0 mapping is included.
- Registered only for the current process. The selected terminal text font and its existing/system cascade remain intact.
- SwiftPM copies this directory into its resource bundle; `Scripts/package-app.sh` copies the font into the development app's `Contents/Resources/Fonts/`. Packaged apps resolve their own asset, not a build-directory copy.
