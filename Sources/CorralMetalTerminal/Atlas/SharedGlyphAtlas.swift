import CoreGraphics
import CoreText
import Foundation
import Metal
import CorralContracts

public protocol MetalGlyphAtlas: CorralContracts.SharedGlyphAtlas {}

public enum GlyphAtlasPixelFormat: Sendable, Equatable {
    case coverageR8
    case colorBGRA8

    fileprivate var metalFormat: MTLPixelFormat {
        switch self {
        case .coverageR8: .r8Unorm
        case .colorBGRA8: .bgra8Unorm
        }
    }

    fileprivate var bytesPerPixel: Int {
        switch self {
        case .coverageR8: 1
        case .colorBGRA8: 4
        }
    }
}

public struct GlyphAtlasEntry: Sendable, Equatable {
    public let coordinates: AtlasCoordinates
    public let format: GlyphAtlasPixelFormat
    public let advanceX: Double
    public let imageOriginX: Double
    public let imageOriginY: Double
    public let ascent: Double
    public let descent: Double
    public let leading: Double
}

public struct GlyphAtlasStatistics: Sendable, Equatable {
    public let cacheHits: UInt64
    public let cacheMisses: UInt64
    public let rasterizedGlyphs: UInt64
    public let evictedPages: UInt64
    public let zeroFilledEvictions: UInt64
    public let pageCount: UInt32
    public let allocatedBytes: UInt64
}

/// The app-wide pool. All terminal panes should use `shared`, never own a pool.
public final class GlyphAtlasPool: MetalGlyphAtlas, @unchecked Sendable {
    public static let shared = GlyphAtlasPool(
        device: MTLCreateSystemDefaultDevice(),
        memoryBudget: .appDefault,
        pageSize: 1024
    )

    public let memoryBudget: AtlasMemoryBudget
    private let device: MTLDevice?
    private let basePageSize: Int
    private let maximumTextureDimension: Int
    private let lock = NSLock()
    private var pages: [UInt16: AtlasPage] = [:]
    private var glyphs: [GlyphRequest: CachedGlyph] = [:]
    private var nextPageIndex: UInt32 = 0
    private var accessClock: UInt64 = 0
    private var byteCount: UInt64 = 0
    private var cacheHitCount: UInt64 = 0
    private var cacheMissCount: UInt64 = 0
    private var rasterizedCount: UInt64 = 0
    private var evictedPageCount: UInt64 = 0
    private var zeroFilledEvictionCount: UInt64 = 0
    private let deviceDomainID = UUID()
    private var nextResourceGeneration: UInt64 = 0
    private var pendingAtlasReservations: [UUID: AtlasReservation] = [:]
    private var contractResources: [AtlasResourceIdentity: ManagedAtlasResource] = [:]
    private var contractLocations: [GlyphKey: GlyphLocation] = [:]
    private var activeFrameLeases: [UUID: Set<AtlasResourceIdentity>] = [:]
    private var pageResourceOwners: [UInt16: AtlasResourceIdentity] = [:]
    private var reservedGPUBytes: UInt64 = 0
    private var reservedPages: UInt32 = 0
    private var reservedCPUShadowBytes: UInt64 = 0

    init(device: MTLDevice?, memoryBudget: AtlasMemoryBudget, pageSize: Int) {
        self.device = device
        self.memoryBudget = memoryBudget
        let deviceLimit = device == nil ? 0 : 16_384 // Conservative 2D texture limit for macOS Metal devices.
        self.maximumTextureDimension = min(deviceLimit, Int(UInt16.max))
        self.basePageSize = min(max(pageSize, 16), self.maximumTextureDimension)
    }

    public var allocatedBytes: UInt64 { synchronized { byteCount } }

    public var statistics: GlyphAtlasStatistics {
        synchronized {
            GlyphAtlasStatistics(
                cacheHits: cacheHitCount,
                cacheMisses: cacheMissCount,
                rasterizedGlyphs: rasterizedCount,
                evictedPages: evictedPageCount,
                zeroFilledEvictions: zeroFilledEvictionCount,
                pageCount: UInt32(pages.count),
                allocatedBytes: byteCount
            )
        }
    }

