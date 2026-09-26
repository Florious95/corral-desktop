import CoreGraphics
import CoreText
import Foundation
import Metal
import CorralContracts

public protocol SharedGlyphAtlas: Sendable {
    var memoryBudget: AtlasMemoryBudget { get }
    var allocatedBytes: UInt64 { get }
    func coordinates(for key: GlyphKey) -> AtlasCoordinates
    func evict(_ key: GlyphKey) async
}

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
public final class GlyphAtlasPool: SharedGlyphAtlas, @unchecked Sendable {
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

    /// Returns a resident glyph's coordinates, or the zero sentinel when it is absent/evicted.
    public func coordinates(for key: GlyphKey) -> AtlasCoordinates {
        guard let scalar = Unicode.Scalar(key.codepoint) else { return .zero }
        let request = GlyphRequest(
            text: String(scalar),
            fontPostScriptName: key.fontPostScriptName,
            pixelSize: key.pixelSize,
            isBold: key.isBold,
            isItalic: key.isItalic
        )
        return synchronized {
            guard let cached = glyphs[request] else { return .zero }
            touch(cached.pageIndex)
            cacheHitCount &+= 1
            return cached.entry.coordinates
        }
    }

    /// Rasterizes and caches a scalar glyph described by the shared contract key.
    public func glyph(for key: GlyphKey) -> GlyphAtlasEntry? {
        guard let scalar = Unicode.Scalar(key.codepoint) else { return nil }
        return glyph(
            for: String(scalar),
            fontPostScriptName: key.fontPostScriptName,
            pixelSize: key.pixelSize,
            isBold: key.isBold,
            isItalic: key.isItalic
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
            isItalic: isItalic
        )
        return synchronized { glyphLocked(for: request) }
    }

    public func texture(forPage index: UInt16) -> MTLTexture? {
        synchronized { pages[index]?.texture }
    }

    /// Eviction is page-granular; every cached coordinate on the page becomes invalid.
    public func evict(_ key: GlyphKey) async {
        evictSynchronously(key)
    }

    private func evictSynchronously(_ key: GlyphKey) {
        guard let scalar = Unicode.Scalar(key.codepoint) else { return }
        let request = GlyphRequest(
            text: String(scalar),
            fontPostScriptName: key.fontPostScriptName,
            pixelSize: key.pixelSize,
            isBold: key.isBold,
            isItalic: key.isItalic
        )
        synchronized {
            guard let cached = glyphs[request] else { return }
            if let pageIndex = cached.pageIndex {
                evictPage(pageIndex)
            } else {
                glyphs.removeValue(forKey: request)
            }
        }
    }

    private func glyphLocked(for request: GlyphRequest) -> GlyphAtlasEntry? {
        guard !request.text.isEmpty, request.pixelSize > 0 else { return nil }
        if let cached = glyphs[request] {
            touch(cached.pageIndex)
            cacheHitCount &+= 1
            return cached.entry
        }
        cacheMissCount &+= 1
        guard let raster = rasterize(request) else { return nil }
        rasterizedCount &+= 1

        if raster.width == 0 || raster.height == 0 {
            let entry = GlyphAtlasEntry(
                coordinates: .zero,
                format: raster.format,
                advanceX: raster.advanceX,
                imageOriginX: raster.imageOriginX,
                imageOriginY: raster.imageOriginY,
                ascent: raster.ascent,
                descent: raster.descent,
                leading: raster.leading
            )
            glyphs[request] = CachedGlyph(entry: entry, pageIndex: nil)
            return entry
        }

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

        while !memoryBudget.allowsAllocation(currentBytes: byteCount, additionalBytes: minimumPageBytes)
                || !memoryBudget.allowsPageAllocation(currentPages: UInt32(pages.count)) {
            guard let oldest = pages.values.min(by: {
                $0.lastAccess == $1.lastAccess ? $0.index < $1.index : $0.lastAccess < $1.lastAccess
            }) else { return nil }
            evictPage(oldest.index)
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
        while !memoryBudget.allowsAllocation(currentBytes: byteCount, additionalBytes: pageBytes) {
            guard let oldest = pages.values.min(by: {
                $0.lastAccess == $1.lastAccess ? $0.index < $1.index : $0.lastAccess < $1.lastAccess
            }) else {
                Self.zero(texture, width: side, height: side, format: format)
                return nil
            }
            evictPage(oldest.index)
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
            glyphs: []
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

    private func evictPage(_ index: UInt16) {
        guard var page = pages.removeValue(forKey: index) else { return }
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

    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
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
}

extension AtlasMemoryBudget {
    public static let appDefault = AtlasMemoryBudget(maximumBytes: 64 * 1024 * 1024, maximumPages: 32)
}
