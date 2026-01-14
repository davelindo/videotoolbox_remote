@testable import VTRemotedCore
import XCTest

final class VTRProtocolTests: XCTestCase {
    func testHeaderEncodeDecode() throws {
        let header = VTRMessageHeader(type: VTRMessageType.ping.rawValue, length: 42)
        let data = header.encoded()
        XCTAssertEqual(data.count, VTRProtocol.headerSize)
        let decoded = try VTRMessageHeader.decode(data)
        XCTAssertEqual(decoded.type, VTRMessageType.ping.rawValue)
        XCTAssertEqual(decoded.length, 42)
    }

    func testHeaderBadMagicThrows() {
        var writer = ByteWriter()
        writer.writeBE(UInt32(0xDEAD_BEEF))
        writer.writeBE(VTRProtocol.version)
        writer.writeBE(VTRMessageType.ping.rawValue)
        writer.writeBE(UInt32(0))
        XCTAssertThrowsError(try VTRMessageHeader.decode(writer.data))
    }
}
