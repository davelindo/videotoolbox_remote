@testable import VTRemotedCore
import XCTest

final class SessionConfigurationTests: XCTestCase {
    func testRejectsUnknownMode() {
        var request = makeRequest()
        request.options["mode"] = "mystery"
        XCTAssertThrowsError(try SessionConfiguration(codec: .h264, request: request))
    }

    func testRejectsDimensionsOutsideVideoToolboxRange() {
        var request = makeRequest()
        request.width = Int(Int32.max) + 1
        XCTAssertThrowsError(try SessionConfiguration(codec: .h264, request: request))
    }

    func testRejectsOversizedTimebaseAndInvalidFrameRate() {
        var request = makeRequest()
        request.timebase = Timebase(num: 1, den: Int(Int32.max) + 1)
        XCTAssertThrowsError(try SessionConfiguration(codec: .h264, request: request))

        request = makeRequest()
        request.frameRate = (num: 0, den: 1)
        XCTAssertThrowsError(try SessionConfiguration(codec: .h264, request: request))

        request.options["mode"] = "decode"
        request.frameRate = (num: 0, den: 0)
        XCTAssertThrowsError(try SessionConfiguration(codec: .h264, request: request))
    }

    func testDecodeAllowsUnknownFrameRateNumerator() {
        var request = makeRequest()
        request.options["mode"] = "decode"
        request.frameRate = (num: 0, den: 1)
        XCTAssertNoThrow(try SessionConfiguration(codec: .h264, request: request))
    }

    func testAcceptsSupportedDecodeReorderDepths() throws {
        for mode in ["encode", "decode", "transcode"] {
            for depth in [0, 1, 2, 64] {
                var request = makeRequest()
                request.options["mode"] = mode
                request.options["decode_reorder_depth"] = String(depth)
                let config = try SessionConfiguration(codec: .h264, request: request)
                XCTAssertEqual(config.options.decodeReorderDepth, depth)
            }
        }
    }

    func testOmittedAndExplicitDefaultDecodeReorderDepth() throws {
        for mode in ["decode", "transcode"] {
            var request = makeRequest()
            request.options["mode"] = mode
            XCTAssertEqual(try SessionConfiguration(codec: .h264, request: request).options.decodeReorderDepth, 2)
            // The transcode client sends -1 explicitly; the decoder client omits it.
            request.options["decode_reorder_depth"] = "-1"
            XCTAssertEqual(try SessionConfiguration(codec: .h264, request: request).options.decodeReorderDepth, 2)
        }
    }

    func testRejectsInvalidDecodeReorderDepths() {
        let invalid = ["", "invalid", "2.5", "-2", "65", String(Int.max), String(Int.min), String(UInt64.max)]
        for mode in ["encode", "decode", "transcode"] {
            for depth in invalid {
                var request = makeRequest()
                request.options["mode"] = mode
                request.options["decode_reorder_depth"] = depth
                XCTAssertThrowsError(try SessionConfiguration(codec: .h264, request: request),
                                     "accepted depth=\(depth) for mode=\(mode)")
            }
        }
    }

    func testRejectsFrameGeometryAboveConfiguredLimit() {
        XCTAssertThrowsError(try SessionConfiguration(
            codec: .h264,
            request: makeRequest(),
            maxFrameBytes: 1024
        ))
    }

    func testAcceptsValidConfigurationAtFrameLimit() throws {
        let config = try SessionConfiguration(
            codec: .h264,
            request: makeRequest(),
            maxFrameBytes: 64 * 64 + 64 * 32
        )
        XCTAssertEqual(config.mode, .encode)
        XCTAssertEqual(config.maxFrameBytes, 6144)
    }

    func testParsesVBVBufferSize() throws {
        var request = makeRequest()
        request.options["bitrate"] = "1500000"
        request.options["bufsize"] = "3000000"

        let config = try SessionConfiguration(codec: .h264, request: request)

        XCTAssertEqual(config.options.bitrate, 1_500_000)
        XCTAssertEqual(config.options.bufferSize, 3_000_000)
    }

    func testOddNV12HeightIncludesRoundedUpChromaRows() throws {
        var request = makeRequest()
        request.width = 4
        request.height = 3

        XCTAssertThrowsError(try SessionConfiguration(
            codec: .h264,
            request: request,
            maxFrameBytes: 19
        ))
        XCTAssertNoThrow(try SessionConfiguration(
            codec: .h264,
            request: request,
            maxFrameBytes: 20
        ))
    }
}

private func makeRequest() -> ConfigureRequest {
    ConfigureRequest(
        width: 64,
        height: 64,
        pixelFormat: VTRPixelFormat.nv12,
        timebase: Timebase(num: 1, den: 30),
        frameRate: (num: 30, den: 1),
        options: ["mode": "encode", "wire_compression": "0"],
        extradata: nil
    )
}