    /// Returns no location for an absent glyph; the atlas origin is never a missing sentinel.
    public func coordinates(for key: GlyphKey) -> AtlasCoordinates? {
        let request = request(for: key)
        return synchronized {
            guard let cached = glyphs[request] else { return nil }
            if let pageIndex = cached.pageIndex,
               let resource = pageResourceOwners[pageIndex],
               contractResources[resource]?.retired == true { return nil }
            touch(cached.pageIndex)
            cacheHitCount &+= 1
            return cached.entry.coordinates
        }
    }

    /// Rasterizes one already-shaped CoreText glyph ID.
    public func glyph(for key: GlyphKey) -> GlyphAtlasEntry? {
        synchronized { glyphLocked(for: request(for: key)) }
    }

    private func request(for key: GlyphKey) -> GlyphRequest {
        GlyphRequest(
            text: "",
            fontPostScriptName: key.fontInstanceID,
            pixelSize: key.rasterHeightPixels,
            isBold: false,
            isItalic: false,
            glyphKey: key
        )
    }

    /// Accepts a complete grapheme cluster so emoji ZWJ sequences are shaped as a unit.
    public func glyph(
        for text: String,
        fontPostScriptName: String,
        pixelSize: UInt16,
        isBold: Bool = false,
        isItalic: Bool = false
    ) -> GlyphAtlasEntry? {
        let request = GlyphRequest(
            text: text,
            fontPostScriptName: fontPostScriptName,
            pixelSize: pixelSize,
            isBold: isBold,
            isItalic: isItalic,
            glyphKey: nil
        )
        return synchronized { glyphLocked(for: request) }
    }

    public func texture(forPage index: UInt16) -> MTLTexture? {
        synchronized { pages[index]?.texture }
    }

    /// Convenience for tests and diagnostics; eviction remains page-granular and zero-fills first.
    public func evict(_ key: GlyphKey) async {
        let request = request(for: key)
        synchronized {
            guard let cached = glyphs[request], let pageIndex = cached.pageIndex else { return }
            _ = evictPage(pageIndex)
        }
    }

    public func reserve(gpuBytes: UInt64, pages: UInt32, cpuShadowBytes: UInt64) async throws -> AtlasReservation {
        try synchronized {
            let (gpuTotal, gpuOverflow) = byteCount.addingReportingOverflow(reservedGPUBytes)
            let (pageTotal, pageOverflow) = UInt64(self.pages.count).addingReportingOverflow(UInt64(reservedPages))
            let (shadowTotal, shadowOverflow) = reservedCPUShadowBytes.addingReportingOverflow(cpuShadowBytes)
            guard !gpuOverflow, !pageOverflow, !shadowOverflow,
                  memoryBudget.allowsAllocation(currentBytes: gpuTotal, additionalBytes: gpuBytes),
                  pageTotal + UInt64(pages) <= UInt64(memoryBudget.maximumPages),
                  shadowTotal <= memoryBudget.maximumCPUShadowBytes,
                  nextResourceGeneration < UInt64.max else { throw AtlasLifecycleError.budgetExceeded }
            nextResourceGeneration += 1
            let resource = AtlasResourceIdentity(
                deviceDomainID: deviceDomainID,
                resourceID: UUID(),
                generation: nextResourceGeneration
            )
            let reservation = AtlasReservation(
                reservationID: UUID(), resource: resource,
                gpuBytes: gpuBytes, pages: pages, cpuShadowBytes: cpuShadowBytes
            )
            let (newGPU, gpuAddOverflow) = reservedGPUBytes.addingReportingOverflow(gpuBytes)
            let (newPages, pageAddOverflow) = reservedPages.addingReportingOverflow(pages)
            guard !gpuAddOverflow, !pageAddOverflow else { throw AtlasLifecycleError.budgetExceeded }
            reservedGPUBytes = newGPU
            reservedPages = newPages
            reservedCPUShadowBytes = shadowTotal
            pendingAtlasReservations[reservation.reservationID] = reservation
            return reservation
        }
    }

