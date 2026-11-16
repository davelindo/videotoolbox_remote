#if canImport(CoreMedia)
@testable import VTRemotedCore
import CoreMedia
import XCTest

final class PacketBlockBufferTests: XCTestCase {
    func testBlockRetainsPoolStorageWithoutCopying() throws {
        let pool = RawBufferPool()
        var original: UnsafeMutableRawPointer?
        func makeBlock() throws -> CMBlockBuffer {
            let data = try XCTUnwrap(pool.data(capacity: 1024) { raw in
                original = raw.baseAddress
                raw.initializeMemory(as: UInt8.self, repeating: 0x67)
                return raw.count
            })
            return try PacketBlockBuffer.make(data)
        }
        try autoreleasepool {
            let block = try makeBlock()
            XCTAssertEqual(pool.snapshot.retainedBytes, 0)
            var pointer: UnsafeMutablePointer<Int8>?
            XCTAssertEqual(CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                                     totalLengthOut: nil, dataPointerOut: &pointer), noErr)
            XCTAssertEqual(pointer.map(UnsafeMutableRawPointer.init), original)
            XCTAssertEqual(pointer?.pointee, 0x67)
        }
        XCTAssertEqual(pool.snapshot.retainedBytes, 1024)
    }

    func testSmallInlineDataHasStableLifetime() throws {
        func makeBlock() throws -> CMBlockBuffer {
            try PacketBlockBuffer.make(Data([1, 2, 3]))
        }
        let block = try makeBlock()
        var bytes = [UInt8](repeating: 0, count: 3)
        XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 3,
                                               destination: &bytes), noErr)
        XCTAssertEqual(bytes, [1, 2, 3])
        XCTAssertThrowsError(try PacketBlockBuffer.make(Data()))
    }
}
#endif
