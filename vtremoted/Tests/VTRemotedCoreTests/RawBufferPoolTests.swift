@testable import VTRemotedCore
import Foundation
import XCTest

final class RawBufferPoolTests: XCTestCase {
    func testRetainedWireDataPreventsPrematureReuse() throws {
        let pool = RawBufferPool(retainedByteLimit: 4096)
        var first: Data? = pool.data(capacity: 1024) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0x35)
            return 1024
        }
        var second: Data? = pool.data(capacity: 1024) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0x96)
            return 1024
        }
        XCTAssertEqual(first, Data(repeating: 0x35, count: 1024))
        XCTAssertEqual(second, Data(repeating: 0x96, count: 1024))
        XCTAssertEqual(pool.snapshot.allocations, 2)
        second = nil
        _ = pool.withBuffer(capacity: 1024) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0xff)
        }
        XCTAssertEqual(first, Data(repeating: 0x35, count: 1024))
        XCTAssertEqual(pool.snapshot.allocations, 2)
        first = nil
        XCTAssertEqual(pool.snapshot.retainedBytes, 2048)
    }

    func testCompressedBuffersPreserveAllTenBitValuesAcrossReuse() throws {
        try XCTSkipUnless(LZ4Codec.isAvailable && ZstdCodec.isAvailable, "compression libraries unavailable")
        let pool = RawBufferPool(retainedByteLimit: 1024 * 1024)
        let pixels = (0..<8192).map { UInt16($0 % 1024) << 6 }
        let input = pixels.withUnsafeBytes { Data($0) }
        for mode in [1, 2] {
            for _ in 0..<30 {
                let compressed = try XCTUnwrap(input.withUnsafeBytes { bytes in
                    mode == 1 ? LZ4Codec.compress(bytes, pool: pool) : ZstdCodec.compress(bytes, pool: pool)
                })
                let decoded = mode == 1 ? LZ4Codec.decompress(compressed, expectedSize: input.count)
                    : ZstdCodec.decompress(compressed, expectedSize: input.count)
                XCTAssertEqual(decoded, input)
            }
        }
        XCTAssertLessThanOrEqual(pool.snapshot.allocations, 3)
        XCTAssertLessThanOrEqual(pool.snapshot.retainedBytes, 1024 * 1024)
    }

    func testPoolBudgetAndFailedFill() {
        let pool = RawBufferPool(retainedByteLimit: 32)
        XCTAssertNil(pool.data(capacity: 1024) { _ in nil })
        XCTAssertEqual(pool.snapshot.retainedBytes, 0)
        XCTAssertEqual(pool.data(capacity: 16) { _ in 0 }, Data())
        XCTAssertLessThanOrEqual(pool.snapshot.retainedBytes, 32)
    }
}