    public func publish(_ reservation: AtlasReservation, locations: [GlyphKey: AtlasCoordinates]) async throws {
        try synchronized {
            guard pendingAtlasReservations[reservation.reservationID] == reservation else {
                throw AtlasLifecycleError.unknownReservation
            }
            guard !locations.isEmpty else { throw AtlasLifecycleError.missingGlyph }
            var pageIndices = Set<UInt16>()
            var shadowBytes: UInt64 = 0
            for (key, coordinates) in locations {
                guard coordinates.width > 0, coordinates.height > 0,
                      let cached = glyphs[request(for: key)],
                      cached.entry.coordinates == coordinates,
                      let pageIndex = cached.pageIndex,
                      pages[pageIndex] != nil else { throw AtlasLifecycleError.missingGlyph }
                guard pageResourceOwners[pageIndex] == nil else { throw AtlasLifecycleError.staleGeneration }
                pageIndices.insert(pageIndex)
                let (keyBytes, keyOverflow) = UInt64(key.fontInstanceID.utf8.count + key.variationSignature.utf8.count + 64)
                    .addingReportingOverflow(UInt64(MemoryLayout<AtlasCoordinates>.size))
                let (newShadow, shadowOverflow) = shadowBytes.addingReportingOverflow(keyBytes)
                guard !keyOverflow, !shadowOverflow else { throw AtlasLifecycleError.budgetExceeded }
                shadowBytes = newShadow
            }
            let actualGPUBytes = pageIndices.reduce(UInt64(0)) { total, index in
                let (sum, overflow) = total.addingReportingOverflow(pages[index]?.byteCount ?? UInt64.max)
                return overflow ? UInt64.max : sum
            }
            guard pageIndices.count <= Int(reservation.pages), actualGPUBytes <= reservation.gpuBytes,
                  shadowBytes <= reservation.cpuShadowBytes else { throw AtlasLifecycleError.budgetExceeded }
            let mapped = locations.mapValues { GlyphLocation(resource: reservation.resource, coordinates: $0) }
            let resource = ManagedAtlasResource(
                reservation: reservation,
                locations: mapped,
                pageIndices: pageIndices,
                leaseCount: 0,
                retired: false
            )
            for index in pageIndices { pageResourceOwners[index] = reservation.resource }
            for (key, location) in mapped { contractLocations[key] = location }
            pendingAtlasReservations.removeValue(forKey: reservation.reservationID)
            contractResources[reservation.resource] = resource
        }
    }

    public func leaseGlyphs(_ keys: [GlyphKey]) async throws -> FrameAtlasLease {
        try synchronized {
            var locations: [GlyphKey: GlyphLocation] = [:]
            var resources = Set<AtlasResourceIdentity>()
            for key in keys {
                guard let location = contractLocations[key],
                      let resource = contractResources[location.resource], !resource.retired else {
                    throw AtlasLifecycleError.missingGlyph
                }
                locations[key] = location
                resources.insert(location.resource)
            }
            for identity in resources {
                guard var resource = contractResources[identity], resource.leaseCount < UInt32.max else {
                    throw AtlasLifecycleError.staleGeneration
                }
                for pageIndex in resource.pageIndices {
                    guard var page = pages[pageIndex], page.leaseCount < UInt32.max else {
                        throw AtlasLifecycleError.staleGeneration
                    }
                    page.leaseCount += 1
                    pages[pageIndex] = page
                }
                resource.leaseCount += 1
                contractResources[identity] = resource
            }
            let leaseID = UUID()
            activeFrameLeases[leaseID] = resources
            return FrameAtlasLease(leaseID: leaseID, resources: resources, locations: locations)
        }
    }

    public func retire(_ resource: AtlasResourceIdentity) async throws {
        try synchronized {
            guard var managed = contractResources[resource] else { throw AtlasLifecycleError.unknownReservation }
            guard !managed.retired else { throw AtlasLifecycleError.staleGeneration }
            managed.retired = true
            contractResources[resource] = managed
            contractLocations = contractLocations.filter { $0.value.resource != resource }
        }
    }

