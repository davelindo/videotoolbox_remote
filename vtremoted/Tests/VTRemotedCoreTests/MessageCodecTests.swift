@testable import VTRemotedCore
import XCTest

final class MessageCodecTests: XCTestCase {
    func testProtocolPixelFormatConstants() {
        XCTAssertEqual(VTRPixelFormat.nv12, 1)
        XCTAssertEqual(VTRPixelFormat.p010, 2)
        XCTAssertEqual(VTRPixelFormat.bgra, 3)
        XCTAssertEqual(VTRPixelFormat.ayuv, 4)
        XCTAssertEqual(VTRPixelFormat.p210, 5)
        XCTAssertEqual(VTRPixelFormat.videoToolbox, 6)
        XCTAssertEqual(VTRPixelFormat.name(VTRPixelFormat.nv12), "nv12")
        XCTAssertEqual(VTRPixelFormat.name(VTRPixelFormat.videoToolbox), "videotoolbox")
        XCTAssertEqual(VTRPixelFormat.name(255), "unknown")
    }

    func testBaselineCapabilities() {
        XCTAssertEqual(
            VTRCapability.baseline,
            [
                VTRCapability.h264,
                VTRCapability.hevc,
                VTRCapability.pixfmtNV12,
                VTRCapability.pixfmtP010
            ]
        )
    }

    func testDefaultServerCapabilities() {
        XCTAssertEqual(
            VTRCapability.defaultServer,
            [
                VTRCapability.h264,
                VTRCapability.hevc,
                VTRCapability.pixfmtNV12,
                VTRCapability.pixfmtP010,
                VTRCapability.pixfmtBGRA,
                VTRCapability.pixfmtAYUV,
                VTRCapability.pixfmtP210,
                VTRCapability.hwFramesVideoToolboxInput,
                VTRCapability.hwFramesVideoToolboxOutput,
                VTRCapability.sideDataV2
            ]
        )
    }

    func testRuntimeServerCapabilitiesMatchBackend() {
        #if canImport(VideoToolbox)
            XCTAssertEqual(VTRCapability.runtimeServer, VTRCapability.defaultServer)
        #else
            XCTAssertEqual(VTRCapability.runtimeServer, VTRCapability.baseline)
        #endif
    }

    func testHelloDecode() throws {
        var writer = ByteWriter()
        writer.writeLengthPrefixedUTF8("tkn")
        writer.writeLengthPrefixedUTF8("h264")
        writer.writeLengthPrefixedUTF8("client")
        writer.writeLengthPrefixedUTF8("build1")

        let hello = try HelloRequest.decode(writer.data)
        XCTAssertEqual(hello.token, "tkn")
        XCTAssertEqual(hello.codec, "h264")
        XCTAssertEqual(hello.clientName, "client")
        XCTAssertEqual(hello.build, "build1")
    }

    func testConfigureDecodeWithOptionsAndExtradata() throws {
        var writer = ByteWriter()
        writer.writeBE(UInt32(1920))
        writer.writeBE(UInt32(1080))
        writer.write(VTRPixelFormat.nv12)
        writer.writeBE(UInt32(1))
        writer.writeBE(UInt32(30))
        writer.writeBE(UInt32(30000))
        writer.writeBE(UInt32(1001))

        writer.writeBE(UInt16(2))
        writer.writeLengthPrefixedUTF8("mode")
        writer.writeLengthPrefixedUTF8("decode")
        writer.writeLengthPrefixedUTF8("wire_compression")
        writer.writeLengthPrefixedUTF8("1")

        let extra = Data([1, 2, 3, 4, 5])
        writer.writeBE(UInt32(extra.count))
        writer.write(extra)

        let cfg = try ConfigureRequest.decode(writer.data)
        XCTAssertEqual(cfg.width, 1920)
        XCTAssertEqual(cfg.height, 1080)
        XCTAssertEqual(cfg.pixelFormat, VTRPixelFormat.nv12)
        XCTAssertEqual(cfg.timebase, Timebase(num: 1, den: 30))
        XCTAssertEqual(cfg.frameRate.num, 30000)
        XCTAssertEqual(cfg.frameRate.den, 1001)
        XCTAssertEqual(cfg.options["mode"], "decode")
        XCTAssertEqual(cfg.options["wire_compression"], "1")
        XCTAssertEqual(cfg.extradata, extra)
    }
}
