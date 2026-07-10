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
