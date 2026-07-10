@testable import VTRemotedCore
import XCTest

final class FramePlaneValidationTests: XCTestCase {
    func testAcceptsPaddedUncompressedPlane() throws {
        let layout = try FramePlaneValidation.validate(
            stride: 80,
            height: 64,
            encodedLength: 80 * 64,
            minimumRowBytes: 64,
            expectedHeight: 64,
            maxDecodedBytes: 16 * 1024,
            compressionMode: 0
        )

        XCTAssertEqual(layout, ValidatedFramePlaneLayout(stride: 80, height: 64, decodedSize: 5120))
    }

    func testRejectsWrongHeightAndShortStride() {
        XCTAssertThrowsError(try FramePlaneValidation.validate(
            stride: 64,
            height: 63,
            encodedLength: 64 * 63,
            minimumRowBytes: 64,
            expectedHeight: 64,
            maxDecodedBytes: 16 * 1024,
            compressionMode: 0
        ))
        XCTAssertThrowsError(try FramePlaneValidation.validate(
            stride: 63,
            height: 64,
            encodedLength: 63 * 64,
            minimumRowBytes: 64,
            expectedHeight: 64,
            maxDecodedBytes: 16 * 1024,
            compressionMode: 0
        ))
    }

    func testRejectsOverflowAndDecodedSizeAboveLimit() {
        XCTAssertThrowsError(try FramePlaneValidation.validate(
            stride: Int.max,
            height: 2,
            encodedLength: 1,
            minimumRowBytes: 1,
            expectedHeight: 2,
            maxDecodedBytes: Int.max,
            compressionMode: 1
        ))
        XCTAssertThrowsError(try FramePlaneValidation.validate(
            stride: 1024,
            height: 1024,
            encodedLength: 1,
            minimumRowBytes: 1024,
            expectedHeight: 1024,
            maxDecodedBytes: 1024,
            compressionMode: 2
        ))
    }

    func testRejectsInvalidEncodedLengthsAndCompressionMode() {
        XCTAssertThrowsError(try FramePlaneValidation.validate(
            stride: 64,
            height: 64,
            encodedLength: 4095,
            minimumRowBytes: 64,
            expectedHeight: 64,
            maxDecodedBytes: 4096,
            compressionMode: 0
        ))
        XCTAssertThrowsError(try FramePlaneValidation.validate(
            stride: 64,
            height: 64,
            encodedLength: 0,
            minimumRowBytes: 64,
            expectedHeight: 64,
            maxDecodedBytes: 4096,
            compressionMode: 1
        ))
        XCTAssertThrowsError(try FramePlaneValidation.validate(
            stride: 64,
            height: 64,
            encodedLength: 1,
            minimumRowBytes: 64,
            expectedHeight: 64,
            maxDecodedBytes: 4096,
            compressionMode: 99
        ))
    }

    func testRejectsTotalDecodedSizeOverflowAndLimit() {
        XCTAssertThrowsError(try FramePlaneValidation.validateTotalDecodedBytes(
            [
                ValidatedFramePlaneLayout(stride: 1, height: 1, decodedSize: Int.max),
                ValidatedFramePlaneLayout(stride: 1, height: 1, decodedSize: 1)
            ],
            maxDecodedBytes: Int.max
        ))
        XCTAssertThrowsError(try FramePlaneValidation.validateTotalDecodedBytes(
            [
                ValidatedFramePlaneLayout(stride: 1, height: 1, decodedSize: 6),
                ValidatedFramePlaneLayout(stride: 1, height: 1, decodedSize: 5)
            ],
            maxDecodedBytes: 10
        ))
    }
}
