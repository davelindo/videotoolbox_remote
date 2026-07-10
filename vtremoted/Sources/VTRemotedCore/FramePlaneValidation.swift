import Foundation

struct ValidatedFramePlaneLayout: Equatable {
    let stride: Int
    let height: Int
    let decodedSize: Int
}

enum FramePlaneValidation {
    // Keeping wire metadata and negotiated limits explicit makes each validation call auditable.
    // swiftlint:disable:next function_parameter_count
    static func validate(
        stride: Int,
        height: Int,
        encodedLength: Int,
        minimumRowBytes: Int,
        expectedHeight: Int,
        maxDecodedBytes: Int,
        compressionMode: Int
    ) throws -> ValidatedFramePlaneLayout {
        guard stride > 0, height > 0, encodedLength >= 0 else {
            throw VTRemotedError.protocolViolation("invalid plane geometry")
        }
        guard height == expectedHeight else {
            throw VTRemotedError.protocolViolation(
                "invalid plane height \(height), expected \(expectedHeight)"
            )
        }
        guard minimumRowBytes > 0, stride >= minimumRowBytes else {
            throw VTRemotedError.protocolViolation(
                "invalid plane stride \(stride), minimum \(minimumRowBytes)"
            )
        }

        let (decodedSize, overflow) = stride.multipliedReportingOverflow(by: height)
        guard !overflow, decodedSize > 0, decodedSize <= max(1, maxDecodedBytes) else {
            throw VTRemotedError.protocolViolation("decoded plane size exceeds limit")
        }

        switch compressionMode {
        case 0:
            guard encodedLength >= decodedSize else {
                throw VTRemotedError.protocolViolation("plane too small")
            }
        case 1, 2:
            guard encodedLength > 0 else {
                throw VTRemotedError.protocolViolation("empty compressed plane")
            }
        default:
            throw VTRemotedError.protocolViolation(
                "unsupported wire compression mode \(compressionMode)"
            )
        }

        return ValidatedFramePlaneLayout(
            stride: stride,
            height: height,
            decodedSize: decodedSize
        )
    }

    static func validateTotalDecodedBytes(
        _ layouts: [ValidatedFramePlaneLayout],
        maxDecodedBytes: Int
    ) throws {
        var total = 0
        for layout in layouts {
            let (next, overflow) = total.addingReportingOverflow(layout.decodedSize)
            guard !overflow, next <= max(1, maxDecodedBytes) else {
                throw VTRemotedError.protocolViolation("decoded frame size exceeds limit")
            }
            total = next
        }
    }
}
