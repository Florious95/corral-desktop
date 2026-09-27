import CoreText
import CorralContracts
@testable import CorralMetalTerminal
import Metal
import XCTest

final class JudgeDeepWaterTests: XCTestCase {
    private func key(_ character: UniChar) throws -> GlyphKey {
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, 18, nil)
        var ch = character
        var glyph = CGGlyph()
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1))
        return GlyphKey(fontInstanceID: "Menlo-Regular", glyphID: UInt32(glyph),
                        variationSignature: "judge", rasterWidthPixels: 24,
                        rasterHeightPixels: 18, rasterScale256: 256)
    }

    private func pool(pages: UInt32 = 8) throws -> (GlyphAtlasPool, MTLDevice) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Real Metal is mandatory; no skip/mock green")
        return (GlyphAtlasPool(device: device, memoryBudget: AtlasMemoryBudget(
            maximumGPUBytes: 8 * 1024 * 1024, maximumPages: pages,
            maximumCPUShadowBytes: 8 * 1024 * 1024), pageSize: 128), device)
    }

    private func pixels(_ texture: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }

    func testRealGPUInFlightLeaseDefersReclaimAndRetainedTextureIsZeroedAfterCompletion() async throws {
        let (pool, device) = try pool()
        let glyph = try key(0x57) // W, independently selected ink-positive control
        let coordinates = try XCTUnwrap(pool.glyph(for: glyph)?.coordinates)
        let texture = try XCTUnwrap(pool.texture(forPage: coordinates.page))
        let before = pixels(texture)
        XCTAssertTrue(before.contains { $0 != 0 }, "zero-check must start with real nonzero glyph ink")
        let reservation = try await pool.reserve(gpuBytes: pool.allocatedBytes, pages: 1, cpuShadowBytes: 4096)
        try await pool.publish(reservation, locations: [glyph: coordinates])
        let lease = try await pool.leaseGlyphs([glyph])
        let secondLease = try await pool.leaseGlyphs([glyph])
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let event = try XCTUnwrap(device.makeSharedEvent())
        let rowBytes = 256
        let destination = try XCTUnwrap(device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared))
        command.encodeWaitForEvent(event, value: 1)
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: destination, destinationOffset: 0, destinationBytesPerRow: rowBytes,
                  destinationBytesPerImage: rowBytes * texture.height)
        blit.endEncoding()
        command.commit()
        defer { event.signaledValue = 1 }
        try await pool.retire(reservation.resource)
        await pool.evict(glyph)
        let earlyReclaim = try await pool.reclaimRetired()
        XCTAssertTrue(earlyReclaim.isEmpty)
        XCTAssertEqual(pixels(texture), before)
        do { _ = try await pool.leaseGlyphs([glyph]); XCTFail("retired generation accepted new lease") }
        catch { XCTAssertEqual(error as? AtlasLifecycleError, .missingGlyph) }
        await pool.release(secondLease)
        await pool.release(secondLease) // Duplicate release cannot decrement the GPU frame's lease.
        let duplicateReclaim = try await pool.reclaimRetired()
        XCTAssertTrue(duplicateReclaim.isEmpty)
        event.signaledValue = 1
        await command.completed()
        XCTAssertEqual(command.status, .completed)
        let copied = UnsafeRawBufferPointer(start: destination.contents(), count: destination.length)
        XCTAssertTrue(copied.contains { $0 != 0 })
        await pool.release(lease)
        let finalReclaim = try await pool.reclaimRetired()
        XCTAssertEqual(finalReclaim, [reservation.resource])
        XCTAssertTrue(pixels(texture).allSatisfy { $0 == 0 }, "retained MTLTexture, not just a zero-filled counter")
        XCTAssertNil(pool.texture(forPage: coordinates.page))
        print("JUDGE: actual GPU wait/blit completed; nonzero source preserved while leased; retained source all zero after final release")
    }

    func testReserveFirstOnePageBudgetStillAllowsItsReservedAllocation() async throws {
        let (pool, _) = try pool(pages: 1)
        _ = try await pool.reserve(gpuBytes: 64 * 1024, pages: 1, cpuShadowBytes: 4096)
        let entry = pool.glyph(for: try key(0x57))
        XCTAssertNotNil(entry, "reserve -> materialize -> publish deadlocks when reservation consumes the sole page slot")
    }

    func testMaterializeFirstOnePageBudgetCanPublishWithoutCountingPageTwice() async throws {
        let (pool, _) = try pool(pages: 1)
        let glyph = try key(0x57)
        let coordinates = try XCTUnwrap(pool.glyph(for: glyph)?.coordinates)
        let reservation = try await pool.reserve(gpuBytes: pool.allocatedBytes, pages: 1, cpuShadowBytes: 4096)
        try await pool.publish(reservation, locations: [glyph: coordinates])
        _ = try await pool.leaseGlyphs([glyph])
    }

    func testSecondPublishedGlyphCannotBeStrandedOnAnAlreadyOwnedPage() async throws {
        let (pool, _) = try pool()
        let first = try key(0x57)
        let firstCoordinates = try XCTUnwrap(pool.glyph(for: first)?.coordinates)
        let firstReservation = try await pool.reserve(gpuBytes: pool.allocatedBytes, pages: 1, cpuShadowBytes: 4096)
        try await pool.publish(firstReservation, locations: [first: firstCoordinates])
        let second = try key(0x67)
        let secondCoordinates = try XCTUnwrap(pool.glyph(for: second)?.coordinates)
        let secondReservation = try await pool.reserve(gpuBytes: pool.allocatedBytes, pages: 1, cpuShadowBytes: 4096)
        print("JUDGE: incremental page IDs first=\(firstCoordinates.page), second=\(secondCoordinates.page)")
        try await pool.publish(secondReservation, locations: [second: secondCoordinates])
        _ = try await pool.leaseGlyphs([first, second])
    }

    func testRetiredLeasedPhysicalPageIsNotMutatedByNewGlyph() async throws {
        let (pool, _) = try pool()
        let first = try key(0x57)
        let coordinates = try XCTUnwrap(pool.glyph(for: first)?.coordinates)
        let texture = try XCTUnwrap(pool.texture(forPage: coordinates.page))
        let reservation = try await pool.reserve(gpuBytes: pool.allocatedBytes, pages: 1, cpuShadowBytes: 4096)
        try await pool.publish(reservation, locations: [first: coordinates])
        let lease = try await pool.leaseGlyphs([first])
        try await pool.retire(reservation.resource)
        let before = pixels(texture)
        let second = try XCTUnwrap(pool.glyph(for: try key(0x67)), "spare budget must still admit the new glyph")
        let after = pixels(texture)
        let changed = zip(before, after).filter { $0 != $1 }.count
        print("JUDGE: retired leased page=\(coordinates.page), new glyph page=\(second.coordinates.page), mutatedBytes=\(changed)")
        XCTAssertNotEqual(second.coordinates.page, coordinates.page)
        XCTAssertEqual(changed, 0, "retired-in-flight pages must be immutable")
        await pool.release(lease)
        _ = try await pool.reclaimRetired()
    }
}
