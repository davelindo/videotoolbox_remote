#if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo)
import CoreFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// FFmpeg constants mirrored for parity with videotoolboxenc.c.
private let AV_PROFILE_UNKNOWN = -99
private let AV_PROFILE_H264_CONSTRAINED: Int = 1 << 9
private let AV_PROFILE_H264_BASELINE = 66
private let AV_PROFILE_H264_CONSTRAINED_BASELINE = AV_PROFILE_H264_BASELINE | AV_PROFILE_H264_CONSTRAINED
private let AV_PROFILE_H264_MAIN = 77
private let AV_PROFILE_H264_EXTENDED = 88
private let AV_PROFILE_H264_HIGH = 100
private let AV_PROFILE_H264_CONSTRAINED_HIGH = AV_PROFILE_H264_HIGH | AV_PROFILE_H264_CONSTRAINED

private let AV_PROFILE_HEVC_MAIN = 1
private let AV_PROFILE_HEVC_MAIN_10 = 2
private let AV_PROFILE_HEVC_REXT = 4

private let AV_CODEC_FLAG_QSCALE: Int64 = 1 << 1
private let AV_CODEC_FLAG_LOW_DELAY: Int64 = 1 << 19
private let AV_CODEC_FLAG_CLOSED_GOP: Int64 = 1 << 31

private let AVCOL_RANGE_UNSPECIFIED = 0
private let AVCOL_RANGE_MPEG = 1
private let AVCOL_RANGE_JPEG = 2

private let AVCOL_SPC_BT709 = 1
private let AVCOL_SPC_UNSPECIFIED = 2
private let AVCOL_SPC_BT470BG = 5
private let AVCOL_SPC_SMPTE170M = 6
private let AVCOL_SPC_SMPTE240M = 7
private let AVCOL_SPC_BT2020_NCL = 9
private let AVCOL_SPC_BT2020_CL = 10

private let AVCOL_PRI_BT709 = 1
private let AVCOL_PRI_UNSPECIFIED = 2
private let AVCOL_PRI_BT470BG = 5
private let AVCOL_PRI_SMPTE170M = 6
private let AVCOL_PRI_BT2020 = 9

private let AVCOL_TRC_BT709 = 1
private let AVCOL_TRC_UNSPECIFIED = 2
private let AVCOL_TRC_GAMMA22 = 4
private let AVCOL_TRC_GAMMA28 = 5
private let AVCOL_TRC_SMPTE240M = 7
private let AVCOL_TRC_BT2020_10 = 14
private let AVCOL_TRC_BT2020_12 = 15
private let AVCOL_TRC_SMPTE2084 = 16
private let AVCOL_TRC_SMPTE428 = 17
private let AVCOL_TRC_ARIB_STD_B67 = 18

