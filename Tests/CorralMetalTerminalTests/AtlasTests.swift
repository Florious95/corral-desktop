import CorralContracts
import Metal
import XCTest
@testable import CorralMetalTerminal

final class AtlasTests: XCTestCase {
    private let font = "Menlo-Regular"

    private func makePool(
        bytes: UInt64 = 8 * 1024 * 1024,
        pages: UInt32 = 8,
        pageSize: Int = 128
    ) throws -> GlyphAtlasPool {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this machine")
        }
        return GlyphAtlasPool(
            device: device,
            memoryBudget: AtlasMemoryBudget(maximumBytes: bytes, maximumPages: pages),
            pageSize: pageSize
        )
    }

    func testSingleCharacterRasterizationAndMetrics() throws {
        let pool = try makePool()
        let key = GlyphKey(fontPostScriptName: font, codepoint: 65, pixelSize: 18)

        let first = try XCTUnwrap(pool.glyph(for: key))
        let second = try XCTUnwrap(pool.glyph(for: key))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.format, .coverageR8)
        XCTAssertGreaterThan(first.coordinates.width, 0)
        XCTAssertGreaterThan(first.coordinates.height, 0)
        XCTAssertGreaterThan(first.advanceX, 0)
        XCTAssertGreaterThan(first.ascent, 0)
        XCTAssertEqual(pool.coordinates(for: key), first.coordinates)
        XCTAssertGreaterThan(pool.statistics.cacheHits, 0)
        let texture = try XCTUnwrap(pool.texture(forPage: first.coordinates.page))
        XCTAssertEqual(texture.pixelFormat, .r8Unorm)
        XCTAssertTrue(readPixels(from: texture, bytesPerPixel: 1).contains { $0 != 0 })
    }

    func testCJKWideCharacterIsShapedAndPlaced() throws {
        let pool = try makePool()
        let entry = try XCTUnwrap(pool.glyph(
            for: "界",
            fontPostScriptName: font,
            pixelSize: 24
        ))

        XCTAssertEqual(entry.format, .coverageR8)
        XCTAssertGreaterThan(entry.coordinates.width, 0)
        XCTAssertGreaterThan(entry.coordinates.height, 0)
        XCTAssertGreaterThan(entry.advanceX, 0)
        XCTAssertTrue(entry.advanceX.isFinite)
        XCTAssertEqual(pool.texture(forPage: entry.coordinates.page)?.pixelFormat, .r8Unorm)
    }

    func testColorEmojiAndZWJSequenceUseBGRAAtlas() throws {
        let pool = try makePool()
        let entry = try XCTUnwrap(pool.glyph(
            for: "👩‍👩‍👧‍👦",
            fontPostScriptName: font,
            pixelSize: 32
        ))

        XCTAssertEqual(entry.format, .colorBGRA8)
        XCTAssertGreaterThan(entry.coordinates.width, 0)
        XCTAssertGreaterThan(entry.coordinates.height, 0)
        let texture = try XCTUnwrap(pool.texture(forPage: entry.coordinates.page))
        XCTAssertEqual(texture.pixelFormat, .bgra8Unorm)
        let pixels = readPixels(from: texture, bytesPerPixel: 4)
        XCTAssertTrue(pixels.contains { $0 != 0 })
        var containsColoredPixel = false
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[index] != pixels[index + 1] || pixels[index + 1] != pixels[index + 2] {
                containsColoredPixel = true
                break
            }
        }
        XCTAssertTrue(containsColoredPixel)
    }

    func testConcurrentQueriesShareCachedPagesWithinBudget() throws {
        let pool = try makePool(bytes: 2 * 128 * 128, pages: 2)
        let values: [UInt32] = [65, 66, 67, 0x754C, 0x754F, 0x732B]
        let fontName = font

        DispatchQueue.concurrentPerform(iterations: 240) { index in
            let codepoint = values[index % values.count]
            _ = pool.glyph(for: GlyphKey(
                fontPostScriptName: fontName,
                codepoint: codepoint,
                pixelSize: 18
            ))
        }

        let statistics = pool.statistics
        XCTAssertGreaterThan(statistics.cacheHits, 0)
        XCTAssertGreaterThan(statistics.rasterizedGlyphs, 0)
        XCTAssertLessThanOrEqual(statistics.pageCount, 2)
        XCTAssertLessThanOrEqual(statistics.allocatedBytes, 2 * 128 * 128)
    }

    func testEvictionZeroFillsTextureBeforeReleasingPage() async throws {
        let budget: UInt64 = 1024 * 1024
        let pool = try makePool(bytes: budget, pages: 1, pageSize: 64)
        let key = GlyphKey(fontPostScriptName: font, codepoint: 65, pixelSize: 16)
        let entry = try XCTUnwrap(pool.glyph(for: key))
        let pageIndex = entry.coordinates.page
        let retainedTexture = try XCTUnwrap(pool.texture(forPage: pageIndex))
        let (retainedBytes, overflow) = retainedTexture.width.multipliedReportingOverflow(by: retainedTexture.height)
        XCTAssertFalse(overflow)
        XCTAssertTrue(readPixels(from: retainedTexture, bytesPerPixel: 1).contains { $0 != 0 })

        await pool.evict(key)

        var pixels = [UInt8](repeating: 0xFF, count: retainedBytes)
        pixels.withUnsafeMutableBytes { buffer in
            retainedTexture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: retainedTexture.width,
                from: MTLRegionMake2D(0, 0, retainedTexture.width, retainedTexture.height),
                mipmapLevel: 0
            )
        }
        XCTAssertTrue(pixels.allSatisfy { $0 == 0 })
        XCTAssertEqual(pool.coordinates(for: key), .zero)
        XCTAssertNil(pool.texture(forPage: pageIndex))
        XCTAssertEqual(pool.allocatedBytes, 0)
        XCTAssertEqual(pool.statistics.evictedPages, 1)
        XCTAssertEqual(pool.statistics.zeroFilledEvictions, 1)
    }

    func testHighEntropyCharactersRemainBoundedUnderPageChurn() throws {
        let pageBytes: UInt64 = 128 * 128 * 4
        let pool = try makePool(bytes: 2 * pageBytes, pages: 2, pageSize: 96)
        var successful = 0
        for range in [UInt32(0x4E00)...UInt32(0x4EFF), UInt32(0x1F600)...UInt32(0x1F6FF)] {
            for scalarValue in range {
                guard let scalar = Unicode.Scalar(scalarValue),
                      pool.glyph(for: String(scalar), fontPostScriptName: font, pixelSize: 18) != nil
                else { continue }
                successful += 1
            }
        }

        XCTAssertGreaterThan(successful, 400)
        XCTAssertLessThanOrEqual(pool.statistics.pageCount, 2)
        XCTAssertLessThanOrEqual(pool.allocatedBytes, 2 * pageBytes)
        XCTAssertGreaterThan(pool.statistics.zeroFilledEvictions, 0)
    }

    func testSharedPoolIsOneStableApplicationInstance() {
        XCTAssertTrue(GlyphAtlasPool.shared === GlyphAtlasPool.shared)
    }

    private func readPixels(from texture: MTLTexture, bytesPerPixel: Int) -> [UInt8] {
        let rowBytes = texture.width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: rowBytes * texture.height)
        pixels.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: rowBytes,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
        }
        return pixels
    }
}
