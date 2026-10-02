# SwiftTerm provenance

Vendored build inputs and tests from [SwiftTerm 1.20.0](https://github.com/migueldeicaza/SwiftTerm), commit `5d14406844143538cd8f8851d2d8a67c1fe443e5` (Git archive: `Package.swift`, `LICENSE`, `Sources`, `Plugins`, `Tests`). The upstream MIT license is retained in `LICENSE`.

Local Issue 26 changes are confined to:

- `Package.swift`: optimize the macOS debug engine, matching Corral's optimized development app; release settings are unchanged.
- `Sources/SwiftTerm/Buffer.swift`: skip paragraphs that reflow would discard, rearrange history in one pass, and defer ordinary narrowed history rows.
- `Sources/SwiftTerm/BufferLine.swift`: keep original cells and attributes alive until a deferred row is requested; materialize disjoint slices without copying and copy boundary rows. Allocation owners are flattened across subsequent reflows.
- `Sources/SwiftTerm/CircularList.swift`: carry deferred row metadata through circular-list operations and materialize on access. Full-array consumers still see all rows, including hyperlink-payload garbage collection.

Reflow preserves the existing cursor/viewport calculations and scrollback capacity. Image, semantic-mark, hard-continuation and non-single-render paragraphs retain upstream's eager path. All access remains on the terminal's owning thread; this is not concurrent parsing or dropped scrollback. Later width changes, search and full-buffer inspection may still visit all retained history.

The unmodified upstream test package also has five `MetalRendererStatusTests` failures locating `Apple/Metal/Shaders.metal` in this checkout environment. Do not treat those tests as passing or alter their assertions to hide the failure.
