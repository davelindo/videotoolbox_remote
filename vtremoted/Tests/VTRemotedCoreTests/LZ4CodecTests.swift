import XCTest
@testable import VTRemotedCore

final class LZ4CodecTests: XCTestCase {
    func testLZ4CompressDecompress() {
        let input = Data((0..<10_000).map { UInt8($0 % 251) })
        guard let compressed = LZ4Codec.compress(input) else { return XCTFail("compress returned nil") }
        guard let out = LZ4Codec.decompress(compressed, expectedSize: input.count) else { return XCTFail("decompress returned nil") }
        XCTAssertEqual(out, input)
    }
}
