#if canImport(VideoToolbox) && canImport(CoreVideo)
    import CoreVideo
    import VideoToolbox
    @testable import VTRemotedCore
    import XCTest

    final class TranscodePixelTransferTests: XCTestCase {
        private let nv12 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        private func buffer(_ width: Int, _ height: Int, _ format: OSType,
                            surface: Bool) throws -> CVPixelBuffer {
            var result: CVPixelBuffer?
            let attributes: [CFString: Any] = surface ? [kCVPixelBufferIOSurfacePropertiesKey: [:]] : [:]
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                               attributes as CFDictionary, &result), noErr)
            let value = try XCTUnwrap(result)
            XCTAssertEqual(CVPixelBufferGetIOSurface(value) != nil, surface)
            return value
        }

        private func session(_ mode: CFString = kVTScalingMode_Normal) throws -> VTPixelTransferSession {
            var result: VTPixelTransferSession?
            XCTAssertEqual(VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault,
                                                        pixelTransferSessionOut: &result), noErr)
            let value = try XCTUnwrap(result)
            XCTAssertEqual(VTSessionSetProperty(value, key: kVTPixelTransferPropertyKey_ScalingMode,
                                                value: mode), noErr)
            return value
        }

        private func tag(_ buffer: CVPixelBuffer, cropped: Bool = false, alternate: Bool = false) {
            let values: [CFString: Any] = [
                kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
                kCVImageBufferYCbCrMatrixKey: alternate ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 :
                    kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                kCVImageBufferChromaLocationTopFieldKey: kCVImageBufferChromaLocation_Left,
                kCVImageBufferPixelAspectRatioKey: [
                    kCVImageBufferPixelAspectRatioHorizontalSpacingKey: cropped ? 4 : 1,
                    kCVImageBufferPixelAspectRatioVerticalSpacingKey: cropped ? 3 : 1
                ],
                kCVImageBufferCleanApertureKey: [
                    kCVImageBufferCleanApertureWidthKey: CVPixelBufferGetWidth(buffer) - (cropped ? 8 : 0),
                    kCVImageBufferCleanApertureHeightKey: CVPixelBufferGetHeight(buffer) - (cropped ? 6 : 0),
                    kCVImageBufferCleanApertureHorizontalOffsetKey: cropped ? 2 : 0,
                    kCVImageBufferCleanApertureVerticalOffsetKey: cropped ? -1 : 0
                ]
            ]
            CVBufferSetAttachments(buffer, values as CFDictionary, .shouldPropagate)
        }

        private func fill(_ buffer: CVPixelBuffer, seed: Int = 0) {
            XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), noErr)
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let format = CVPixelBufferGetPixelFormatType(buffer)
            let planes = CVPixelBufferGetPlaneCount(buffer)
            let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                format == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            for plane in 0..<max(1, planes) {
                let base = (planes == 0 ? CVPixelBufferGetBaseAddress(buffer) :
                    CVPixelBufferGetBaseAddressOfPlane(buffer, plane))!
                let stride = planes == 0 ? CVPixelBufferGetBytesPerRow(buffer) :
                    CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let height = planes == 0 ? CVPixelBufferGetHeight(buffer) :
                    CVPixelBufferGetHeightOfPlane(buffer, plane)
                for row in 0..<height {
                    for column in 0..<(stride / (tenBit ? 2 : 1)) {
                        let pattern = (column * 13 + row * 7 + plane * 31 + seed) % (tenBit ? 800 : 200)
                        if tenBit {
                            base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)[column] =
                                UInt16(64 + pattern) << 6
                        } else {
                            base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)[column] =
                                UInt8(16 + pattern)
                        }
                    }
                }
            }
        }

        private func pixels(_ buffer: CVPixelBuffer) -> Data {
            XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, .readOnly), noErr)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let planes = CVPixelBufferGetPlaneCount(buffer)
            let format = CVPixelBufferGetPixelFormatType(buffer)
            let bytes = planes == 0 ? 4 :
                (format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                    format == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange ? 2 : 1)
            let rowBytes = CVPixelBufferGetWidth(buffer) * bytes
            var data = Data()
            for plane in 0..<max(1, planes) {
                let base = (planes == 0 ? CVPixelBufferGetBaseAddress(buffer) :
                    CVPixelBufferGetBaseAddressOfPlane(buffer, plane))!.assumingMemoryBound(to: UInt8.self)
                let stride = planes == 0 ? CVPixelBufferGetBytesPerRow(buffer) :
                    CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let rows = planes == 0 ? CVPixelBufferGetHeight(buffer) :
                    CVPixelBufferGetHeightOfPlane(buffer, plane)
                for row in 0..<rows { data.append(base.advanced(by: row * stride), count: rowBytes) }
            }
            return data
        }

        func testDownscaleUsesHalfPixelCenteredCoordinates() throws {
            let source = try buffer(1920, 1080, nv12, surface: true)
            tag(source)
            XCTAssertEqual(CVPixelBufferLockBaseAddress(source, []), noErr)
            let y = CVPixelBufferGetBaseAddressOfPlane(source, 0)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(source, 0)
            for row in 0..<1080 {
                for column in 0..<1920 {
                    let distance = Double((column - 601) * (column - 601) + (row - 501) * (row - 501))
                    y[row * stride + column] = UInt8((63 + 140 * exp(-distance / 128)).rounded())
                }
            }
            memset(CVPixelBufferGetBaseAddressOfPlane(source, 1)!, 128,
                   CVPixelBufferGetBytesPerRowOfPlane(source, 1) * 540)
            CVPixelBufferUnlockBaseAddress(source, [])
            let transfer = TranscodePixelTransfer()
            let session = try session()
            defer { VTPixelTransferSessionInvalidate(session) }
            for (width, height) in [(1536, 864), (1280, 720), (960, 540), (480, 270),
                                    (1280, 1080), (1920, 720), (2560, 720)] {
                let output = try buffer(width, height, nv12, surface: true)
                try transfer.transfer(session, from: source, to: output)
                let expectedX = (601.5 * Double(width) / 1920) - 0.5
                let expectedY = (501.5 * Double(height) / 1080) - 0.5
                let data = pixels(output)
                var mass = 0.0, xMass = 0.0, yMass = 0.0
                for row in (Int(expectedY) - 30)...(Int(expectedY) + 30) {
                    for column in (Int(expectedX) - 30)...(Int(expectedX) + 30) {
                        let value = Double(data[row * width + column]) - 63
                        mass += value
                        xMass += value * Double(column)
                        yMass += value * Double(row)
                    }
                }
                XCTAssertGreaterThan(mass, 0)
                XCTAssertEqual(xMass / mass, expectedX, accuracy: 0.04, "width=\(width)")
                XCTAssertEqual(yMass / mass, expectedY, accuracy: 0.04, "height=\(height)")
            }
        }

        func testPaddedPlanesFormatsCropsAndMetadataMatchOrdinaryMemoryTransfer() throws {
            let transfer = TranscodePixelTransfer()
            for format in [nv12, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                           kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                           kCVPixelFormatType_32BGRA, kCVPixelFormatType_4444AYpCbCr8] {
                for mode in [kVTScalingMode_Normal, kVTScalingMode_Letterbox, kVTScalingMode_Trim] {
                    let session = try session(mode)
                    defer { VTPixelTransferSessionInvalidate(session) }
                    for seed in 0..<2 {
                        let source = try buffer(258, 146, format, surface: true)
                        let reference = try buffer(258, 146, format, surface: false)
                        fill(source, seed: seed)
                        fill(reference, seed: seed)
                        tag(source, cropped: true, alternate: seed == 1)
                        tag(reference, cropped: true, alternate: seed == 1)
                        let original = pixels(source)
                        let output = try buffer(130, 74, format, surface: true)
                        let expected = try buffer(130, 74, format, surface: true)
                        try transfer.transfer(session, from: source, to: output)
                        XCTAssertEqual(VTPixelTransferSessionTransferImage(session, from: reference, to: expected), noErr)
                        XCTAssertEqual(pixels(output), pixels(expected), "format=\(format), mode=\(mode)")
                        XCTAssertEqual(pixels(source), original, "decoder input must stay unchanged")
                        let actualTags = CVBufferCopyAttachments(output, .shouldPropagate)
                        let expectedTags = CVBufferCopyAttachments(expected, .shouldPropagate)
                        XCTAssertEqual(actualTags as NSDictionary?, expectedTags as NSDictionary?)
                    }
                }
            }
        }

        func testUnresizedTransferAndChangingInputDimensions() throws {
            let transfer = TranscodePixelTransfer()
            let session = try session()
            defer { VTPixelTransferSessionInvalidate(session) }
            for width in [258, 320, 258] {
                let source = try buffer(width, 146, nv12, surface: true)
                fill(source)
                tag(source)
                let identical = try buffer(width, 146, nv12, surface: true)
                let expectedIdentity = try buffer(width, 146, nv12, surface: true)
                try transfer.transfer(session, from: source, to: identical)
                // Some virtualized drivers round samples even for identity
                // transfer. The unchanged path must preserve Apple's behavior.
                XCTAssertEqual(VTPixelTransferSessionTransferImage(session, from: source,
                                                                    to: expectedIdentity), noErr)
                XCTAssertEqual(pixels(identical), pixels(expectedIdentity))
                let small = try buffer(130, 74, nv12, surface: true)
                let reference = try buffer(width, 146, nv12, surface: false)
                fill(reference)
                tag(reference)
                let expectedSmall = try buffer(130, 74, nv12, surface: true)
                try transfer.transfer(session, from: source, to: small)
                XCTAssertEqual(VTPixelTransferSessionTransferImage(session, from: reference,
                                                                    to: expectedSmall), noErr)
                XCTAssertEqual(pixels(small), pixels(expectedSmall))
            }
            transfer.reset()
        }
    }
#endif
