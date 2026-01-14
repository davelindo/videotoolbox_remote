@testable import VTRemotedCore
import XCTest

final class LZ4CodecTests: XCTestCase {
    func testLZ4CompressDecompress() {
        let input = Data((0 ..< 10000).map { UInt8($0 % 251) })
        guard let compressed = LZ4Codec.compress(input) else {
            return XCTFail("compress returned nil")
        }
        guard let out = LZ4Codec.decompress(compressed, expectedSize: input.count) else {
            return XCTFail("decompress returned nil")
        }
        XCTAssertEqual(out, input)
    }
    
    func testLZ4DecompressRaw() {
        let input = Data((0 ..< 10000).map { UInt8($0 % 251) })
        guard let compressed = LZ4Codec.compress(input) else {
            return XCTFail("compress returned nil")
        }
        
        var output = Data(count: input.count)
        let success = compressed.withUnsafeBytes { srcPtr in
            output.withUnsafeMutableBytes { dstPtr in
                LZ4Codec.decompressRaw(srcPtr, into: dstPtr.baseAddress!, expectedSize: input.count)
            }
        }
        XCTAssertTrue(success)
        XCTAssertEqual(output, input)
    }
}
