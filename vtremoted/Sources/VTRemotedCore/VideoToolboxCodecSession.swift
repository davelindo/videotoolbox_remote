#if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo)
    import CoreFoundation
    import CoreMedia
    import CoreVideo
    import Foundation
    import VideoToolbox

    /// VideoToolbox-backed encoder/decoder.
    final class VideoToolboxCodecSession: CodecSession {
        private let send: MessageSender
        private let logger = Logger.shared

        private var config: SessionConfiguration?

        private var compressionSession: VTCompressionSession?
        private var decompressionSession: VTDecompressionSession?
        private var formatDescription: CMFormatDescription?
        private var nalLengthField: Int = 4
        private var cvPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        private var encoderExtradata: Data?

        private var warmupPending = false
        private let warmupSemaphore = DispatchSemaphore(value: 0)
        private var forceKeyframeNext = false

        private class FrameContext {
            let sideData: [Data]
            init(sideData: [Data]) {
                self.sideData = sideData
            }
        }

        private let kVTPropertyNotSupportedErr: OSStatus = -12900

        // Some VT constants are missing from older Swift overlays when building outside Xcode.
        private let vtKeyRateControlMode: CFString = "RateControlMode" as CFString
        private let vtRateControlModeAverageBitRate: CFString = "AverageBitRate" as CFString
        private let vtKeyConstantBitRate: CFString = "ConstantBitRate" as CFString
        private let vtKeyPrioritizeSpeed: CFString = "PrioritizeEncodingSpeedOverQuality" as CFString
        private let vtKeyEncoderID: CFString = "EncoderID" as CFString
        private let vtKeySpatialAdaptiveQP: CFString = "SpatialAdaptiveQPLevel" as CFString
        private let vtKeyAllowOpenGOP: CFString = "AllowOpenGOP" as CFString
        private let vtKeyMaximizePowerEfficiency: CFString = "MaximizePowerEfficiency" as CFString
        private let vtKeyReferenceBufferCount: CFString = "ReferenceBufferCount" as CFString
        private let vtKeyMinAllowedFrameQP: CFString = "MinAllowedFrameQP" as CFString
        private let vtKeyMaxAllowedFrameQP: CFString = "MaxAllowedFrameQP" as CFString
        private let vtKeyMaxH264SliceBytes: CFString = "MaxH264SliceBytes" as CFString
        private let vtKeyH264EntropyMode: CFString = "H264EntropyMode" as CFString
        private let vtH264EntropyCAVLC: CFString = "CAVLC" as CFString
        private let vtH264EntropyCABAC: CFString = "CABAC" as CFString
        private let vtKeyTargetQualityForAlpha: CFString = "TargetQualityForAlpha" as CFString
        private let vtKeyEnableHWEncoder: CFString = "EnableHardwareAcceleratedVideoEncoder" as CFString
        private let vtKeyRequireHWEncoder: CFString = "RequireHardwareAcceleratedVideoEncoder" as CFString
        private let vtKeyLowLatencyRC: CFString = "EnableLowLatencyRateControl" as CFString

        private let vtProfileH264Baseline13: CFString = "H264_Baseline_1_3" as CFString
        private let vtProfileH264Baseline30: CFString = "H264_Baseline_3_0" as CFString
        private let vtProfileH264Baseline31: CFString = "H264_Baseline_3_1" as CFString
        private let vtProfileH264Baseline32: CFString = "H264_Baseline_3_2" as CFString
        private let vtProfileH264Baseline40: CFString = "H264_Baseline_4_0" as CFString
        private let vtProfileH264Baseline41: CFString = "H264_Baseline_4_1" as CFString
        private let vtProfileH264Baseline42: CFString = "H264_Baseline_4_2" as CFString
        private let vtProfileH264Baseline50: CFString = "H264_Baseline_5_0" as CFString
        private let vtProfileH264Baseline51: CFString = "H264_Baseline_5_1" as CFString
        private let vtProfileH264Baseline52: CFString = "H264_Baseline_5_2" as CFString
        private let vtProfileH264BaselineAuto: CFString = "H264_Baseline_AutoLevel" as CFString
        private let vtProfileH264ConstrainedBaselineAuto: CFString = "H264_ConstrainedBaseline_AutoLevel" as CFString

        private let vtProfileH264Main30: CFString = "H264_Main_3_0" as CFString
        private let vtProfileH264Main31: CFString = "H264_Main_3_1" as CFString
        private let vtProfileH264Main32: CFString = "H264_Main_3_2" as CFString
        private let vtProfileH264Main40: CFString = "H264_Main_4_0" as CFString
        private let vtProfileH264Main41: CFString = "H264_Main_4_1" as CFString
        private let vtProfileH264Main42: CFString = "H264_Main_4_2" as CFString
        private let vtProfileH264Main50: CFString = "H264_Main_5_0" as CFString
        private let vtProfileH264Main51: CFString = "H264_Main_5_1" as CFString
        private let vtProfileH264Main52: CFString = "H264_Main_5_2" as CFString
        private let vtProfileH264MainAuto: CFString = "H264_Main_AutoLevel" as CFString

        private let vtProfileH264High30: CFString = "H264_High_3_0" as CFString
        private let vtProfileH264High31: CFString = "H264_High_3_1" as CFString
        private let vtProfileH264High32: CFString = "H264_High_3_2" as CFString
        private let vtProfileH264High40: CFString = "H264_High_4_0" as CFString
        private let vtProfileH264High41: CFString = "H264_High_4_1" as CFString
        private let vtProfileH264High42: CFString = "H264_High_4_2" as CFString
        private let vtProfileH264High50: CFString = "H264_High_5_0" as CFString
        private let vtProfileH264High51: CFString = "H264_High_5_1" as CFString
        private let vtProfileH264High52: CFString = "H264_High_5_2" as CFString
        private let vtProfileH264HighAuto: CFString = "H264_High_AutoLevel" as CFString
        private let vtProfileH264ConstrainedHighAuto: CFString = "H264_ConstrainedHigh_AutoLevel" as CFString
        private let vtProfileH264Extended50: CFString = "H264_Extended_5_0" as CFString
        private let vtProfileH264ExtendedAuto: CFString = "H264_Extended_AutoLevel" as CFString

        private let vtProfileHEVCMainAuto: CFString = "HEVC_Main_AutoLevel" as CFString
        private let vtProfileHEVCMain10Auto: CFString = "HEVC_Main10_AutoLevel" as CFString
        private let vtProfileHEVCMain42210Auto: CFString = "HEVC_Main42210_AutoLevel" as CFString

        init(sender: @escaping MessageSender) {
            send = sender
        }

        func configure(_ configuration: SessionConfiguration) throws -> Data {
            config = configuration
            switch configuration.mode {
            case .encode:
                try setupEncoder(configuration)
                try warmup()
                return encoderExtradata ?? Data()
            case .decode:
                try setupDecoder(configuration)
                return Data()
            }
        }

        func handleFrameMessage(_ payload: Data) throws {
            guard let config else { throw VTRemotedError.protocolViolation("FRAME before CONFIGURE") }
            guard config.mode == .encode else { return }
            guard let session = compressionSession else { throw VTRemotedError.videoToolboxUnavailable }

            var reader = ByteReader(payload)
            let ptsTicks = try Int64(bitPattern: reader.readBEUInt64())
            _ = try reader.readBEUInt64() // duration ticks (ignored)
            let flags = try reader.readBEUInt32()
            let planes = try reader.readUInt8()
            guard planes == 2 else { throw VTRemotedError.protocolViolation("expected 2 planes") }

            let stride0 = try Int(reader.readBEUInt32())
            let height0 = try Int(reader.readBEUInt32())
            let len0 = try Int(reader.readBEUInt32())
            let yRaw = try reader.readBytes(count: len0)

            let stride1 = try Int(reader.readBEUInt32())
            let height1 = try Int(reader.readBEUInt32())
            let len1 = try Int(reader.readBEUInt32())
            let uvRaw = try reader.readBytes(count: len1)

            let expectedY = max(0, stride0 * height0)
            let expectedUV = max(0, stride1 * height1)

            let yPlane: Data
            let uvPlane: Data
            if config.options.wireCompression == 1 {
                guard let yDecomp = LZ4Codec.decompress(yRaw, expectedSize: expectedY),
                      let uvDecomp = LZ4Codec.decompress(uvRaw, expectedSize: expectedUV)
                else {
                    throw VTRemotedError.protocolViolation("LZ4 decompress failed")
                }
                yPlane = yDecomp
                uvPlane = uvDecomp
            } else if config.options.wireCompression == 2 {
                guard let yDecomp = ZstdCodec.decompress(yRaw, expectedSize: expectedY),
                      let uvDecomp = ZstdCodec.decompress(uvRaw, expectedSize: expectedUV)
                else {
                    throw VTRemotedError.protocolViolation("Zstd decompress failed")
                }
                yPlane = yDecomp
                uvPlane = uvDecomp
            } else {
                yPlane = yRaw
                uvPlane = uvRaw
            }

            guard let pool = VTCompressionSessionGetPixelBufferPool(session) else {
                throw VTRemotedError.videoToolboxUnavailable
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            guard status == kCVReturnSuccess, let pBuffer = pixelBuffer else {
                throw VTRemotedError.ioError(code: Int32(status), message: "CVPixelBufferPoolCreatePixelBuffer failed")
            }

            CVPixelBufferLockBaseAddress(pBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pBuffer, []) }

            let bytesPerSample = (config.pixelFormat == 2) ? 2 : 1
            let rowBytesY = config.width * bytesPerSample
            let rowBytesUV = config.width * bytesPerSample

            yPlane.withUnsafeBytes { yPtr in
                uvPlane.withUnsafeBytes { uvPtr in
                    let ySrc = yPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let uvSrc = uvPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)

                    if let yDst = CVPixelBufferGetBaseAddressOfPlane(pBuffer, 0) {
                        let dstStride = CVPixelBufferGetBytesPerRowOfPlane(pBuffer, 0)
                        let rowBytes = min(rowBytesY, min(stride0, dstStride))
                        for yIdx in 0 ..< height0 {
                            memcpy(yDst.advanced(by: yIdx * dstStride), ySrc.advanced(by: yIdx * stride0), rowBytes)
                        }
                    }
                    if let uvDst = CVPixelBufferGetBaseAddressOfPlane(pBuffer, 1) {
                        let dstStride = CVPixelBufferGetBytesPerRowOfPlane(pBuffer, 1)
                        let rowBytes = min(rowBytesUV, min(stride1, dstStride))
                        for yIdx in 0 ..< height1 {
                            memcpy(uvDst.advanced(by: yIdx * dstStride), uvSrc.advanced(by: yIdx * stride1), rowBytes)
                        }
                    }
                }
            }

            // Parse side data (V1 extension)
            var sideData: [Data] = []
            if reader.remaining > 0 {
                let sideDataCount = try reader.readUInt8()
                for _ in 0 ..< sideDataCount {
                    let type = try reader.readBEUInt32()
                    let size = try reader.readBEUInt32()
                    let data = try reader.readBytes(count: Int(size))
                    if type == 2 { // A53_CC
                        sideData.append(data)
                    }
                }
            }

            let pts = cmTime(fromTicks: ptsTicks, timebase: config.timebase)
            let forceKey = (flags & 1) != 0 || forceKeyframeNext
            let props: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            forceKeyframeNext = false

            let frameContext = FrameContext(sideData: sideData)
            let ctxPtr = Unmanaged.passRetained(frameContext).toOpaque()

            VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pBuffer,
                presentationTimeStamp: pts,
                duration: .invalid,
                frameProperties: props,
                sourceFrameRefcon: ctxPtr,
                infoFlagsOut: nil
            )
        }

        func handlePacketMessage(_ payload: Data) throws {
            guard let config else { throw VTRemotedError.protocolViolation("PACKET before CONFIGURE") }
            guard config.mode == .decode else { return }
            guard let session = decompressionSession, let fmt = formatDescription else {
                throw VTRemotedError.videoToolboxUnavailable
            }

            var reader = ByteReader(payload)
            let ptsTicks = try Int64(bitPattern: reader.readBEUInt64())
            let dtsTicks = try Int64(bitPattern: reader.readBEUInt64())
            let durTicks = try Int64(bitPattern: reader.readBEUInt64())
            _ = try reader.readBEUInt32() // isKey
            let dataLen = try Int(reader.readBEUInt32())
            let annexB = try reader.readBytes(count: dataLen)

            let lengthPrefixed = AnnexB.toLengthPrefixed(annexB, lengthSize: nalLengthField)

            var block: CMBlockBuffer?
            let dataCount = lengthPrefixed.count
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: dataCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataCount,
                flags: 0,
                blockBufferOut: &block
            )
            guard status == noErr, let bufferBlock = block else { return }

            lengthPrefixed.withUnsafeBytes { ptr in
                _ = CMBlockBufferReplaceDataBytes(
                    with: ptr.baseAddress!,
                    blockBuffer: bufferBlock,
                    offsetIntoDestination: 0,
                    dataLength: dataCount
                )
            }

            var timing = CMSampleTimingInfo(
                duration: cmTime(fromTicks: durTicks, timebase: config.timebase),
                presentationTimeStamp: cmTime(fromTicks: ptsTicks, timebase: config.timebase),
                decodeTimeStamp: cmTime(fromTicks: dtsTicks, timebase: config.timebase)
            )

            var sample: CMSampleBuffer?
            status = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: bufferBlock,
                formatDescription: fmt,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: [dataCount],
                sampleBufferOut: &sample
            )
            guard status == noErr, let sampleBuffer = sample else { return }

            status = VTDecompressionSessionDecodeFrame(session,
                                                       sampleBuffer: sampleBuffer,
                                                       flags: [],
                                                       frameRefcon: nil,
                                                       infoFlagsOut: nil)
            if status == noErr {
                _ = VTDecompressionSessionWaitForAsynchronousFrames(session)
            }
        }

        func flush() throws {
            if let session = compressionSession {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            }
            if let session = decompressionSession {
                _ = VTDecompressionSessionFinishDelayedFrames(session)
                _ = VTDecompressionSessionWaitForAsynchronousFrames(session)
            }
        }

        func shutdown() {
            if let session = compressionSession {
                VTCompressionSessionInvalidate(session)
            }
            if let session = decompressionSession {
                VTDecompressionSessionInvalidate(session)
            }
        }

        // MARK: - Encoder

        private func setupEncoder(_ config: SessionConfiguration) throws {
            let codecType: CMVideoCodecType = switch config.codec {
            case .h264: kCMVideoCodecType_H264
            case .hevc: kCMVideoCodecType_HEVC
            }

            if config.codec == .h264, config.pixelFormat != 1 {
                throw VTRemotedError.unsupported("h264 requires nv12")
            }

            cvPixelFormat = try pickCVPixelFormat(pixelFormat: config.pixelFormat)

            var hasBFrames = config.options.maxBFrames > 0
            var entropy = config.options.entropy
            let profile = config.options.profile

            if config.codec == .h264 {
                if hasBFrames, (profile & 0xFF) == VideoToolboxConstants.AV_PROFILE_H264_BASELINE {
                    logger.info("WARN baseline profile cannot use B-frames; disabling")
                    hasBFrames = false
                }
                if entropy == 2, (profile & 0xFF) == VideoToolboxConstants.AV_PROFILE_H264_BASELINE {
                    logger.info("WARN CABAC requires main/high profile; disabling entropy override")
                    entropy = 0
                }
            }

            let profileLevel = try profileLevelString(
                codec: config.codec,
                profile: profile,
                level: config.options.level,
                pixelFormat: config.pixelFormat,
                hasBFrames: hasBFrames
            )

            let encInfo = NSMutableDictionary()
            if config.options.requireSoftware {
                encInfo[vtKeyEnableHWEncoder] = kCFBooleanFalse
            } else if !config.options.allowSoftware {
                encInfo[vtKeyRequireHWEncoder] = kCFBooleanTrue
            } else {
                encInfo[vtKeyEnableHWEncoder] = kCFBooleanTrue
            }
            if (config.options.flags & VideoToolboxConstants.AV_CODEC_FLAG_LOW_DELAY) != 0,
               config.codec == .h264 || (config.codec == .hevc && isAppleSilicon()) {
                if config.options.bitrate <= 0 {
                    throw VTRemotedError.protocolViolation("low_delay requires bitrate")
                }
                encInfo[vtKeyLowLatencyRC] = kCFBooleanTrue
            }

            let pbInfo = NSMutableDictionary()
            pbInfo[kCVPixelBufferPixelFormatTypeKey] = NSNumber(value: cvPixelFormat)
            pbInfo[kCVPixelBufferWidthKey] = NSNumber(value: config.width)
            pbInfo[kCVPixelBufferHeightKey] = NSNumber(value: config.height)
            if let prim = mapColorPrimaries(config.options.colorPrimaries) {
                pbInfo[kCVImageBufferColorPrimariesKey] = prim
            }
            if let trc = mapTransferFunction(config.options.colorTRC) {
                pbInfo[kCVImageBufferTransferFunctionKey] = trc
            }
            if let mat = mapColorMatrix(config.options.colorSpace) {
                pbInfo[kCVImageBufferYCbCrMatrixKey] = mat
            }

            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(config.width),
                height: Int32(config.height),
                codecType: codecType,
                encoderSpecification: encInfo,
                imageBufferAttributes: pbInfo,
                compressedDataAllocator: nil,
                outputCallback: { refCon, frameRefCon, status, _, sampleBuffer in
                    guard status == noErr, let sbuf = sampleBuffer, CMSampleBufferDataIsReady(sbuf) else {
                        if let frameRefCon {
                            Unmanaged<FrameContext>.fromOpaque(frameRefCon).release()
                        }
                        return
                    }
                    let unmanaged = Unmanaged<VideoToolboxCodecSession>.fromOpaque(refCon!)
                    let context = frameRefCon.map { Unmanaged<FrameContext>.fromOpaque($0).takeRetainedValue() }
                    unmanaged.takeUnretainedValue().handleEncodedSampleBuffer(sbuf, context: context)
                },
                refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                compressionSessionOut: &compressionSession
            )
            guard status == noErr, let session = compressionSession else {
                throw VTRemotedError.ioError(code: Int32(status), message: "VTCompressionSessionCreate failed")
            }

            func setProp(_ key: CFString, _ value: CFTypeRef, _ name: String, fatal: Bool = false) throws {
                let status = VTSessionSetProperty(session,
                                                  key: key,
                                                  value: value)
                if status == kVTPropertyNotSupportedErr {
                    if fatal { throw VTRemotedError.ioError(code: Int32(status), message: "set \(name) failed") }
                    logger.info("WARN \(name) not supported")
                    return
                }
                if status != noErr {
                    if fatal { throw VTRemotedError.ioError(code: Int32(status), message: "set \(name) failed") }
                    logger.info("WARN set \(name) failed \(status)")
                }
            }

            if (config.options.flags & VideoToolboxConstants.AV_CODEC_FLAG_QSCALE) != 0
                || config.options.globalQuality > 0 {
                if (config.options.flags & VideoToolboxConstants.AV_CODEC_FLAG_QSCALE) != 0, !isAppleSilicon() {
                    throw VTRemotedError.unsupported("qscale")
                }
                let factor: Float = (config.options.flags & VideoToolboxConstants.AV_CODEC_FLAG_QSCALE) != 0 ?
                    (VideoToolboxConstants.FF_QP2LAMBDA * 100.0) : 100.0
                var quality = Float(config.options.globalQuality) / factor
                if quality > 1.0 { quality = 1.0 }
                let qualityNum = CFNumberCreate(kCFAllocatorDefault, .float32Type, &quality)
                try setProp(kVTCompressionPropertyKey_Quality, qualityNum!, "quality", fatal: true)
            } else if config.options.bitrate > 0 {
                var br32 = Int32(clamping: config.options.bitrate)
                let bitrate = CFNumberCreate(kCFAllocatorDefault,
                                             .sInt32Type,
                                             &br32)
                if config.options.constantBitRate {
                    let status = VTSessionSetProperty(session, key: vtKeyConstantBitRate, value: bitrate)
                    if status == kVTPropertyNotSupportedErr {
                        throw VTRemotedError.ioError(code: Int32(status), message: "constant_bit_rate not supported")
                    } else if status != noErr {
                        throw VTRemotedError.ioError(code: Int32(status), message: "set ConstantBitRate failed")
                    }
                } else {
                    let status = VTSessionSetProperty(session,
                                                      key: kVTCompressionPropertyKey_AverageBitRate,
                                                      value: bitrate)
                    if status != noErr {
                        throw VTRemotedError.ioError(code: Int32(status), message: "set AverageBitRate failed")
                    }
                }
            }

            if config.options.prioritizeSpeed >= 0 {
                let prioritized = config.options.prioritizeSpeed != 0 ? kCFBooleanTrue : kCFBooleanFalse
                try setProp(vtKeyPrioritizeSpeed, prioritized!, "prio_speed")
            }

            if config.codec == .h264 || config.codec == .hevc, config.options.maxRate > 0 {
                let bytesPerSecond = Int64(config.options.maxRate >> 3)
                let oneSecond: Int64 = 1
                let arr = [NSNumber(value: bytesPerSecond), NSNumber(value: oneSecond)] as CFArray
                let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: arr)
                if status != noErr, config.codec != .hevc {
                    throw VTRemotedError.ioError(code: Int32(status), message: "set DataRateLimits failed")
                }
            }

            if config.codec == .hevc, config.options.alphaQuality > 0.0 {
                var alphaVal = config.options.alphaQuality
                let num = CFNumberCreate(kCFAllocatorDefault, .doubleType, &alphaVal)
                _ = VTSessionSetProperty(session, key: vtKeyTargetQualityForAlpha, value: num)
            }

            if let prof = profileLevel {
                try setProp(kVTCompressionPropertyKey_ProfileLevel, prof, "profile_level")
            }

            if config.options.gop > 0 {
                var gopVal = Int32(clamping: config.options.gop)
                let gopNum = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &gopVal)
                try setProp(kVTCompressionPropertyKey_MaxKeyFrameInterval, gopNum!, "gop", fatal: true)
            }

            if config.options.framesBefore {
                try setProp(kVTCompressionPropertyKey_MoreFramesBeforeStart, kCFBooleanTrue, "frames_before")
            }
            if config.options.framesAfter {
                try setProp(kVTCompressionPropertyKey_MoreFramesAfterEnd, kCFBooleanTrue, "frames_after")
            }

            if config.options.sarNum > 0, config.options.sarDen > 0 {
                let par = NSMutableDictionary()
                par[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing] = NSNumber(value: config.options.sarNum)
                par[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing] = NSNumber(value: config.options.sarDen)
                try setProp(kVTCompressionPropertyKey_PixelAspectRatio, par, "sar", fatal: true)
            }

            if let trc = mapTransferFunction(config.options.colorTRC) {
                _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: trc)
            }
            if let mat = mapColorMatrix(config.options.colorSpace) {
                _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: mat)
            }
            if let prim = mapColorPrimaries(config.options.colorPrimaries) {
                _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: prim)
            }
            if let gamma = gammaLevel(config.options.colorTRC) {
                var gammaVal = gamma
                let num = CFNumberCreate(kCFAllocatorDefault, .float32Type, &gammaVal)
                _ = VTSessionSetProperty(session, key: kCVImageBufferGammaLevelKey, value: num)
            }

            if !hasBFrames {
                try setProp(kVTCompressionPropertyKey_AllowFrameReordering,
                            kCFBooleanFalse,
                            "allow_reorder",
                            fatal: true)
            }

            if config.codec == .h264, entropy != 0 {
                let ent = entropy == 2 ? vtH264EntropyCABAC : vtH264EntropyCAVLC
                try setProp(vtKeyH264EntropyMode, ent, "entropy")
            }

            if config.options.realtime >= 0 {
                let isRealtime = config.options.realtime != 0 ? kCFBooleanTrue : kCFBooleanFalse
                try setProp(kVTCompressionPropertyKey_RealTime, isRealtime!, "realtime")
            }

            if (config.options.flags & VideoToolboxConstants.AV_CODEC_FLAG_CLOSED_GOP) != 0 {
                try setProp(vtKeyAllowOpenGOP, kCFBooleanFalse, "closed_gop")
            }

            if config.options.qmin >= 0 {
                var val = Int32(clamping: config.options.qmin)
                let num = CFNumberCreate(kCFAllocatorDefault, .intType, &val)
                try setProp(vtKeyMinAllowedFrameQP, num!, "qmin", fatal: true)
            }
            if config.options.qmax >= 0 {
                var val = Int32(clamping: config.options.qmax)
                let num = CFNumberCreate(kCFAllocatorDefault, .intType, &val)
                try setProp(vtKeyMaxAllowedFrameQP, num!, "qmax", fatal: true)
            }

            if config.options.maxSliceBytes >= 0, config.codec == .h264 {
                var val = Int32(clamping: config.options.maxSliceBytes)
                let num = CFNumberCreate(kCFAllocatorDefault, .intType, &val)
                try setProp(vtKeyMaxH264SliceBytes, num!, "max_slice_bytes", fatal: true)
            }

            if config.options.powerEfficient >= 0 {
                let powerEfficient = config.options.powerEfficient != 0 ? kCFBooleanTrue : kCFBooleanFalse
                try setProp(vtKeyMaximizePowerEfficiency, powerEfficient!, "power_efficient")
            }

            if config.options.maxReferenceFrames > 0 {
                var val = Int32(clamping: config.options.maxReferenceFrames)
                let num = CFNumberCreate(kCFAllocatorDefault, .intType, &val)
                try setProp(vtKeyReferenceBufferCount, num!, "max_ref_frames", fatal: true)
            }

            if config.options.spatialAQ >= 0 {
                var val: Int32 = config.options.spatialAQ != 0 ?
                    VideoToolboxConstants.kVTQPModulationLevel_Default :
                    VideoToolboxConstants.kVTQPModulationLevel_Disable
                let num = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &val)
                try setProp(vtKeySpatialAdaptiveQP, num!, "spatial_aq")
            }

            func copyProp(_ key: CFString) -> (OSStatus, CFTypeRef?) {
                var value: CFTypeRef?
                let status = withUnsafeMutablePointer(to: &value) { ptr in
                    VTSessionCopyProperty(session,
                                          key: key,
                                          allocator: kCFAllocatorDefault,
                                          valueOut: UnsafeMutableRawPointer(ptr))
                }
                return (status, value)
            }

            let (encStatus, encValue) = copyProp(vtKeyEncoderID)
            if encStatus == noErr, let encoderString = encValue as? String {
                logger.debug("DBG EncoderID \(encoderString)")
            }

            let preparation = VTCompressionSessionPrepareToEncodeFrames(session)
            guard preparation == noErr else {
                throw VTRemotedError.ioError(code: Int32(preparation), message: "PrepareToEncodeFrames failed")
            }

            if logger.level.rawValue >= LogLevel.debug.rawValue {
                var supported: CFDictionary?
                let supStatus = VTSessionCopySupportedPropertyDictionary(
                    session,
                    supportedPropertyDictionaryOut: &supported
                )
                if supStatus != noErr {
                    logger.debug("DBG VT supported properties unavailable status=\(supStatus)")
                }
                let supportedDict = supported as NSDictionary?

                func describe(_ value: CFTypeRef?) -> String {
                    guard let value else { return "nil" }
                    return CFCopyDescription(value) as String
                }

                func logProp(_ name: String, _ key: CFString) {
                    let supportedStr = (supportedDict?[key] != nil) ? "supported" : "unknown"
                    let (status, val) = copyProp(key)
                    if status == noErr {
                        logger.debug("DBG VT prop \(name) (\(supportedStr)) = \(describe(val))")
                    } else if status == kVTPropertyNotSupportedErr {
                        logger.debug("DBG VT prop \(name) (\(supportedStr)) = not supported")
                    } else {
                        logger.debug("DBG VT prop \(name) (\(supportedStr)) read failed \(status)")
                    }
                }

                logger.debug("DBG VT property dump post-PrepareToEncodeFrames")
                logProp("AverageBitRate", kVTCompressionPropertyKey_AverageBitRate)
                logProp("DataRateLimits", kVTCompressionPropertyKey_DataRateLimits)
                logProp("ConstantBitRate", vtKeyConstantBitRate)
                logProp("Quality", kVTCompressionPropertyKey_Quality)
                logProp("MaxKeyFrameInterval", kVTCompressionPropertyKey_MaxKeyFrameInterval)
                logProp("AllowFrameReordering", kVTCompressionPropertyKey_AllowFrameReordering)
                logProp("ProfileLevel", kVTCompressionPropertyKey_ProfileLevel)
                logProp("RealTime", kVTCompressionPropertyKey_RealTime)
                logProp("MinAllowedFrameQP", vtKeyMinAllowedFrameQP)
                logProp("MaxAllowedFrameQP", vtKeyMaxAllowedFrameQP)
                logProp("MaxH264SliceBytes", vtKeyMaxH264SliceBytes)
                logProp("H264EntropyMode", vtKeyH264EntropyMode)
                logProp("AllowOpenGOP", vtKeyAllowOpenGOP)
                logProp("MaximizePowerEfficiency", vtKeyMaximizePowerEfficiency)
                logProp("SpatialAdaptiveQP", vtKeySpatialAdaptiveQP)
                logProp("ReferenceBufferCount", vtKeyReferenceBufferCount)
            }
        }

        private func handleEncodedSampleBuffer(_ sbuf: CMSampleBuffer, context: FrameContext?) {
            guard let config else { return }
            guard let block = CMSampleBufferGetDataBuffer(sbuf) else { return }

            // Capture extradata once.
            if encoderExtradata == nil, let fmt = CMSampleBufferGetFormatDescription(sbuf) {
                let atom = (config.codec == .hevc) ? "hvcC" : "avcC"
                if let data = sampleDescriptionAtom(fmt, atom: atom) {
                    encoderExtradata = AnnexB.stripAtomHeaderIfPresent(data, fourCC: atom)
                    if config.codec == .h264, data.count > 4 {
                        nalLengthField = Int((data[4] & 0x3) + 1)
                    } else if config.codec == .hevc, let extra = encoderExtradata, extra.count > 21 {
                        nalLengthField = Int((extra[21] & 0x3) + 1)
                    }
                }
            }

            // Warmup discard.
            if warmupPending {
                warmupPending = false
                forceKeyframeNext = true
                warmupSemaphore.signal()
                return
            }

            let annex = convertToAnnexB(block: block, nalLengthField: nalLengthField)

            let pts = sbuf.presentationTimeStamp
            let ptsTicks = config.timebase.ticks(from: RationalTime(value: pts.value, timescale: pts.timescale))

            let rawDts = CMSampleBufferGetDecodeTimeStamp(sbuf)
            let dtsTime: CMTime = (rawDts.isValid && rawDts.isNumeric) ? rawDts : pts
            let dtsTicks = config.timebase.ticks(from: RationalTime(value: dtsTime.value, timescale: dtsTime.timescale))
            let dur = sbuf.duration.isNumeric ? sbuf.duration : .invalid
            let durTicks = dur.isNumeric ?
                config.timebase.ticks(from: RationalTime(value: dur.value, timescale: dur.timescale)) : 0

            let attachments = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false)
            let isKey = (attachments as? [[NSObject: Any]])?.first?[kCMSampleAttachmentKey_NotSync as NSObject] == nil

            var writer = ByteWriter()
            writer.writeBE(UInt64(bitPattern: ptsTicks))
            writer.writeBE(UInt64(bitPattern: dtsTicks))
            writer.writeBE(UInt64(bitPattern: durTicks))
            writer.writeBE(UInt32(isKey ? 1 : 0))
            writer.writeBE(UInt32(annex.count))
            writer.write(annex)

            do {
                try send(.packet, writer.data)
            } catch {
                logger.error("send packet failed: \(error)")
            }
        }

        private func convertToAnnexB(block: CMBlockBuffer, nalLengthField: Int) -> Data {
            let totalLen = CMBlockBufferGetDataLength(block)
            var data = Data(count: totalLen)
            data.withUnsafeMutableBytes { ptr in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: totalLen, destination: ptr.baseAddress!)
            }

            // 1. Calculate required size for Annex-B
            var index = 0
            var annexSize = 0
            data.withUnsafeBytes { inPtr in
                let inBase = inPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                while index + nalLengthField <= totalLen {
                    var len: UInt32 = 0
                    for idx in 0 ..< nalLengthField {
                        len = (len << 8) | UInt32(inBase[index + idx])
                    }
                    guard index + nalLengthField + Int(len) <= totalLen else { break }
                    annexSize += 4 + Int(len)
                    index += nalLengthField + Int(len)
                }
            }

            // 2. Build Annex-B buffer
            var annex = Data(count: annexSize)

            index = 0
            var outIdx = 0
            annex.withUnsafeMutableBytes { outPtr in
                let outBase = outPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                data.withUnsafeBytes { inPtr in
                    let inBase = inPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)

                    while index + nalLengthField <= totalLen {
                        var len: UInt32 = 0
                        for idx in 0 ..< nalLengthField {
                            len = (len << 8) | UInt32(inBase[index + idx])
                        }
                        guard index + nalLengthField + Int(len) <= totalLen else { break }

                        // Write start code
                        outBase[outIdx] = 0
                        outBase[outIdx + 1] = 0
                        outBase[outIdx + 2] = 0
                        outBase[outIdx + 3] = 1
                        outIdx += 4

                        // Copy NAL unit
                        index += nalLengthField
                        memcpy(outBase.advanced(by: outIdx), inBase.advanced(by: index), Int(len))
                        outIdx += Int(len)
                        index += Int(len)
                    }
                }
            }
            return annex
        }

        private func warmup() throws {
            guard let session = compressionSession, let config else { return }
            warmupPending = true
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                             config.width,
                                             config.height,
                                             cvPixelFormat,
                                             nil,
                                             &pixelBuffer)
            guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                warmupPending = false
                return
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
                memset(base, 0, CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let presentationTime = CMTime(value: 0, timescale: Int32(max(1, config.timebase.den)))
            VTCompressionSessionEncodeFrame(session,
                                            imageBuffer: buffer,
                                            presentationTimeStamp: presentationTime,
                                            duration: .invalid,
                                            frameProperties: nil,
                                            sourceFrameRefcon: nil,
                                            infoFlagsOut: nil)
            _ = warmupSemaphore.wait(timeout: .now() + 1.0)
        }

        // MARK: - Decoder

        private func setupDecoder(_ config: SessionConfiguration) throws {
            let codecType: CMVideoCodecType = switch config.codec {
            case .h264: kCMVideoCodecType_H264
            case .hevc: kCMVideoCodecType_HEVC
            }

            cvPixelFormat = try pickCVPixelFormat(pixelFormat: config.pixelFormat)

            guard let rawExtra = config.configExtradata, !rawExtra.isEmpty else {
                throw VTRemotedError.protocolViolation("decoder requires extradata")
            }

            let atom = (config.codec == .hevc) ? "hvcC" : "avcC"
            let extra = AnnexB.stripAtomHeaderIfPresent(rawExtra, fourCC: atom)

            // Try to interpret as avcC/hvcC.
            if config.codec == .h264, extra.count > 6, extra[0] == 1 {
                nalLengthField = Int((extra[4] & 0x03) + 1)
                formatDescription = try makeFormatDescriptionFromAtom(codecType: codecType,
                                                                      width: config.width,
                                                                      height: config.height,
                                                                      atomName: atom,
                                                                      atomData: extra)
            } else if config.codec == .hevc, extra.count > 21, extra[0] == 1 {
                nalLengthField = Int((extra[21] & 0x03) + 1)
                formatDescription = try makeFormatDescriptionFromAtom(codecType: codecType,
                                                                      width: config.width,
                                                                      height: config.height,
                                                                      atomName: atom,
                                                                      atomData: extra)
            } else {
                // Fall back to parsing Annex-B parameter sets.
                nalLengthField = 4
                formatDescription = try formatDescriptionFromAnnexB(extra,
                                                                    codec: config.codec,
                                                                    codecType: codecType,
                                                                    nalLength: 4)
            }

            guard let fmt = formatDescription else {
                throw VTRemotedError.videoToolboxUnavailable
            }

            var callback = VTDecompressionOutputCallbackRecord(
                decompressionOutputCallback: { refCon, _, status, _, imageBuffer, pts, duration in
                    guard status == noErr, let img = imageBuffer else { return }
                    let unmanaged = Unmanaged<VideoToolboxCodecSession>.fromOpaque(refCon!)
                    unmanaged.takeUnretainedValue().handleDecodedFrame(pixelBuffer: img, pts: pts, duration: duration)
                },
                decompressionOutputRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            )

            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: cvPixelFormat
            ]

            var decompressionSessionPtr: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: fmt,
                decoderSpecification: nil,
                imageBufferAttributes: attrs as CFDictionary,
                outputCallback: &callback,
                decompressionSessionOut: &decompressionSessionPtr
            )
            guard status == noErr, let session = decompressionSessionPtr else {
                throw VTRemotedError.ioError(code: Int32(status), message: "VTDecompressionSessionCreate failed")
            }
            decompressionSession = session
        }

        private func handleDecodedFrame(pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
            guard let config else { return }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

            guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return }

            let ptsTicks = config.timebase.ticks(from: RationalTime(value: pts.value, timescale: pts.timescale))
            let durTicks: Int64 = if duration.isNumeric {
                config.timebase.ticks(from: RationalTime(value: duration.value, timescale: duration.timescale))
            } else {
                0
            }

            var writer = ByteWriter()
            writer.writeBE(UInt64(bitPattern: ptsTicks))
            writer.writeBE(UInt64(bitPattern: durTicks))
            writer.writeBE(UInt32(0))
            writer.write(UInt8(2))

            for plane in 0 ..< 2 {
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
                let len = stride * height

                writer.writeBE(UInt32(stride))
                writer.writeBE(UInt32(height))

                let raw = if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) {
                    Data(bytes: base, count: len)
                } else {
                    Data(count: len)
                }

                if config.options.wireCompression == 1 {
                    guard let compressed = LZ4Codec.compress(raw) else {
                        logger.error("lz4 compress failed")
                        return
                    }
                    writer.writeBE(UInt32(compressed.count))
                    writer.write(compressed)
                } else if config.options.wireCompression == 2 {
                    guard let compressed = ZstdCodec.compress(raw) else {
                        logger.error("zstd compress failed")
                        return
                    }
                    writer.writeBE(UInt32(compressed.count))
                    writer.write(compressed)
                } else {
                    writer.writeBE(UInt32(raw.count))
                    writer.write(raw)
                }
            }

            do {
                try send(.frame, writer.data)
            } catch {
                logger.error("send frame failed: \(error)")
            }
        }

        // MARK: - Helpers

        private func pickCVPixelFormat(pixelFormat: UInt8) throws -> OSType {
            switch pixelFormat {
            case 1:
                return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            case 2:
                return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            default:
                throw VTRemotedError.unsupported("pix_fmt=\(pixelFormat)")
            }
        }

        private func isAppleSilicon() -> Bool {
            #if arch(arm64)
                return true
            #else
                return false
            #endif
        }

        private func bitDepthForPixFmt(_ pixelFormat: UInt8) -> Int {
            switch pixelFormat {
            case 2: 10
            case 1: 8
            default: 0
            }
        }

        private func mapColorPrimaries(_ primaries: Int) -> CFString? {
            switch primaries {
            case VideoToolboxConstants.AVCOL_PRI_BT2020:
                kCVImageBufferColorPrimaries_ITU_R_2020
            case VideoToolboxConstants.AVCOL_PRI_BT709:
                kCVImageBufferColorPrimaries_ITU_R_709_2
            case VideoToolboxConstants.AVCOL_PRI_SMPTE170M:
                kCVImageBufferColorPrimaries_SMPTE_C
            case VideoToolboxConstants.AVCOL_PRI_BT470BG:
                kCVImageBufferColorPrimaries_EBU_3213
            default:
                nil
            }
        }

        private func mapTransferFunction(_ trc: Int) -> CFString? {
            switch trc {
            case VideoToolboxConstants.AVCOL_TRC_SMPTE2084:
                kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            case VideoToolboxConstants.AVCOL_TRC_BT2020_10, VideoToolboxConstants.AVCOL_TRC_BT2020_12:
                kCVImageBufferTransferFunction_ITU_R_2020
            case VideoToolboxConstants.AVCOL_TRC_BT709:
                kCVImageBufferTransferFunction_ITU_R_709_2
            case VideoToolboxConstants.AVCOL_TRC_SMPTE240M:
                kCVImageBufferTransferFunction_SMPTE_240M_1995
            case VideoToolboxConstants.AVCOL_TRC_SMPTE428:
                kCVImageBufferTransferFunction_SMPTE_ST_428_1
            case VideoToolboxConstants.AVCOL_TRC_ARIB_STD_B67:
                kCVImageBufferTransferFunction_ITU_R_2100_HLG
            case VideoToolboxConstants.AVCOL_TRC_GAMMA22, VideoToolboxConstants.AVCOL_TRC_GAMMA28:
                kCVImageBufferTransferFunction_UseGamma
            default:
                nil
            }
        }

        private func mapColorMatrix(_ space: Int) -> CFString? {
            switch space {
            case VideoToolboxConstants.AVCOL_SPC_BT2020_CL, VideoToolboxConstants.AVCOL_SPC_BT2020_NCL:
                kCVImageBufferYCbCrMatrix_ITU_R_2020
            case VideoToolboxConstants.AVCOL_SPC_BT470BG, VideoToolboxConstants.AVCOL_SPC_SMPTE170M:
                kCVImageBufferYCbCrMatrix_ITU_R_601_4
            case VideoToolboxConstants.AVCOL_SPC_BT709:
                kCVImageBufferYCbCrMatrix_ITU_R_709_2
            case VideoToolboxConstants.AVCOL_SPC_SMPTE240M:
                kCVImageBufferYCbCrMatrix_SMPTE_240M_1995
            default:
                nil
            }
        }

        private func gammaLevel(_ trc: Int) -> Float32? {
            switch trc {
            case VideoToolboxConstants.AVCOL_TRC_GAMMA22:
                2.2
            case VideoToolboxConstants.AVCOL_TRC_GAMMA28:
                2.8
            default:
                nil
            }
        }

        private func profileLevelString(codec: VideoCodec,
                                        profile: Int,
                                        level: Int,
                                        pixelFormat: UInt8,
                                        hasBFrames: Bool) throws -> CFString? {
            switch codec {
            case .h264:
                var hProfile = profile
                if hProfile == VideoToolboxConstants.AV_PROFILE_UNKNOWN, level != 0 {
                    hProfile = hasBFrames
                        ? VideoToolboxConstants.AV_PROFILE_H264_MAIN
                        : VideoToolboxConstants.AV_PROFILE_H264_BASELINE
                }

                switch hProfile {
                case VideoToolboxConstants.AV_PROFILE_UNKNOWN:
                    return nil
                case VideoToolboxConstants.AV_PROFILE_H264_BASELINE:
                    return h264BaselineLevel(level)
                case VideoToolboxConstants.AV_PROFILE_H264_CONSTRAINED_BASELINE:
                    if level != 0 {
                        logger.info("WARN Level is auto-selected when constrained-baseline profile is used")
                    }
                    return vtProfileH264ConstrainedBaselineAuto
                case VideoToolboxConstants.AV_PROFILE_H264_MAIN:
                    return h264MainLevel(level)
                case VideoToolboxConstants.AV_PROFILE_H264_CONSTRAINED_HIGH:
                    if level != 0 {
                        logger.info("WARN Level is auto-selected when constrained-high profile is used")
                    }
                    return vtProfileH264ConstrainedHighAuto
                case VideoToolboxConstants.AV_PROFILE_H264_HIGH:
                    return h264HighLevel(level)
                case VideoToolboxConstants.AV_PROFILE_H264_EXTENDED:
                    switch level {
                    case 0: return vtProfileH264ExtendedAuto
                    case 50: return vtProfileH264Extended50
                    default: break
                    }
                default:
                    break
                }
            case .hevc:
                return hevcProfileLevel(profile: profile, pixelFormat: pixelFormat)
            }

            throw VTRemotedError.unsupported("invalid profile/level")
        }

        private func h264BaselineLevel(_ level: Int) -> CFString? {
            switch level {
            case 0: vtProfileH264BaselineAuto
            case 13: vtProfileH264Baseline13
            case 30: vtProfileH264Baseline30
            case 31: vtProfileH264Baseline31
            case 32: vtProfileH264Baseline32
            case 40: vtProfileH264Baseline40
            case 41: vtProfileH264Baseline41
            case 42: vtProfileH264Baseline42
            case 50: vtProfileH264Baseline50
            case 51: vtProfileH264Baseline51
            case 52: vtProfileH264Baseline52
            default: nil
            }
        }

        private func h264MainLevel(_ level: Int) -> CFString? {
            switch level {
            case 0: vtProfileH264MainAuto
            case 30: vtProfileH264Main30
            case 31: vtProfileH264Main31
            case 32: vtProfileH264Main32
            case 40: vtProfileH264Main40
            case 41: vtProfileH264Main41
            case 42: vtProfileH264Main42
            case 50: vtProfileH264Main50
            case 51: vtProfileH264Main51
            case 52: vtProfileH264Main52
            default: nil
            }
        }

        private func h264HighLevel(_ level: Int) -> CFString? {
            switch level {
            case 0: vtProfileH264HighAuto
            case 30: vtProfileH264High30
            case 31: vtProfileH264High31
            case 32: vtProfileH264High32
            case 40: vtProfileH264High40
            case 41: vtProfileH264High41
            case 42: vtProfileH264High42
            case 50: vtProfileH264High50
            case 51: vtProfileH264High51
            case 52: vtProfileH264High52
            default: nil
            }
        }

        private func hevcProfileLevel(profile: Int, pixelFormat: UInt8) -> CFString? {
            let bitDepth = bitDepthForPixFmt(pixelFormat)
            switch profile {
            case VideoToolboxConstants.AV_PROFILE_UNKNOWN:
                if bitDepth == 10 { return vtProfileHEVCMain10Auto }
                return nil
            case VideoToolboxConstants.AV_PROFILE_HEVC_MAIN:
                if bitDepth > 0, bitDepth != 8 {
                    logger.info("WARN main profile with \(bitDepth)-bit input")
                }
                return vtProfileHEVCMainAuto
            case VideoToolboxConstants.AV_PROFILE_HEVC_MAIN_10:
                return vtProfileHEVCMain10Auto
            case VideoToolboxConstants.AV_PROFILE_HEVC_REXT:
                return vtProfileHEVCMain42210Auto
            default:
                return nil
            }
        }

        private func cmTime(fromTicks ticks: Int64, timebase: Timebase) -> CMTime {
            let num = max(1, timebase.num)
            let den = max(1, timebase.den)
            let (value, overflow) = ticks.multipliedReportingOverflow(by: Int64(num))
            let safe = overflow ? (ticks >= 0 ? Int64.max : Int64.min) : value
            return CMTime(value: CMTimeValue(safe), timescale: Int32(den))
        }

        private func sampleDescriptionAtom(_ fmt: CMFormatDescription, atom: String) -> Data? {
            let key = kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
            guard let ext = CMFormatDescriptionGetExtension(fmt, extensionKey: key) else {
                return nil
            }
            if let dict = ext as? [AnyHashable: Any] {
                if let data = dict[atom] as? Data { return data }
                if let data = dict[atom] as? NSData { return data as Data }
            }
            return nil
        }

        private func makeFormatDescriptionFromAtom(codecType: CMVideoCodecType,
                                                   width: Int,
                                                   height: Int,
                                                   atomName: String,
                                                   atomData: Data) throws -> CMFormatDescription {
            let atoms: [String: Data] = [atomName: atomData]
            let key = kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String
            let ext: [String: Any] = [key: atoms]
            var fmt: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: codecType,
                width: Int32(width),
                height: Int32(height),
                extensions: ext as CFDictionary,
                formatDescriptionOut: &fmt
            )
            guard status == noErr, let format = fmt else {
                throw VTRemotedError.ioError(code: Int32(status), message: "CMVideoFormatDescriptionCreate failed")
            }
            return format
        }

        private func formatDescriptionFromAnnexB(_ data: Data,
                                                 codec: VideoCodec,
                                                 codecType: CMVideoCodecType,
                                                 nalLength: Int) throws -> CMFormatDescription {
            let units = AnnexB.splitNALUnits(data)
            switch codec {
            case .h264:
                return try formatDescriptionH264(units: units, nalLength: nalLength)
            case .hevc:
                return try formatDescriptionHEVC(units: units, nalLength: nalLength)
            }
        }

        private func formatDescriptionH264(units: [Data], nalLength: Int) throws -> CMFormatDescription {
            var sps: Data?
            var pps: Data?
            for unit in units {
                guard let first = unit.first else { continue }
                let nalType = Int(first & 0x1F)
                if nalType == 7, sps == nil { sps = unit }
                if nalType == 8, pps == nil { pps = unit }
            }
            guard let spsData = sps, let ppsData = pps else {
                throw VTRemotedError.protocolViolation("missing SPS/PPS")
            }
            var fmt: CMFormatDescription?
            let spsBytes = [UInt8](spsData)
            let ppsBytes = [UInt8](ppsData)
            let status = spsBytes.withUnsafeBytes { spsPtr in
                ppsBytes.withUnsafeBytes { ppsPtr in
                    var ptrs: [UnsafePointer<UInt8>] = [
                        spsPtr.bindMemory(to: UInt8.self).baseAddress!,
                        ppsPtr.bindMemory(to: UInt8.self).baseAddress!
                    ]
                    var sizes: [Int] = [spsBytes.count, ppsBytes.count]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: &ptrs,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: Int32(nalLength),
                        formatDescriptionOut: &fmt
                    )
                }
            }
            guard status == noErr, let format = fmt else {
                throw VTRemotedError.ioError(code: Int32(status), message: "CreateFromH264ParameterSets failed")
            }
            return format
        }

        private func formatDescriptionHEVC(units: [Data], nalLength: Int) throws -> CMFormatDescription {
            var vps: Data?
            var sps: Data?
            var pps: Data?
            for unit in units {
                guard let first = unit.first else { continue }
                let nalType = Int((first >> 1) & 0x3F)
                if nalType == 32, vps == nil { vps = unit }
                if nalType == 33, sps == nil { sps = unit }
                if nalType == 34, pps == nil { pps = unit }
            }
            guard let vpsData = vps, let spsData = sps, let ppsData = pps else {
                throw VTRemotedError.protocolViolation("missing VPS/SPS/PPS")
            }
            var fmt: CMFormatDescription?
            let vpsBytes = [UInt8](vpsData)
            let spsBytes = [UInt8](spsData)
            let ppsBytes = [UInt8](ppsData)
            let status = vpsBytes.withUnsafeBytes { vpsPtr in
                spsBytes.withUnsafeBytes { spsPtr in
                    ppsBytes.withUnsafeBytes { ppsPtr in
                        var ptrs: [UnsafePointer<UInt8>] = [
                            vpsPtr.bindMemory(to: UInt8.self).baseAddress!,
                            spsPtr.bindMemory(to: UInt8.self).baseAddress!,
                            ppsPtr.bindMemory(to: UInt8.self).baseAddress!
                        ]
                        var sizes: [Int] = [vpsBytes.count, spsBytes.count, ppsBytes.count]
                        return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 3,
                            parameterSetPointers: &ptrs,
                            parameterSetSizes: &sizes,
                            nalUnitHeaderLength: Int32(nalLength),
                            extensions: nil,
                            formatDescriptionOut: &fmt
                        )
                    }
                }
            }
            guard status == noErr, let format = fmt else {
                throw VTRemotedError.ioError(code: Int32(status), message: "CreateFromHEVCParameterSets failed")
            }
            return format
        }
    }
#endif
