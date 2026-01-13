import XCTest
@testable import VTRemotedCore

final class ByteBufferTests: XCTestCase {
    func testByteWriterAndReaderRoundTrip() throws {
        var w = ByteWriter()
        w.write(UInt8(0xAB))
        w.writeBE(UInt16(0x1234))
        w.writeBE(UInt32(0x89ABCDEF))
        w.writeBE(UInt64(0x0123456789ABCDEF))
        w.writeLengthPrefixedUTF8("hello")

        var r = ByteReader(w.data)
        XCTAssertEqual(try r.readUInt8(), 0xAB)
        XCTAssertEqual(try r.readBEUInt16(), 0x1234)
        XCTAssertEqual(try r.readBEUInt32(), 0x89ABCDEF)
        XCTAssertEqual(try r.readBEUInt64(), 0x0123456789ABCDEF)
        XCTAssertEqual(try r.readLengthPrefixedUTF8(), "hello")
        XCTAssertEqual(r.remaining, 0)
    }

    func testReaderEOFThrows() {
        var r = ByteReader(Data())
        XCTAssertThrowsError(try r.readUInt8())
    }
}
