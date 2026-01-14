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
    
    func testSliceRangeAdvancesPosition() throws {
        let data = Data([0, 1, 2, 3, 4, 5, 6, 7])
        var reader = ByteReader(data)
        
        let range1 = try reader.sliceRange(count: 3)
        XCTAssertEqual(range1, 0..<3)
        XCTAssertEqual(reader.remaining, 5)
        
        let range2 = try reader.sliceRange(count: 2)
        XCTAssertEqual(range2, 3..<5)
        XCTAssertEqual(reader.remaining, 3)
    }
    
    func testSliceRangeEOFThrows() {
        var reader = ByteReader(Data([1, 2, 3]))
        XCTAssertThrowsError(try reader.sliceRange(count: 4))
    }
    
    func testSliceRangeNegativeThrows() {
        var reader = ByteReader(Data([1, 2, 3]))
        XCTAssertThrowsError(try reader.sliceRange(count: -1))
    }
    
    func testReadBytesUsesSliceRange() throws {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        var reader = ByteReader(data)
        
        let bytes = try reader.readBytes(count: 2)
        XCTAssertEqual(bytes, Data([0xDE, 0xAD]))
        XCTAssertEqual(reader.remaining, 2)
    }
}
