@testable import VTRemotedCore
import XCTest

final class HDRToSDRSettingsTests: XCTestCase {
    func testExplicitOptInAndSupportedConfiguration() throws {
        XCTAssertNil(try HDRToSDRSettings(codec: .hevc, mode: .transcode,
                                         pixelFormat: VTRPixelFormat.p010, options: [:]))
        for transfer in ["16", "18"] {
            for format in [VTRPixelFormat.nv12, VTRPixelFormat.p010] {
                let settings = try XCTUnwrap(HDRToSDRSettings(codec: .hevc, mode: .transcode,
                    pixelFormat: format, options: ["hdr_to_sdr": "1", "hdr_source_transfer": transfer,
                                                   "hdr_source_peak": "1000"]))
                XCTAssertEqual(settings.sourceTransfer, Int(transfer))
                XCTAssertEqual(settings.sourcePeakNits, 1000)
            }
        }
    }

    func testRejectsUnsupportedRequestsAndConflictingOutputTags() {
        let valid = ["hdr_to_sdr": "1", "hdr_source_transfer": "16"]
        for codec in [VideoCodec.h264] {
            XCTAssertThrowsError(try HDRToSDRSettings(codec: codec, mode: .transcode,
                pixelFormat: VTRPixelFormat.nv12, options: valid))
        }
        for mode in [SessionMode.encode, .decode] {
            XCTAssertThrowsError(try HDRToSDRSettings(codec: .hevc, mode: mode,
                pixelFormat: VTRPixelFormat.nv12, options: valid))
        }
        for (key, values) in ["hdr_to_sdr": ["true", "2", ""],
                              "hdr_source_transfer": ["", "1", "2"],
                              "hdr_source_peak": ["nan", "inf", "0", "-1", "10001"],
                              "color_range": ["2"], "colorspace": ["9"],
                              "color_primaries": ["9"], "color_trc": ["16", "18"]] {
            for value in values {
                var options = valid
                options[key] = value
                XCTAssertThrowsError(try HDRToSDRSettings(codec: .hevc, mode: .transcode,
                    pixelFormat: VTRPixelFormat.nv12, options: options), "\(key)=\(value)")
            }
        }
    }

    func testRemovesHDRMetadataAndPreservesCaptions() {
        for type: UInt32 in [20, 22, 28, 29, 31, 41] {
            XCTAssertTrue(HDRToSDRSettings.isHDRSideData(type))
        }
        for type: UInt32 in [0, 23, 30, UInt32.max] {
            XCTAssertFalse(HDRToSDRSettings.isHDRSideData(type))
        }
    }
}

