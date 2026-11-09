#if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo)
    import CoreMedia
    import CoreVideo
    import VideoToolbox
    @testable import VTRemotedCore
    import XCTest

    final class DecoderCallbackTests: XCTestCase {
        private let leadingDrop: VTDecodeInfoFlags = [.frameDropped, .skippedLeadingFrameDropped]

        private func image() throws -> CVPixelBuffer {
            var result: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 96, 64,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &result), kCVReturnSuccess)
            let buffer = try XCTUnwrap(result)
            XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
            for plane in 0..<2 {
                memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!, plane == 0 ? 16 : 128,
                       CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return buffer
        }

        func testLeadingDropsDiscardOnlyTheirSideDataAndContinueOutput() throws {
            // VPS/SPS/PPS from a synthetic 96x64 HEVC stream with open GOPs.
            let extra = try XCTUnwrap(Data(base64Encoded:
                "AAAAAUABDAH//wFgAAADAJAAAAMAAAMAHpWUCQAAAAFCAQEBYAAAAwCQAAADAAADAB6gMIEFllZUpMLwFoCAAAADAIAAAAYEAAAAAUQBwHPBiQ=="))
            for mode in ["decode", "transcode"] {
                var sent: [(VTRMessageType, Data)] = []
                let session = VideoToolboxCodecSession { type, chunks in
                    sent.append((type, chunks.reduce(into: Data()) { $0.append($1) }))
                }
                defer { session.shutdown() }
                let request = ConfigureRequest(width: 96, height: 64, pixelFormat: VTRPixelFormat.nv12,
                    timebase: Timebase(num: 1, den: 90000), frameRate: (num: 30, den: 1),
                    options: ["mode": mode, "out_codec": "h264", "allow_sw": "1",
                              "decode_async": "0", "decode_reorder_depth": "0", "max_b_frames": "0"],
                    extradata: extra)
                _ = try session.configure(SessionConfiguration(codec: .hevc, request: request))
                let omitted = Data(repeating: 0xD3, count: 32)
                let retained = Data(repeating: 0x7B, count: 32)
                for pts in [Int64(3000), 4500] {
                    session.storePendingDecodeSideData(ptsTicks: pts,
                        sideData: [.init(type: 1000, data: omitted)])
                }
                session.storePendingDecodeSideData(ptsTicks: 6000,
                    sideData: [.init(type: 1000, data: retained)])
                session.handleDecoderOutput(status: kVTVideoDecoderReferenceMissingErr, flags: leadingDrop,
                    imageBuffer: nil, pts: CMTime(value: 1, timescale: 30), duration: .invalid)
                session.handleDecoderOutput(status: noErr, flags: leadingDrop.union(.asynchronous),
                    imageBuffer: nil, pts: CMTime(value: 3, timescale: 60), duration: .invalid)
                XCTAssertTrue(session.takePendingDecodeSideData(ptsTicks: 3000).isEmpty, mode)
                XCTAssertTrue(session.takePendingDecodeSideData(ptsTicks: 4500).isEmpty, mode)
                XCTAssertTrue(sent.isEmpty, mode)
                session.handleDecoderOutput(status: noErr, flags: [], imageBuffer: try image(),
                    pts: CMTime(value: 2, timescale: 30), duration: CMTime(value: 1, timescale: 30))
                try session.flush()
                XCTAssertEqual(sent.count, 1, mode)
                XCTAssertEqual(sent.first?.0, mode == "decode" ? .frame : .packet, mode)
                let body = try XCTUnwrap(sent.first?.1)
                XCTAssertNotNil(body.range(of: retained), mode)
                XCTAssertNil(body.range(of: omitted), mode)
            }
        }

        func testUnexpectedCallbacksRemainTerminal() throws {
            let buffer = try image()
            let cases: [(OSStatus, VTDecodeInfoFlags, CVImageBuffer?)] = [
                (noErr, [], nil),
                (noErr, .frameDropped, nil),
                (noErr, .skippedLeadingFrameDropped, nil),
                (noErr, leadingDrop, buffer),
                (noErr, leadingDrop.union(.imageBufferModifiable), nil),
                (kVTVideoDecoderReferenceMissingErr, [], nil),
                (kVTVideoDecoderReferenceMissingErr, .frameDropped, nil),
                (kVTVideoDecoderBadDataErr, leadingDrop, nil),
                (kVTVideoDecoderBadDataErr, [], buffer)
            ]
            for (status, flags, image) in cases {
                var sent: [VTRMessageType] = []
                let session = VideoToolboxCodecSession { type, _ in sent.append(type) }
                session.handleDecoderOutput(status: status, flags: flags, imageBuffer: image,
                    pts: .zero, duration: .invalid)
                XCTAssertEqual(sent, [.error], "status=\(status) flags=\(flags.rawValue)")
                XCTAssertThrowsError(try session.flush())
                session.handleDecoderOutput(status: kVTVideoDecoderReferenceMissingErr, flags: leadingDrop,
                    imageBuffer: nil, pts: .zero, duration: .invalid)
                XCTAssertThrowsError(try session.flush(), "a drop must not clear an earlier failure")
            }
        }
    }
#endif