    public func release(_ lease: FrameAtlasLease) async {
        synchronized {
            guard let resources = activeFrameLeases.removeValue(forKey: lease.leaseID) else { return }
            for identity in resources {
                guard var resource = contractResources[identity], resource.leaseCount > 0 else { continue }
                resource.leaseCount -= 1
                contractResources[identity] = resource
                for pageIndex in resource.pageIndices {
                    guard var page = pages[pageIndex], page.leaseCount > 0 else { continue }
                    page.leaseCount -= 1
                    pages[pageIndex] = page
                }
            }
        }
    }

    public func reclaimRetired() async throws -> [AtlasResourceIdentity] {
        try synchronized {
            let reclaimable = contractResources.values.filter { $0.retired && $0.leaseCount == 0 }
            var reclaimed: [AtlasResourceIdentity] = []
            for resource in reclaimable {
                for pageIndex in resource.pageIndices {
                    pageResourceOwners.removeValue(forKey: pageIndex)
                    guard evictPage(pageIndex) else { throw AtlasLifecycleError.resourceStillLeased }
                }
                reservedGPUBytes -= resource.reservation.gpuBytes
                reservedPages -= resource.reservation.pages
                reservedCPUShadowBytes -= resource.reservation.cpuShadowBytes
                contractResources.removeValue(forKey: resource.reservation.resource)
                reclaimed.append(resource.reservation.resource)
            }
            return reclaimed
        }
    }

