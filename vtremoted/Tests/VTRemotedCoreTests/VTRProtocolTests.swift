import XCTest
@testable import VTRemotedCore

final class VTRProtocolTests: XCTestCase {
    func testHeaderEncodeDecode() throws {
        let h = VTRMessageHeader(type: VTRMessageType.ping.rawValue, length: 42)
        let data = h.encoded()
        XCTAssertEqual(data.count, VTRProtocol.headerSize)
        let decoded = try VTRMessageHeader.decode(data)
        XCTAssertEqual(decoded.type, VTRMessageType.ping.rawValue)
        XCTAssertEqual(decoded.length, 42)
    }

    func testHeaderBadMagicThrows() {
        var w = ByteWriter()
        w.writeBE(UInt32(0xDEADBEEF))
        w.writeBE(VTRProtocol.version)
        w.writeBE(VTRMessageType.ping.rawValue)
        w.writeBE(UInt32(0))
        XCTAssertThrowsError(try VTRMessageHeader.decode(w.data))
    }
}
