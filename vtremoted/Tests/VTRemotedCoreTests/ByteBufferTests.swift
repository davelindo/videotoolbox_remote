@testable import VTRemotedCore
import XCTest

final class ByteBufferTests: XCTestCase {
    func testByteWriterAndReaderRoundTrip() throws {
        var writer = ByteWriter()
        writer.write(UInt8(1))
        writer.writeBE(UInt16(2))
        writer.writeBE(UInt32(3))
        writer.writeBE(UInt64(4))
        writer.writeLengthPrefixedUTF8("hello")

        var reader = ByteReader(writer.data)
        XCTAssertEqual(try reader.readUInt8(), 1)
        XCTAssertEqual(try reader.readBEUInt16(), 2)
        XCTAssertEqual(try reader.readBEUInt32(), 3)
        XCTAssertEqual(try reader.readBEUInt64(), 4)
        XCTAssertEqual(try reader.readLengthPrefixedUTF8(), "hello")
    }

    func testReaderEOFThrows() {
        var reader = ByteReader(Data([1, 2, 3]))
        XCTAssertNoThrow(try reader.readBytes(count: 3))
        XCTAssertThrowsError(try reader.readUInt8())
    }
}