    private func glyphLocked(for request: GlyphRequest) -> GlyphAtlasEntry? {
        guard request.glyphKey != nil || !request.text.isEmpty, request.pixelSize > 0 else { return nil }
        if let cached = glyphs[request] {
            if let pageIndex = cached.pageIndex,
               let resource = pageResourceOwners[pageIndex],
               contractResources[resource]?.retired == true { return nil }
            touch(cached.pageIndex)
            cacheHitCount &+= 1
            return cached.entry
        }
        cacheMissCount &+= 1
        guard let raster = rasterize(request) else { return nil }
        rasterizedCount &+= 1

        guard raster.width <= maximumTextureDimension - 2,
              raster.height <= maximumTextureDimension - 2,
              let pageIndex = findOrCreatePage(for: raster),
              var page = pages[pageIndex],
              let texture = page.texture,
              let position = place(width: raster.width + 2, height: raster.height + 2, in: &page)
        else { return nil }

        let x = position.x + 1
        let y = position.y + 1
        let region = MTLRegionMake2D(x, y, raster.width, raster.height)
        raster.bytes.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: address,
                bytesPerRow: raster.width * raster.format.bytesPerPixel
            )
        }
        page.glyphs.insert(request)
        page.lastAccess = tick()
        pages[pageIndex] = page
        let entry = GlyphAtlasEntry(
            coordinates: AtlasCoordinates(
                page: pageIndex,
                x: UInt16(x),
                y: UInt16(y),
                width: UInt16(raster.width),
                height: UInt16(raster.height)
            ),
            format: raster.format,
            advanceX: raster.advanceX,
            imageOriginX: raster.imageOriginX,
            imageOriginY: raster.imageOriginY,
            ascent: raster.ascent,
            descent: raster.descent,
            leading: raster.leading
        )
        glyphs[request] = CachedGlyph(entry: entry, pageIndex: pageIndex)
        return entry
    }

    private func rasterize(_ request: GlyphRequest) -> RasterizedGlyph? {
        if let glyphKey = request.glyphKey { return rasterize(glyphKey) }
        let baseFont = CTFontCreateWithName(
            request.fontPostScriptName as CFString,
            CGFloat(request.pixelSize),
            nil
        )
        var traits: CTFontSymbolicTraits = []
        if request.isBold { traits.insert(.boldTrait) }
        if request.isItalic { traits.insert(.italicTrait) }
        let traitMask: CTFontSymbolicTraits = [.boldTrait, .italicTrait]
        let font = traits.isEmpty
            ? baseFont
            : (CTFontCreateCopyWithSymbolicTraits(baseFont, 0, nil, traits, traitMask) ?? baseFont)
        let format: GlyphAtlasPixelFormat = Self.isColorEmoji(request.text) ? .colorBGRA8 : .coverageR8
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if format == .coverageR8 {
            attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = CGColor(gray: 1, alpha: 1)
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: request.text, attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let bounds = CTLineGetImageBounds(line, nil)

        guard !bounds.isNull,
              bounds.width > 0,
              bounds.height > 0,
              bounds.minX.isFinite,
              bounds.minY.isFinite,
              bounds.maxX.isFinite,
              bounds.maxY.isFinite
        else {
            return RasterizedGlyph(
                bytes: [], width: 0, height: 0, format: format,
                advanceX: Double(advance), imageOriginX: 0, imageOriginY: 0,
                ascent: Double(ascent),
                descent: Double(descent), leading: Double(leading)
            )
        }

        let left = floor(bounds.minX)
        let bottom = floor(bounds.minY)
        let width = Int(ceil(bounds.maxX) - left)
        let height = Int(ceil(bounds.maxY) - bottom)
        guard width > 0, height > 0,
              width <= maximumTextureDimension - 2,
              height <= maximumTextureDimension - 2
        else { return nil }
        let bytesPerRow = width * format.bytesPerPixel
        let (count, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !overflow, UInt64(count) <= memoryBudget.maximumBytes else { return nil }

        var bytes = [UInt8](repeating: 0, count: count)
        let colorSpace = format == .coverageR8 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = format == .coverageR8
            ? CGImageAlphaInfo.none.rawValue
            : CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let address = buffer.baseAddress,
                  let context = CGContext(
                    data: address,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  )
            else { return false }
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setShouldSmoothFonts(false)
            context.setTextDrawingMode(.fill)
            context.setFillColor(format == .coverageR8 ? CGColor(gray: 1, alpha: 1) : CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.translateBy(x: -left, y: -bottom)
            CTLineDraw(line, context)
            return true
        }
        guard rendered else { return nil }
        return RasterizedGlyph(
            bytes: bytes,
            width: width,
            height: height,
            format: format,
            advanceX: Double(advance),
            imageOriginX: Double(bounds.minX),
            imageOriginY: Double(bounds.minY),
            ascent: Double(ascent),
            descent: Double(descent),
            leading: Double(leading)
        )
    }

    private func rasterize(_ key: GlyphKey) -> RasterizedGlyph? {
        guard key.glyphID <= UInt32(UInt16.max), key.rasterWidthPixels > 0,
              key.rasterHeightPixels > 0, key.rasterScale256 > 0 else { return nil }
        let pointSize = CGFloat(key.rasterHeightPixels) * 256 / CGFloat(key.rasterScale256)
        let font = CTFontCreateWithName(key.fontInstanceID as CFString, pointSize, nil)
        var glyph = CGGlyph(key.glyphID)
        var bounds = CGRect.zero
        var advance = CGSize.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &bounds, 1)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }

        let width = Int(key.rasterWidthPixels)
        let height = Int(key.rasterHeightPixels)
        let format: GlyphAtlasPixelFormat = key.fontInstanceID.localizedCaseInsensitiveContains("emoji")
            ? .colorBGRA8 : .coverageR8
        let bytesPerRow = width * format.bytesPerPixel
        let (count, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !overflow, UInt64(count) <= memoryBudget.maximumBytes else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        let colorSpace = format == .coverageR8 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = format == .coverageR8
            ? CGImageAlphaInfo.none.rawValue
            : CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else { return nil }
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let address = buffer.baseAddress,
                  let context = CGContext(
                    data: address, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo
                  ) else { return false }
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            context.addPath(path)
            context.fillPath()
            return true
        }
        guard rendered else { return nil }
        return RasterizedGlyph(
            bytes: bytes, width: width, height: height, format: format,
            advanceX: Double(advance.width), imageOriginX: Double(bounds.minX), imageOriginY: Double(bounds.minY),
            ascent: Double(CTFontGetAscent(font)), descent: Double(CTFontGetDescent(font)),
            leading: Double(CTFontGetLeading(font))
        )
    }

    private func findOrCreatePage(for raster: RasterizedGlyph) -> UInt16? {
        for index in pages.keys.sorted() {
            guard let page = pages[index], page.format == raster.format else { continue }
            if canPlace(width: raster.width + 2, height: raster.height + 2, in: page) {
                return index
            }
        }
        return createPage(
            format: raster.format,
            minimumWidth: raster.width + 2,
            minimumHeight: raster.height + 2
        )
    }

    private func createPage(format: GlyphAtlasPixelFormat, minimumWidth: Int, minimumHeight: Int) -> UInt16? {
        guard let device, basePageSize > 0 else { return nil }
        let required = max(minimumWidth, minimumHeight, basePageSize)
        let side = Self.nextPowerOfTwo(required)
        guard side <= maximumTextureDimension,
              nextPageIndex <= UInt32(UInt16.max)
        else { return nil }
        let (pixelCount, pixelOverflow) = UInt64(side).multipliedReportingOverflow(by: UInt64(side))
        let (minimumPageBytes, byteOverflow) = pixelCount.multipliedReportingOverflow(by: UInt64(format.bytesPerPixel))
        guard !pixelOverflow, !byteOverflow, minimumPageBytes <= memoryBudget.maximumBytes else { return nil }

        while !canAllocate(additionalBytes: minimumPageBytes) || !canAllocatePages(1) {
            guard let oldest = pages.values.filter({ $0.leaseCount == 0 && pageResourceOwners[$0.index] == nil }).min(by: {
                $0.lastAccess == $1.lastAccess ? $0.index < $1.index : $0.lastAccess < $1.lastAccess
            }) else { return nil }
            _ = evictPage(oldest.index)
        }

        let index = UInt16(nextPageIndex)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format.metalFormat,
            width: side,
            height: side,
            mipmapped: false
        )
        descriptor.storageMode = MTLStorageMode.shared
        descriptor.usage = MTLTextureUsage.shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let pageBytes = UInt64(texture.allocatedSize)
        guard pageBytes > 0, pageBytes <= memoryBudget.maximumBytes else {
            Self.zero(texture, width: side, height: side, format: format)
            return nil
        }
        while !canAllocate(additionalBytes: pageBytes) {
            guard let oldest = pages.values.filter({ $0.leaseCount == 0 && pageResourceOwners[$0.index] == nil }).min(by: {
                $0.lastAccess == $1.lastAccess ? $0.index < $1.index : $0.lastAccess < $1.lastAccess
            }) else {
                Self.zero(texture, width: side, height: side, format: format)
                return nil
            }
            _ = evictPage(oldest.index)
        }
        Self.zero(texture, width: side, height: side, format: format)
        nextPageIndex += 1
        pages[index] = AtlasPage(
            index: index,
            format: format,
            texture: texture,
            dimension: side,
            byteCount: pageBytes,
            cursorX: 0,
            cursorY: 0,
            rowHeight: 0,
            lastAccess: tick(),
            glyphs: [],
            leaseCount: 0
        )
        byteCount += pageBytes
        return index
    }

    private func canPlace(width: Int, height: Int, in page: AtlasPage) -> Bool {
        var copy = page
        return place(width: width, height: height, in: &copy) != nil
    }

    private func place(width: Int, height: Int, in page: inout AtlasPage) -> (x: Int, y: Int)? {
        var x = page.cursorX
        var y = page.cursorY
        var rowHeight = page.rowHeight
        if x + width > page.dimension {
            x = 0
            y += rowHeight
            rowHeight = 0
        }
        guard width <= page.dimension, height <= page.dimension,
              y + height <= page.dimension
        else { return nil }
        page.cursorX = x + width
        page.cursorY = y
        page.rowHeight = max(rowHeight, height)
        return (x, y)
    }

    @discardableResult
    private func evictPage(_ index: UInt16) -> Bool {
        guard let current = pages[index], current.leaseCount == 0, pageResourceOwners[index] == nil else { return false }
        guard var page = pages.removeValue(forKey: index) else { return false }
        if let texture = page.texture {
            Self.zero(texture, width: page.dimension, height: page.dimension, format: page.format)
            zeroFilledEvictionCount &+= 1
            page.texture = nil
        }
        for request in page.glyphs {
            glyphs.removeValue(forKey: request)
        }
        byteCount -= page.byteCount
        evictedPageCount &+= 1
        return true
    }

    private func canAllocate(additionalBytes: UInt64) -> Bool {
        let (currentBytes, overflow) = byteCount.addingReportingOverflow(reservedGPUBytes)
        return !overflow && memoryBudget.allowsAllocation(currentBytes: currentBytes, additionalBytes: additionalBytes)
    }

    private func canAllocatePages(_ additionalPages: UInt32) -> Bool {
        UInt64(pages.count) + UInt64(reservedPages) + UInt64(additionalPages) <= UInt64(memoryBudget.maximumPages)
    }

    private func touch(_ pageIndex: UInt16?) {
        guard let pageIndex, var page = pages[pageIndex] else { return }
        page.lastAccess = tick()
        pages[pageIndex] = page
    }

    private func tick() -> UInt64 {
        accessClock &+= 1
        return accessClock
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func zero(_ texture: MTLTexture, width: Int, height: Int, format: GlyphAtlasPixelFormat) {
        let rowBytes = width * format.bytesPerPixel
        let zeros = [UInt8](repeating: 0, count: rowBytes * height)
        zeros.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: address,
                bytesPerRow: rowBytes
            )
        }
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        var result = 1
        while result < value && result <= Int.max / 2 { result <<= 1 }
        return result
    }

    private static func isColorEmoji(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x1F000...0x1FAFF).contains(value)
                || (0x2600...0x27BF).contains(value)
                || value == 0xFE0F
                || value == 0x20E3
        }
    }
}

