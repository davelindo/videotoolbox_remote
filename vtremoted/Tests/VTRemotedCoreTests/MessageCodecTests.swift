import XCTest
@testable import VTRemotedCore

final class MessageCodecTests: XCTestCase {
    func testHelloDecode() throws {
        var w = ByteWriter()
        w.writeLengthPrefixedUTF8("tkn")
        w.writeLengthPrefixedUTF8("h264")
        w.writeLengthPrefixedUTF8("client")
        w.writeLengthPrefixedUTF8("build1")

        let hello = try HelloRequest.decode(w.data)
        XCTAssertEqual(hello.token, "tkn")
        XCTAssertEqual(hello.codec, "h264")
        XCTAssertEqual(hello.clientName, "client")
        XCTAssertEqual(hello.build, "build1")
    }

    func testConfigureDecodeWithOptionsAndExtradata() throws {
        var w = ByteWriter()
        w.writeBE(UInt32(1920))
        w.writeBE(UInt32(1080))
        w.write(UInt8(1))
        w.writeBE(UInt32(1))
        w.writeBE(UInt32(30))
        w.writeBE(UInt32(30000))
        w.writeBE(UInt32(1001))

        w.writeBE(UInt16(2))
        w.writeLengthPrefixedUTF8("mode")
        w.writeLengthPrefixedUTF8("decode")
        w.writeLengthPrefixedUTF8("wire_compression")
        w.writeLengthPrefixedUTF8("1")

        let extra = Data([1, 2, 3, 4, 5])
        w.writeBE(UInt32(extra.count))
        w.write(extra)

        let cfg = try ConfigureRequest.decode(w.data)
        XCTAssertEqual(cfg.width, 1920)
        XCTAssertEqual(cfg.height, 1080)
        XCTAssertEqual(cfg.pixelFormat, 1)
        XCTAssertEqual(cfg.timebase, Timebase(num: 1, den: 30))
        XCTAssertEqual(cfg.frameRate.num, 30000)
        XCTAssertEqual(cfg.frameRate.den, 1001)
        XCTAssertEqual(cfg.options["mode"], "decode")
        XCTAssertEqual(cfg.options["wire_compression"], "1")
        XCTAssertEqual(cfg.extradata, extra)
    }
}