private let FF_QP2LAMBDA: Float = 118.0
private let kVTQPModulationLevel_Default: Int32 = -1
private let kVTQPModulationLevel_Disable: Int32 = 0
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

    init(sender: @escaping MessageSender) {
        self.send = sender
    }

    func configure(_ configuration: SessionConfiguration) throws -> Data {
        self.config = configuration
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
        guard let cs = compressionSession else { throw VTRemotedError.videoToolboxUnavailable }

        var r = ByteReader(payload)
        let ptsTicks = Int64(bitPattern: try r.readBEUInt64())
        _ = try r.readBEUInt64() // duration ticks (ignored)
        let flags = try r.readBEUInt32()
        let planes = try r.readUInt8()
        guard planes == 2 else { throw VTRemotedError.protocolViolation("expected 2 planes") }

        let stride0 = Int(try r.readBEUInt32())
        let height0 = Int(try r.readBEUInt32())
        let len0 = Int(try r.readBEUInt32())
        let yRaw = try r.readBytes(count: len0)

        let stride1 = Int(try r.readBEUInt32())
        let height1 = Int(try r.readBEUInt32())
        let len1 = Int(try r.readBEUInt32())
        let uvRaw = try r.readBytes(count: len1)

        let expectedY = max(0, stride0 * height0)
        let expectedUV = max(0, stride1 * height1)

        let yPlane: Data
        let uvPlane: Data
        if config.options.wireCompression == 1 {
            guard let yd = LZ4Codec.decompress(yRaw, expectedSize: expectedY),
                  let uvd = LZ4Codec.decompress(uvRaw, expectedSize: expectedUV) else {
                throw VTRemotedError.protocolViolation("LZ4 decompress failed")
            }
            yPlane = yd
            uvPlane = uvd
        } else {
            yPlane = yRaw
            uvPlane = uvRaw
        }

        guard let pool = VTCompressionSessionGetPixelBufferPool(cs) else {
            throw VTRemotedError.videoToolboxUnavailable
        }
        var pixelBuffer: CVPixelBuffer?
        let st = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard st == kCVReturnSuccess, let pb = pixelBuffer else {
            throw VTRemotedError.ioError(code: Int32(st), message: "CVPixelBufferPoolCreatePixelBuffer failed")
        }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        let bytesPerSample = (config.pixelFormat == 2) ? 2 : 1
        let rowBytesY = config.width * bytesPerSample
        let rowBytesUV = config.width * bytesPerSample

        yPlane.withUnsafeBytes { yPtr in
            uvPlane.withUnsafeBytes { uvPtr in
                let ySrc = yPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let uvSrc = uvPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)

                if let yDst = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
                    let dstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                    let rowBytes = min(rowBytesY, min(stride0, dstStride))
                    for y in 0..<height0 {
                        memcpy(yDst.advanced(by: y * dstStride), ySrc.advanced(by: y * stride0), rowBytes)
                    }
                }
                if let uvDst = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
                    let dstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
                    let rowBytes = min(rowBytesUV, min(stride1, dstStride))
                    for y in 0..<height1 {
                        memcpy(uvDst.advanced(by: y * dstStride), uvSrc.advanced(by: y * stride1), rowBytes)
                    }
                }
            }
        }

        let pts = cmTime(fromTicks: ptsTicks, timebase: config.timebase)
        let forceKey = (flags & 1) != 0 || forceKeyframeNext
        let props: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKeyframeNext = false

        VTCompressionSessionEncodeFrame(
            cs,
            imageBuffer: pb,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: props,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    func handlePacketMessage(_ payload: Data) throws {
        guard let config else { throw VTRemotedError.protocolViolation("PACKET before CONFIGURE") }
        guard config.mode == .decode else { return }
        guard let ds = decompressionSession, let fmt = formatDescription else { throw VTRemotedError.videoToolboxUnavailable }

        var r = ByteReader(payload)
        let ptsTicks = Int64(bitPattern: try r.readBEUInt64())
        let dtsTicks = Int64(bitPattern: try r.readBEUInt64())
        let durTicks = Int64(bitPattern: try r.readBEUInt64())
        _ = try r.readBEUInt32() // isKey
        let dataLen = Int(try r.readBEUInt32())
        let annexB = try r.readBytes(count: dataLen)

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
        guard status == noErr, let block else { return }

        lengthPrefixed.withUnsafeBytes { ptr in
            _ = CMBlockBufferReplaceDataBytes(with: ptr.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: dataCount)
        }

        var timing = CMSampleTimingInfo(
            duration: cmTime(fromTicks: durTicks, timebase: config.timebase),
            presentationTimeStamp: cmTime(fromTicks: ptsTicks, timebase: config.timebase),
            decodeTimeStamp: cmTime(fromTicks: dtsTicks, timebase: config.timebase)
        )

        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: fmt,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [dataCount],
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { return }

        status = VTDecompressionSessionDecodeFrame(ds, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
        if status == noErr {
            _ = VTDecompressionSessionWaitForAsynchronousFrames(ds)
        }
    }

    func flush() throws {
        if let cs = compressionSession {
            VTCompressionSessionCompleteFrames(cs, untilPresentationTimeStamp: .invalid)
        }
        if let ds = decompressionSession {
            _ = VTDecompressionSessionFinishDelayedFrames(ds)
            _ = VTDecompressionSessionWaitForAsynchronousFrames(ds)
        }
    }

    func shutdown() {
        if let cs = compressionSession {
            VTCompressionSessionInvalidate(cs)
        }
        if let ds = decompressionSession {
            VTDecompressionSessionInvalidate(ds)
        }
    }

    // MARK: - Encoder

    private func setupEncoder(_ config: SessionConfiguration) throws {
        let codecType: CMVideoCodecType
        switch config.codec {
        case .h264: codecType = kCMVideoCodecType_H264
        case .hevc: codecType = kCMVideoCodecType_HEVC
        }

        if config.codec == .h264, config.pixelFormat != 1 {
            throw VTRemotedError.unsupported("h264 requires nv12")
        }

        cvPixelFormat = try pickCVPixelFormat(pixelFormat: config.pixelFormat)

        var hasBFrames = config.options.maxBFrames > 0
        var entropy = config.options.entropy
        let profile = config.options.profile

        if config.codec == .h264 {
            if hasBFrames && (profile & 0xFF) == AV_PROFILE_H264_BASELINE {
                logger.info("WARN baseline profile cannot use B-frames; disabling")
                hasBFrames = false
            }
            if entropy == 2 && (profile & 0xFF) == AV_PROFILE_H264_BASELINE {
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
        if (config.options.flags & AV_CODEC_FLAG_LOW_DELAY) != 0,
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
            outputCallback: { refCon, _, status, _, sampleBuffer in
                guard status == noErr, let sbuf = sampleBuffer, CMSampleBufferDataIsReady(sbuf) else { return }
                let unmanaged = Unmanaged<VideoToolboxCodecSession>.fromOpaque(refCon!)
                unmanaged.takeUnretainedValue().handleEncodedSampleBuffer(sbuf)
            },
            refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            compressionSessionOut: &compressionSession
        )
        guard status == noErr, let cs = compressionSession else {
            throw VTRemotedError.ioError(code: Int32(status), message: "VTCompressionSessionCreate failed")
        }

        func setProp(_ key: CFString, _ value: CFTypeRef, _ name: String, fatal: Bool = false) throws {
            let st = VTSessionSetProperty(cs, key: key, value: value)
            if st == kVTPropertyNotSupportedErr {
                if fatal { throw VTRemotedError.ioError(code: Int32(st), message: "set \(name) failed") }
                logger.info("WARN \(name) not supported")
                return
            }
            if st != noErr {
                if fatal { throw VTRemotedError.ioError(code: Int32(st), message: "set \(name) failed") }
                logger.info("WARN set \(name) failed \(st)")
            }
        }

        if (config.options.flags & AV_CODEC_FLAG_QSCALE) != 0 || config.options.globalQuality > 0 {
            if (config.options.flags & AV_CODEC_FLAG_QSCALE) != 0 && !isAppleSilicon() {
                throw VTRemotedError.unsupported("qscale")
            }
            let factor: Float = (config.options.flags & AV_CODEC_FLAG_QSCALE) != 0 ? (FF_QP2LAMBDA * 100.0) : 100.0
            var quality = Float(config.options.globalQuality) / factor
            if quality > 1.0 { quality = 1.0 }
            let q = CFNumberCreate(kCFAllocatorDefault, .float32Type, &quality)
            try setProp(kVTCompressionPropertyKey_Quality, q!, "quality", fatal: true)
        } else if config.options.bitrate > 0 {
            var br32 = Int32(clamping: config.options.bitrate)
            let br = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &br32)
            if config.options.constantBitRate {
                let st = VTSessionSetProperty(cs, key: vtKeyConstantBitRate, value: br)
                if st == kVTPropertyNotSupportedErr {
                    throw VTRemotedError.ioError(code: Int32(st), message: "constant_bit_rate not supported")
                } else if st != noErr {
                    throw VTRemotedError.ioError(code: Int32(st), message: "set ConstantBitRate failed")
                }
            } else {
                let st = VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_AverageBitRate, value: br)
                if st != noErr {
                    throw VTRemotedError.ioError(code: Int32(st), message: "set AverageBitRate failed")
                }
            }
        }

        if config.options.prioritizeSpeed >= 0 {
            try setProp(vtKeyPrioritizeSpeed, config.options.prioritizeSpeed != 0 ? kCFBooleanTrue : kCFBooleanFalse, "prio_speed")
        }

        if (config.codec == .h264 || config.codec == .hevc), config.options.maxRate > 0 {
            let bytesPerSecond = Int64(config.options.maxRate >> 3)
            let oneSecond: Int64 = 1
            let arr = [NSNumber(value: bytesPerSecond), NSNumber(value: oneSecond)] as CFArray
            let st = VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_DataRateLimits, value: arr)
            if st != noErr && config.codec != .hevc {
                throw VTRemotedError.ioError(code: Int32(st), message: "set DataRateLimits failed")
            }
        }

        if config.codec == .hevc && config.options.alphaQuality > 0.0 {
            var a = config.options.alphaQuality
            let num = CFNumberCreate(kCFAllocatorDefault, .doubleType, &a)
            _ = VTSessionSetProperty(cs, key: vtKeyTargetQualityForAlpha, value: num)
        }

        if let prof = profileLevel {
            try setProp(kVTCompressionPropertyKey_ProfileLevel, prof, "profile_level")
        }

        if config.options.gop > 0 {
            var g32 = Int32(clamping: config.options.gop)
            let g = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &g32)
            try setProp(kVTCompressionPropertyKey_MaxKeyFrameInterval, g!, "gop", fatal: true)
        }

        if config.options.framesBefore {
            try setProp(kVTCompressionPropertyKey_MoreFramesBeforeStart, kCFBooleanTrue, "frames_before")
        }
        if config.options.framesAfter {
            try setProp(kVTCompressionPropertyKey_MoreFramesAfterEnd, kCFBooleanTrue, "frames_after")
        }

        if config.options.sarNum > 0 && config.options.sarDen > 0 {
            let par = NSMutableDictionary()
            par[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing] = NSNumber(value: config.options.sarNum)
            par[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing] = NSNumber(value: config.options.sarDen)
            try setProp(kVTCompressionPropertyKey_PixelAspectRatio, par, "sar", fatal: true)
        }

        if let trc = mapTransferFunction(config.options.colorTRC) {
            _ = VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_TransferFunction, value: trc)
        }
        if let mat = mapColorMatrix(config.options.colorSpace) {
            _ = VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_YCbCrMatrix, value: mat)
        }
        if let prim = mapColorPrimaries(config.options.colorPrimaries) {
            _ = VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_ColorPrimaries, value: prim)
        }
        if let gamma = gammaLevel(config.options.colorTRC) {
            var g = gamma
            let num = CFNumberCreate(kCFAllocatorDefault, .float32Type, &g)
            _ = VTSessionSetProperty(cs, key: kCVImageBufferGammaLevelKey, value: num)
        }

        if !hasBFrames {
            try setProp(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse, "allow_reorder", fatal: true)
        }

        if config.codec == .h264 && entropy != 0 {
            let ent = entropy == 2 ? vtH264EntropyCABAC : vtH264EntropyCAVLC
            try setProp(vtKeyH264EntropyMode, ent, "entropy")
        }

        if config.options.realtime >= 0 {
            try setProp(kVTCompressionPropertyKey_RealTime, config.options.realtime != 0 ? kCFBooleanTrue : kCFBooleanFalse, "realtime")
        }

        if (config.options.flags & AV_CODEC_FLAG_CLOSED_GOP) != 0 {
            try setProp(vtKeyAllowOpenGOP, kCFBooleanFalse, "closed_gop")
        }

        if config.options.qmin >= 0 {
            var v = Int32(clamping: config.options.qmin)
            let num = CFNumberCreate(kCFAllocatorDefault, .intType, &v)
            try setProp(vtKeyMinAllowedFrameQP, num!, "qmin", fatal: true)
        }
        if config.options.qmax >= 0 {
            var v = Int32(clamping: config.options.qmax)
            let num = CFNumberCreate(kCFAllocatorDefault, .intType, &v)
            try setProp(vtKeyMaxAllowedFrameQP, num!, "qmax", fatal: true)
        }

        if config.options.maxSliceBytes >= 0 && config.codec == .h264 {
            var v = Int32(clamping: config.options.maxSliceBytes)
            let num = CFNumberCreate(kCFAllocatorDefault, .intType, &v)
            try setProp(vtKeyMaxH264SliceBytes, num!, "max_slice_bytes", fatal: true)
        }

        if config.options.powerEfficient >= 0 {
            try setProp(vtKeyMaximizePowerEfficiency, config.options.powerEfficient != 0 ? kCFBooleanTrue : kCFBooleanFalse, "power_efficient")
        }

        if config.options.maxReferenceFrames > 0 {
            var v = Int32(clamping: config.options.maxReferenceFrames)
            let num = CFNumberCreate(kCFAllocatorDefault, .intType, &v)
            try setProp(vtKeyReferenceBufferCount, num!, "max_ref_frames", fatal: true)
        }

        if config.options.spatialAQ >= 0 {
            var v: Int32 = config.options.spatialAQ != 0 ? kVTQPModulationLevel_Default : kVTQPModulationLevel_Disable
            let num = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &v)
            try setProp(vtKeySpatialAdaptiveQP, num!, "spatial_aq")
        }

        func copyProp(_ key: CFString) -> (OSStatus, CFTypeRef?) {
            var value: CFTypeRef?
            let status = withUnsafeMutablePointer(to: &value) { ptr in
                VTSessionCopyProperty(cs, key: key, allocator: kCFAllocatorDefault, valueOut: UnsafeMutableRawPointer(ptr))
            }
            return (status, value)
        }

        let (encStatus, encValue) = copyProp(vtKeyEncoderID)
        if encStatus == noErr, let s = encValue as? String {
            logger.debug("DBG EncoderID \(s)")
        }

        let prep = VTCompressionSessionPrepareToEncodeFrames(cs)
        guard prep == noErr else { throw VTRemotedError.ioError(code: Int32(prep), message: "PrepareToEncodeFrames failed") }

        if logger.level.rawValue >= LogLevel.debug.rawValue {
            var supported: CFDictionary?
            let supStatus = VTSessionCopySupportedPropertyDictionary(cs, supportedPropertyDictionaryOut: &supported)
            if supStatus != noErr {
                logger.debug("DBG VT supported properties unavailable status=\(supStatus)")
            }
            let supportedDict = supported as NSDictionary?

            func describe(_ v: CFTypeRef?) -> String {
                guard let v else { return "nil" }
                return CFCopyDescription(v) as String
            }

            func logProp(_ name: String, _ key: CFString) {
                let supportedStr = (supportedDict?[key] != nil) ? "supported" : "unknown"
                let (st, v) = copyProp(key)
                if st == noErr {
                    logger.debug("DBG VT prop \(name) (\(supportedStr)) = \(describe(v))")
                } else if st == kVTPropertyNotSupportedErr {
                    logger.debug("DBG VT prop \(name) (\(supportedStr)) = not supported")
                } else {
                    logger.debug("DBG VT prop \(name) (\(supportedStr)) read failed \(st)")
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

    private func handleEncodedSampleBuffer(_ sbuf: CMSampleBuffer) {
        guard let config else { return }
        guard let block = CMSampleBufferGetDataBuffer(sbuf) else { return }

        // Capture extradata once.
        if encoderExtradata == nil, let fmt = CMSampleBufferGetFormatDescription(sbuf) {
            let atom = (config.codec == .hevc) ? "hvcC" : "avcC"
            if let data = sampleDescriptionAtom(fmt, atom: atom) {
                encoderExtradata = AnnexB.stripAtomHeaderIfPresent(data, fourCC: atom)
                if config.codec == .h264, data.count > 4 {
                    nalLengthField = Int((data[4] & 0x3) + 1)
                } else if config.codec == .hevc, encoderExtradata!.count > 21 {
                    nalLengthField = Int((encoderExtradata![21] & 0x3) + 1)
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

        let totalLen = CMBlockBufferGetDataLength(block)
        var data = Data(count: totalLen)
        data.withUnsafeMutableBytes { ptr in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: totalLen, destination: ptr.baseAddress!)
        }

        // Convert length-prefixed to Annex-B.
        var idx = 0
        var annex = Data()
        while idx + nalLengthField <= data.count {
            var len: UInt32 = 0
            for _ in 0..<nalLengthField {
                len = (len << 8) | UInt32(data[idx])
                idx += 1
            }
            guard idx + Int(len) <= data.count else { break }
            annex.append(contentsOf: [0, 0, 0, 1])
            annex.append(data[idx..<idx + Int(len)])
            idx += Int(len)
        }

        let pts = sbuf.presentationTimeStamp
        let ptsTicks = config.timebase.ticks(from: RationalTime(value: pts.value, timescale: pts.timescale))

        let rawDts = CMSampleBufferGetDecodeTimeStamp(sbuf)
        let dtsTime: CMTime = (rawDts.isValid && rawDts.isNumeric) ? rawDts : pts
        let dtsTicks = config.timebase.ticks(from: RationalTime(value: dtsTime.value, timescale: dtsTime.timescale))
        let dur = sbuf.duration.isNumeric ? sbuf.duration : .invalid
        let durTicks = dur.isNumeric ? config.timebase.ticks(from: RationalTime(value: dur.value, timescale: dur.timescale)) : 0

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false)
        let isKey = (attachments as? [[NSObject: Any]])?.first?[kCMSampleAttachmentKey_NotSync as NSObject] == nil

        var w = ByteWriter()
        w.writeBE(UInt64(bitPattern: ptsTicks))
        w.writeBE(UInt64(bitPattern: dtsTicks))
        w.writeBE(UInt64(bitPattern: durTicks))
        w.writeBE(UInt32(isKey ? 1 : 0))
        w.writeBE(UInt32(annex.count))
        w.write(annex)

        do {
            try send(.packet, w.data)
        } catch {
            logger.error("send packet failed: \(error)")
        }
    }

    private func warmup() throws {
        guard let cs = compressionSession, let config else { return }
        warmupPending = true
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreate(kCFAllocatorDefault, config.width, config.height, cvPixelFormat, nil, &pb)
        guard st == kCVReturnSuccess, let buffer = pb else {
            warmupPending = false
            return
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            memset(base, 0, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let ts = CMTime(value: 0, timescale: Int32(max(1, config.timebase.den)))
        VTCompressionSessionEncodeFrame(cs, imageBuffer: buffer, presentationTimeStamp: ts, duration: .invalid, frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
        _ = warmupSemaphore.wait(timeout: .now() + 1.0)
    }

    // MARK: - Decoder

    private func setupDecoder(_ config: SessionConfiguration) throws {
        let codecType: CMVideoCodecType
        switch config.codec {
        case .h264: codecType = kCMVideoCodecType_H264
        case .hevc: codecType = kCMVideoCodecType_HEVC
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
            formatDescription = try makeFormatDescriptionFromAtom(codecType: codecType, width: config.width, height: config.height, atomName: atom, atomData: extra)
        } else if config.codec == .hevc, extra.count > 21, extra[0] == 1 {
            nalLengthField = Int((extra[21] & 0x03) + 1)
            formatDescription = try makeFormatDescriptionFromAtom(codecType: codecType, width: config.width, height: config.height, atomName: atom, atomData: extra)
        } else {
            // Fall back to parsing Annex-B parameter sets.
            nalLengthField = 4
            formatDescription = try formatDescriptionFromAnnexB(extra, codec: config.codec, codecType: codecType, nalLength: 4)
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
            kCVPixelBufferPixelFormatTypeKey: cvPixelFormat,
        ]

        var ds: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fmt,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &ds
        )
        guard status == noErr, let ds else {
            throw VTRemotedError.ioError(code: Int32(status), message: "VTDecompressionSessionCreate failed")
        }
        decompressionSession = ds
    }

    private func handleDecodedFrame(pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        guard let config else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return }

        let ptsTicks = config.timebase.ticks(from: RationalTime(value: pts.value, timescale: pts.timescale))
        let durTicks: Int64
        if duration.isNumeric {
            durTicks = config.timebase.ticks(from: RationalTime(value: duration.value, timescale: duration.timescale))
        } else {
            durTicks = 0
        }

        var w = ByteWriter()
        w.writeBE(UInt64(bitPattern: ptsTicks))
        w.writeBE(UInt64(bitPattern: durTicks))
        w.writeBE(UInt32(0))
        w.write(UInt8(2))

        for plane in 0..<2 {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let len = stride * height

            w.writeBE(UInt32(stride))
            w.writeBE(UInt32(height))

            let raw: Data
            if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) {
                raw = Data(bytes: base, count: len)
            } else {
                raw = Data(count: len)
            }

            if config.options.wireCompression == 1 {
                guard let compressed = LZ4Codec.compress(raw) else {
                    logger.error("lz4 compress failed")
                    return
                }
                w.writeBE(UInt32(compressed.count))
                w.write(compressed)
            } else {
                w.writeBE(UInt32(raw.count))
                w.write(raw)
            }
        }

        do {
            try send(.frame, w.data)
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
        case 2: return 10
        case 1: return 8
        default: return 0
        }
    }

    private func mapColorPrimaries(_ primaries: Int) -> CFString? {
        switch primaries {
        case AVCOL_PRI_BT2020:
            return kCVImageBufferColorPrimaries_ITU_R_2020
        case AVCOL_PRI_BT709:
            return kCVImageBufferColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_SMPTE170M:
            return kCVImageBufferColorPrimaries_SMPTE_C
        case AVCOL_PRI_BT470BG:
            return kCVImageBufferColorPrimaries_EBU_3213
        case AVCOL_PRI_UNSPECIFIED:
            return nil
        default:
            return nil
        }
    }

    private func mapTransferFunction(_ trc: Int) -> CFString? {
        switch trc {
        case AVCOL_TRC_SMPTE2084:
            return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_BT2020_10, AVCOL_TRC_BT2020_12:
            return kCVImageBufferTransferFunction_ITU_R_2020
        case AVCOL_TRC_BT709:
            return kCVImageBufferTransferFunction_ITU_R_709_2
        case AVCOL_TRC_SMPTE240M:
            return kCVImageBufferTransferFunction_SMPTE_240M_1995
        case AVCOL_TRC_SMPTE428:
            return kCVImageBufferTransferFunction_SMPTE_ST_428_1
        case AVCOL_TRC_ARIB_STD_B67:
            return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        case AVCOL_TRC_GAMMA22, AVCOL_TRC_GAMMA28:
            return kCVImageBufferTransferFunction_UseGamma
        case AVCOL_TRC_UNSPECIFIED:
            return nil
        default:
            return nil
        }
    }

    private func mapColorMatrix(_ space: Int) -> CFString? {
        switch space {
        case AVCOL_SPC_BT2020_CL, AVCOL_SPC_BT2020_NCL:
            return kCVImageBufferYCbCrMatrix_ITU_R_2020
        case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M:
            return kCVImageBufferYCbCrMatrix_ITU_R_601_4
        case AVCOL_SPC_BT709:
            return kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case AVCOL_SPC_SMPTE240M:
            return kCVImageBufferYCbCrMatrix_SMPTE_240M_1995
        case AVCOL_SPC_UNSPECIFIED:
            return nil
        default:
            return nil
        }
    }

    private func gammaLevel(_ trc: Int) -> Float32? {
        switch trc {
        case AVCOL_TRC_GAMMA22:
            return 2.2
        case AVCOL_TRC_GAMMA28:
            return 2.8
        default:
            return nil
        }
    }

    private func profileLevelString(codec: VideoCodec, profile: Int, level: Int, pixelFormat: UInt8, hasBFrames: Bool) throws -> CFString? {
        switch codec {
        case .h264:
            var hProfile = profile
            if hProfile == AV_PROFILE_UNKNOWN && level != 0 {
                hProfile = hasBFrames ? AV_PROFILE_H264_MAIN : AV_PROFILE_H264_BASELINE
            }

            switch hProfile {
            case AV_PROFILE_UNKNOWN:
                return nil
            case AV_PROFILE_H264_BASELINE:
                switch level {
                case 0: return vtProfileH264BaselineAuto
                case 13: return vtProfileH264Baseline13
                case 30: return vtProfileH264Baseline30
                case 31: return vtProfileH264Baseline31
                case 32: return vtProfileH264Baseline32
                case 40: return vtProfileH264Baseline40
                case 41: return vtProfileH264Baseline41
                case 42: return vtProfileH264Baseline42
                case 50: return vtProfileH264Baseline50
                case 51: return vtProfileH264Baseline51
                case 52: return vtProfileH264Baseline52
                default: break
                }
            case AV_PROFILE_H264_CONSTRAINED_BASELINE:
                if level != 0 {
                    logger.info("WARN Level is auto-selected when constrained-baseline profile is used")
                }
                return vtProfileH264ConstrainedBaselineAuto
            case AV_PROFILE_H264_MAIN:
                switch level {
                case 0: return vtProfileH264MainAuto
                case 30: return vtProfileH264Main30
                case 31: return vtProfileH264Main31
                case 32: return vtProfileH264Main32
                case 40: return vtProfileH264Main40
                case 41: return vtProfileH264Main41
                case 42: return vtProfileH264Main42
                case 50: return vtProfileH264Main50
                case 51: return vtProfileH264Main51
                case 52: return vtProfileH264Main52
                default: break
                }
            case AV_PROFILE_H264_CONSTRAINED_HIGH:
                if level != 0 {
                    logger.info("WARN Level is auto-selected when constrained-high profile is used")
                }
                return vtProfileH264ConstrainedHighAuto
            case AV_PROFILE_H264_HIGH:
                switch level {
                case 0: return vtProfileH264HighAuto
                case 30: return vtProfileH264High30
                case 31: return vtProfileH264High31
                case 32: return vtProfileH264High32
                case 40: return vtProfileH264High40
                case 41: return vtProfileH264High41
                case 42: return vtProfileH264High42
                case 50: return vtProfileH264High50
                case 51: return vtProfileH264High51
                case 52: return vtProfileH264High52
                default: break
                }
            case AV_PROFILE_H264_EXTENDED:
                switch level {
                case 0: return vtProfileH264ExtendedAuto
                case 50: return vtProfileH264Extended50
                default: break
                }
            default:
                break
            }
        case .hevc:
            let bitDepth = bitDepthForPixFmt(pixelFormat)
            switch profile {
            case AV_PROFILE_UNKNOWN:
                if bitDepth == 10 {
                    return vtProfileHEVCMain10Auto
                }
                return nil
            case AV_PROFILE_HEVC_MAIN:
                if bitDepth > 0 && bitDepth != 8 {
                    logger.info("WARN main profile with \(bitDepth)-bit input")
                }
                return vtProfileHEVCMainAuto
            case AV_PROFILE_HEVC_MAIN_10:
                if bitDepth > 0 && bitDepth != 10 {
                    throw VTRemotedError.unsupported("invalid main10 profile with \(bitDepth)-bit input")
                }
                return vtProfileHEVCMain10Auto
            case AV_PROFILE_HEVC_REXT:
                return vtProfileHEVCMain42210Auto
            default:
                break
            }
        }

        throw VTRemotedError.unsupported("invalid profile/level")
    }

    private func cmTime(fromTicks ticks: Int64, timebase: Timebase) -> CMTime {
        let num = max(1, timebase.num)
        let den = max(1, timebase.den)
        let (value, overflow) = ticks.multipliedReportingOverflow(by: Int64(num))
        let safe = overflow ? (ticks >= 0 ? Int64.max : Int64.min) : value
        return CMTime(value: CMTimeValue(safe), timescale: Int32(den))
    }

    private func sampleDescriptionAtom(_ fmt: CMFormatDescription, atom: String) -> Data? {
        guard let ext = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) else {
            return nil
        }
        if let dict = ext as? [AnyHashable: Any] {
            if let data = dict[atom] as? Data { return data }
            if let data = dict[atom] as? NSData { return data as Data }
        }
        return nil
    }

    private func makeFormatDescriptionFromAtom(codecType: CMVideoCodecType, width: Int, height: Int, atomName: String, atomData: Data) throws -> CMFormatDescription {
        let atoms: [String: Data] = [atomName: atomData]
        let ext: [String: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: atoms]
        var fmt: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: Int32(width),
            height: Int32(height),
            extensions: ext as CFDictionary,
            formatDescriptionOut: &fmt
        )
        guard status == noErr, let fmt else {
            throw VTRemotedError.ioError(code: Int32(status), message: "CMVideoFormatDescriptionCreate failed")
        }
        return fmt
    }

    private func formatDescriptionFromAnnexB(_ data: Data, codec: VideoCodec, codecType: CMVideoCodecType, nalLength: Int) throws -> CMFormatDescription {
        let units = AnnexB.splitNALUnits(data)
        switch codec {
        case .h264:
            var sps: Data?
            var pps: Data?
            for u in units {
                guard let first = u.first else { continue }
                let nalType = Int(first & 0x1f)
                if nalType == 7 && sps == nil { sps = u }
                if nalType == 8 && pps == nil { pps = u }
            }
            guard let sps, let pps else { throw VTRemotedError.protocolViolation("missing SPS/PPS") }
            var fmt: CMFormatDescription?
            let spsBytes = [UInt8](sps)
            let ppsBytes = [UInt8](pps)
            let status = spsBytes.withUnsafeBytes { spsPtr in
                ppsBytes.withUnsafeBytes { ppsPtr in
                    var ptrs: [UnsafePointer<UInt8>] = [
                        spsPtr.bindMemory(to: UInt8.self).baseAddress!,
                        ppsPtr.bindMemory(to: UInt8.self).baseAddress!,
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
            guard status == noErr, let fmt else { throw VTRemotedError.ioError(code: Int32(status), message: "CreateFromH264ParameterSets failed") }
            return fmt
        case .hevc:
            var vps: Data?
            var sps: Data?
            var pps: Data?
            for u in units {
                guard let first = u.first else { continue }
                let nalType = Int((first >> 1) & 0x3f)
                if nalType == 32 && vps == nil { vps = u }
                if nalType == 33 && sps == nil { sps = u }
                if nalType == 34 && pps == nil { pps = u }
            }
            guard let vps, let sps, let pps else { throw VTRemotedError.protocolViolation("missing VPS/SPS/PPS") }
            var fmt: CMFormatDescription?
            let vpsBytes = [UInt8](vps)
            let spsBytes = [UInt8](sps)
            let ppsBytes = [UInt8](pps)
            let status = vpsBytes.withUnsafeBytes { vpsPtr in
                spsBytes.withUnsafeBytes { spsPtr in
                    ppsBytes.withUnsafeBytes { ppsPtr in
                        var ptrs: [UnsafePointer<UInt8>] = [
                            vpsPtr.bindMemory(to: UInt8.self).baseAddress!,
                            spsPtr.bindMemory(to: UInt8.self).baseAddress!,
                            ppsPtr.bindMemory(to: UInt8.self).baseAddress!,
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
            guard status == noErr, let fmt else { throw VTRemotedError.ioError(code: Int32(status), message: "CreateFromHEVCParameterSets failed") }
            return fmt
        }
    }
}
#endif
