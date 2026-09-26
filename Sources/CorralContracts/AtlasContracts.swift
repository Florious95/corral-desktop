import Foundation

/// The cache key represents shaped glyph output, not a Unicode scalar or nominal font name.
public struct GlyphKey: Codable, Hashable, Sendable {
    public let fontInstanceID: String
    public let glyphID: UInt32
    public let variationSignature: String
    public let rasterWidthPixels: UInt16
    public let rasterHeightPixels: UInt16
    public let rasterScale256: UInt16

    public init(fontInstanceID: String, glyphID: UInt32, variationSignature: String, rasterWidthPixels: UInt16, rasterHeightPixels: UInt16, rasterScale256: UInt16) {
        self.fontInstanceID = fontInstanceID
        self.glyphID = glyphID
        self.variationSignature = variationSignature
        self.rasterWidthPixels = rasterWidthPixels
        self.rasterHeightPixels = rasterHeightPixels
        self.rasterScale256 = rasterScale256
    }
}

public struct AtlasResourceIdentity: Codable, Hashable, Sendable {
    public let deviceDomainID: UUID
    public let resourceID: UUID
    public let generation: UInt64

    public init(deviceDomainID: UUID, resourceID: UUID, generation: UInt64) {
        self.deviceDomainID = deviceDomainID
        self.resourceID = resourceID
        self.generation = generation
    }
}

public struct AtlasCoordinates: Codable, Hashable, Sendable {
    public let page: UInt16
    public let x: UInt16
    public let y: UInt16
    public let width: UInt16
    public let height: UInt16

    public init(page: UInt16, x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        self.page = page
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct GlyphLocation: Codable, Hashable, Sendable {
    public let resource: AtlasResourceIdentity
    public let coordinates: AtlasCoordinates

    public init(resource: AtlasResourceIdentity, coordinates: AtlasCoordinates) {
        self.resource = resource
        self.coordinates = coordinates
    }
}

public struct AtlasMemoryBudget: Codable, Hashable, Sendable {
    public let maximumGPUBytes: UInt64
    public let maximumPages: UInt32
    public let maximumCPUShadowBytes: UInt64

    public init(maximumGPUBytes: UInt64, maximumPages: UInt32, maximumCPUShadowBytes: UInt64) {
        self.maximumGPUBytes = maximumGPUBytes
        self.maximumPages = maximumPages
        self.maximumCPUShadowBytes = maximumCPUShadowBytes
    }
}

/// A reservation is an atomic budget claim covering staging, live, and retired-in-flight resources.
public struct AtlasReservation: Codable, Hashable, Sendable {
    public let reservationID: UUID
    public let resource: AtlasResourceIdentity
    public let gpuBytes: UInt64
    public let pages: UInt32
    public let cpuShadowBytes: UInt64

    public init(reservationID: UUID, resource: AtlasResourceIdentity, gpuBytes: UInt64, pages: UInt32, cpuShadowBytes: UInt64) {
        self.reservationID = reservationID
        self.resource = resource
        self.gpuBytes = gpuBytes
        self.pages = pages
        self.cpuShadowBytes = cpuShadowBytes
    }
}

/// Immutable per-frame snapshot. The renderer retains all referenced generations until `release`.
public struct FrameAtlasLease: Equatable, Sendable {
    public let leaseID: UUID
    public let resources: Set<AtlasResourceIdentity>
    public let locations: [GlyphKey: GlyphLocation]

    public init(leaseID: UUID, resources: Set<AtlasResourceIdentity>, locations: [GlyphKey: GlyphLocation]) {
        self.leaseID = leaseID
        self.resources = resources
        self.locations = locations
    }
}

public enum AtlasLifecycleError: Error, Equatable, Sendable {
    case budgetExceeded
    case staleGeneration
    case unknownReservation
    case missingGlyph
    case resourceStillLeased
}

/// Mutations are batched and async; implementations must serialize ownership and reserve all budgets atomically.
public protocol SharedGlyphAtlas: Sendable {
    var memoryBudget: AtlasMemoryBudget { get async }
    func reserve(gpuBytes: UInt64, pages: UInt32, cpuShadowBytes: UInt64) async throws -> AtlasReservation
    func publish(_ reservation: AtlasReservation, locations: [GlyphKey: AtlasCoordinates]) async throws
    /// Missing glyphs fail the batch; no valid coordinate (including the origin) is a missing sentinel.
    func leaseGlyphs(_ keys: [GlyphKey]) async throws -> FrameAtlasLease
    /// Removes this generation from future lookup without invalidating extant frame leases.
    func retire(_ resource: AtlasResourceIdentity) async throws
    func release(_ lease: FrameAtlasLease) async
    /// Reclaims retired resources only after their final frame lease is released.
    func reclaimRetired() async throws -> [AtlasResourceIdentity]
}
