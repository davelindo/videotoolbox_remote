@testable import VTRemotedCore
import XCTest

final class ZstdCodecTests: XCTestCase {
    func testZstdCompressDecompress() {
        let original = Data("Hello Zstd Compression World!".utf8)
        guard let compressed = ZstdCodec.compress(original) else {
            XCTFail("Compression failed")
            return
        }
        XCTAssertLessThan(compressed.count, original.count + 100) // Should not explode in size

        guard let decompressed = ZstdCodec.decompress(compressed, expectedSize: original.count) else {
            XCTFail("Decompression failed")
            return
        }
        XCTAssertEqual(decompressed, original)
    }

    func testZstdEmptyData() {
        let original = Data()
        let compressed = ZstdCodec.compress(original)
        XCTAssertEqual(compressed, Data())

        let decompressed = ZstdCodec.decompress(Data(), expectedSize: 0)
        XCTAssertEqual(decompressed, Data())
    }

    func testZstdMismatchSize() {
        let original = Data("Testing mismatch".utf8)
        let compressed = ZstdCodec.compress(original)!
        let decompressed = ZstdCodec.decompress(compressed, expectedSize: original.count - 1)
        XCTAssertNil(decompressed)
    }
}