#if canImport(CoreImage) && canImport(CoreVideo)
    import CoreImage
    import CoreVideo

    final class HDRToneMapperTests: XCTestCase {
        private func settings(transfer: Int = 16, peak: Double? = nil) throws -> HDRToSDRSettings {
            var options = ["hdr_to_sdr": "1", "hdr_source_transfer": String(transfer)]
            if let peak { options["hdr_source_peak"] = String(peak) }
            return try XCTUnwrap(HDRToSDRSettings(codec: .hevc, mode: .transcode,
                pixelFormat: VTRPixelFormat.nv12, options: options))
        }

        // ST 2084 reference encoding, independent of the native mapping implementation.
        private func pq(_ nits: Double) -> Double {
            let p = pow(nits / 10000, 2610.0 / 16384)
            return pow((3424.0 / 4096 + 2413.0 / 128 * p) / (1 + 2392.0 / 128 * p), 2523.0 / 32)
        }

        private func source(_ codes: [Double], cb: Double = 0, cr: Double = 0,
                            width: Int = 160) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, 16,
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
            let value = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(value, [])
            defer { CVPixelBufferUnlockBaseAddress(value, []) }
            for plane in 0..<2 {
                let rows = CVPixelBufferGetHeightOfPlane(value, plane)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(value, plane) / 2
                let base = CVPixelBufferGetBaseAddressOfPlane(value, plane)!.assumingMemoryBound(to: UInt16.self)
                for y in 0..<rows {
                    for x in 0..<width {
                        let code = plane == 0 ? 64 + 876 * codes[min(codes.count - 1, x * codes.count / width)] :
                            512 + 896 * (x % 2 == 0 ? cb : cr)
                        base[y * stride + x] = UInt16(min(1023, max(0, code.rounded()))) << 6
                    }
                }
            }
            return value
        }

        private func rgb(_ buffer: CVPixelBuffer, x: Int) -> [Double] {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(buffer)!.advanced(by: 16 * x)
                .assumingMemoryBound(to: Float.self)
            return (0..<3).map { Double(base[$0]) }
        }

        private func linear(_ mapper: HDRToneMapper, _ source: CVPixelBuffer,
                            _ settings: HDRToSDRSettings) throws -> CVPixelBuffer {
            let image = try mapper.mappedImage(source, settings: settings)
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(source),
                CVPixelBufferGetHeight(source), kCVPixelFormatType_128RGBAFloat, nil, &buffer), noErr)
            let output = try XCTUnwrap(buffer)
            let destination = CIRenderDestination(pixelBuffer: output)
            destination.colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            try mapper.render(image, to: destination)
            return output
        }

        private func luma(_ buffer: CVPixelBuffer) -> UInt16 {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            return CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt16.self)[80] >> 6
        }

        func testPQAndHLGHighlightDetailAndNeutrality() throws {
            guard #available(macOS 15.0, *) else { throw XCTSkip("requires macOS 15") }
            let mapper = try HDRToneMapper(maxFrameBytes: 1_000_000)
            for peak in [1000.0, 4000, 10000] {
                let nits = [0, 10, 100, 203, peak * 0.5, peak * 0.75, peak]
                let input = try source(nits.map(pq))
                let output = try linear(mapper, input, settings(peak: peak))
                var previous = -1.0
                for index in nits.indices {
                    let sample = rgb(output, x: index * 160 / nits.count + 8)
                    XCTAssertGreaterThan(sample[0], previous + 0.005, "peak=\(peak) nits=\(nits[index])")
                    XCTAssertEqual(sample[0], sample[1], accuracy: 0.003)
                    XCTAssertEqual(sample[0], sample[2], accuracy: 0.003)
                    previous = sample[0]
                }
                XCTAssertEqual(previous, 1, accuracy: 0.04)
            }
            // HLG defaults to its nominal 1000-nit display peak without metadata.
            let hlg = try linear(mapper, source([0, 0.3, 0.5, 0.7, 0.85, 1]), settings(transfer: 18))
            let highlights = [92, 120, 146].map { rgb(hlg, x: $0)[0] }
            XCTAssertGreaterThan(highlights[1] - highlights[0], 0.05)
            XCTAssertGreaterThan(highlights[2] - highlights[1], 0.05)
            XCTAssertEqual(highlights[2], 1, accuracy: 0.04)
        }

        func testEncodedBT709OutputPreservesNeutralChroma() throws {
            guard #available(macOS 15.0, *) else { throw XCTSkip("requires macOS 15") }
            let mapper = try HDRToneMapper(maxFrameBytes: 1_000_000)
            for transfer in [16, 18] {
                let input = try source([0.3, 0.5, 0.7, 0.85, 1])
                let output = try mapper.map(input, settings: settings(transfer: transfer))
                CVPixelBufferLockBaseAddress(output, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
                let uv = CVPixelBufferGetBaseAddressOfPlane(output, 1)!.assumingMemoryBound(to: UInt16.self)
                let row = CVPixelBufferGetBytesPerRowOfPlane(output, 1) / 2
                for x in stride(from: 12, to: 160, by: 32) {
                    XCTAssertEqual(Double(uv[3 * row + x] >> 6), 512, accuracy: 1, "transfer=\(transfer) Cb")
                    XCTAssertEqual(Double(uv[3 * row + x + 1] >> 6), 512, accuracy: 1, "transfer=\(transfer) Cr")
                }
            }
        }

        func testPreservesTenBitStepsAndConvertsBT2020Primaries() throws {
            guard #available(macOS 15.0, *) else { throw XCTSkip("requires macOS 15") }
            let mapper = try HDRToneMapper(maxFrameBytes: 1_000_000)
            let steps = try linear(mapper, source([600, 601, 602, 603].map { ($0 - 64) / 876 }),
                                   settings(peak: 1000))
            let values = [20, 60, 100, 140].map { rgb(steps, x: $0)[0] }
            XCTAssertEqual(Set(values).count, 4, "adjacent 10-bit codes must survive mapping")
            // BT.2020 red at 100 nits. The mapped chromaticity must follow the
            // BT.2020 -> BT.709 primary matrix, independently of the tone curve.
            let encodedRed = pq(100)
            let y = 0.2627 * encodedRed
            let red = try source([y], cb: -y / 1.8814, cr: (encodedRed - y) / 1.4746)
            let result = rgb(try linear(mapper, red, settings(peak: 203)), x: 80)
            XCTAssertGreaterThan(result[0], 0.3)
            XCTAssertEqual(result[1] / result[0], -0.124550 / 1.660491, accuracy: 0.008)
            XCTAssertEqual(result[2] / result[0], -0.018151 / 1.660491, accuracy: 0.008)
        }

        func testFrameContentLightOverridesStaticPeakAndZeroMeansUnknown() throws {
            guard #available(macOS 15.0, *) else { throw XCTSkip("requires macOS 15") }
            let mapper = try HDRToneMapper(maxFrameBytes: 1_000_000)
            let input = try source([pq(1000)])
            CVBufferSetAttachment(input, kCVImageBufferContentLightLevelInfoKey,
                Data([0x03, 0xe8, 0, 203]) as CFData, .shouldPropagate)
            let framePeak = rgb(try linear(mapper, input, settings(peak: 10000)), x: 80)[0]
            XCTAssertEqual(framePeak, 1, accuracy: 0.04)
            CVBufferSetAttachment(input, kCVImageBufferContentLightLevelInfoKey,
                Data([0, 0, 0, 0]) as CFData, .shouldPropagate)
            let staticPeak = rgb(try linear(mapper, input, settings(peak: 10000)), x: 80)[0]
            XCTAssertLessThan(staticPeak, 0.8)
            XCTAssertGreaterThan(staticPeak, 0.4)
        }

        func testRetainedBuffersGeometryMetadataAndMemoryLimit() throws {
            guard #available(macOS 15.0, *) else { throw XCTSkip("requires macOS 15") }
            let mapper = try HDRToneMapper(maxFrameBytes: 160 * 16 * 16)
            let input = try source([pq(100)])
            CVBufferSetAttachment(input, kCVImageBufferPixelAspectRatioKey,
                [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 4,
                 kCVImageBufferPixelAspectRatioVerticalSpacingKey: 3] as CFDictionary, .shouldPropagate)
            let first = try mapper.map(input, settings: settings(peak: 1000))
            let original = luma(first)
            _ = try mapper.map(source([pq(1000)]), settings: settings(peak: 1000))
            XCTAssertEqual(luma(first), original, "a retained frame cannot be overwritten")
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(first), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            XCTAssertNotNil(CVBufferCopyAttachment(first, kCVImageBufferPixelAspectRatioKey, nil))
            mapper.tagOutput(first)
            let transfer = try XCTUnwrap(CVBufferCopyAttachment(first, kCVImageBufferTransferFunctionKey, nil))
            XCTAssertEqual(transfer as? String, kCVImageBufferTransferFunction_ITU_R_709_2 as String)
            XCTAssertNil(CVBufferCopyAttachment(first, kCVImageBufferContentLightLevelInfoKey, nil))
            XCTAssertThrowsError(try mapper.map(source([pq(100)], width: 320), settings: settings()))
        }
    }
#endif