private struct GlyphRequest: Hashable {
    let text: String
    let fontPostScriptName: String
    let pixelSize: UInt16
    let isBold: Bool
    let isItalic: Bool
    let glyphKey: GlyphKey?
}

private struct CachedGlyph {
    let entry: GlyphAtlasEntry
    let pageIndex: UInt16?
}

private struct RasterizedGlyph {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    let format: GlyphAtlasPixelFormat
    let advanceX: Double
    let imageOriginX: Double
    let imageOriginY: Double
    let ascent: Double
    let descent: Double
    let leading: Double
}

private struct AtlasPage {
    let index: UInt16
    let format: GlyphAtlasPixelFormat
    var texture: MTLTexture?
    let dimension: Int
    let byteCount: UInt64
    var cursorX: Int
    var cursorY: Int
    var rowHeight: Int
    var lastAccess: UInt64
    var glyphs: Set<GlyphRequest>
    var leaseCount: UInt32
}

private struct ManagedAtlasResource {
    let reservation: AtlasReservation
    let locations: [GlyphKey: GlyphLocation]
    let pageIndices: Set<UInt16>
    var leaseCount: UInt32
    var retired: Bool
}

extension AtlasMemoryBudget {
    public init(maximumBytes: UInt64, maximumPages: UInt32) {
        self.init(maximumGPUBytes: maximumBytes, maximumPages: maximumPages, maximumCPUShadowBytes: maximumBytes)
    }

    public var maximumBytes: UInt64 { maximumGPUBytes }

    public func allowsAllocation(currentBytes: UInt64, additionalBytes: UInt64) -> Bool {
        let (total, overflow) = currentBytes.addingReportingOverflow(additionalBytes)
        return !overflow && total <= maximumGPUBytes
    }

    public func allowsPageAllocation(currentPages: UInt32) -> Bool {
        currentPages < maximumPages
    }

    public static let appDefault = AtlasMemoryBudget(
        maximumGPUBytes: 64 * 1024 * 1024,
        maximumPages: 32,
        maximumCPUShadowBytes: 64 * 1024 * 1024
    )
}
