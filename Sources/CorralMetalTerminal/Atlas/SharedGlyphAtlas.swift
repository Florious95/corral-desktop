import CorralContracts

/// One app-wide glyph pool shared by all terminal stages; eviction returns zeroed coordinates.
public protocol SharedGlyphAtlas: Sendable {
    var memoryBudget: AtlasMemoryBudget { get }
    var allocatedBytes: UInt64 { get }
    func coordinates(for key: GlyphKey) -> AtlasCoordinates
    func evict(_ key: GlyphKey) async
}
