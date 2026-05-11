#if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo)
    import CoreFoundation
    import CoreMedia
    import CoreVideo
    import Foundation
    import VideoToolbox

    /// VideoToolbox-backed encoder/decoder.
    final class VideoToolboxCodecSession: CodecSession, StreamingCodecSession {
        private let send: MessageSender
        private let logger = Logger.shared

        private var config: SessionConfiguration?

        private var compressionSession: VTCompressionSession?
        private var decompressionSession: VTDecompressionSession?
        private var formatDescription: CMFormatDescription?
        private var nalLengthField: Int = 4
        private var cvPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        private var encoderExtradata: Data?
        private var encoderCodec: VideoCodec = .h264

        private let warmupSemaphore = DispatchSemaphore(value: 0)
        private var forceKeyframeNext = false

        /// FFmpeg's `AV_NOPTS_VALUE` (INT64_MIN) transported over the wire.
        private static let noPtsTicks: Int64 = Int64.min

        /// Tracks DTS/PTS for monotonicity and duplicate detection
        private let timestampTracker = TimestampTracker()
        private let callbackLock = NSLock()

        // VideoToolbox can invoke encoder output callbacks out-of-order.
        //
        // When frame reordering is disabled (max_b_frames == 0), the correct emission order is
        // submission order. When frame reordering is enabled, the correct emission order is
        // decoding order (DTS). We support both:
        // - Seq reordering for the no-reorder case (exact, no fixed latency).
        // - DTS window reordering when VT reports frame reordering enabled (bounded latency).
        private var encodeReorderBySeq = false
        private var encodeSeqNext: UInt64 = 0
        private var encodeSeqExpected: UInt64 = 0
        private var encodePendingPackets: [UInt64: PendingEncodedPacket] = [:]
        private var encodeDroppedSeqs = Set<UInt64>()
        private var encodeDtsReorderDepth: Int = 0
        private var encodeDtsReorderBuffer: EncodeReorderBuffer<PendingEncodedPacket>?

        private var decodeAsyncEnabled = false
        private var decodeReorderDepth = 0
        private var decodeReorderBuffer: DecodeReorderBuffer<[Data]>?
        private var transcodeReorderBuffer: DecodeReorderBuffer<TranscodeFramePayload>?
        private var pendingDecodeSideDataByPts: [Int64: [WireSideData]] = [:]
        private var pendingDecodeSideDataOrder: [Int64] = []
        private var transcodeOutputPool: CVPixelBufferPool?
        private var transcodeTransferSession: VTPixelTransferSession?
        private var transcodeOutputWidth: Int = 0
        private var transcodeOutputHeight: Int = 0
        private var transcodeNeedsTransfer = false

        // When encoding with frame reordering enabled, VideoToolbox can report DTS values that are
        // ahead of PTS for B-frames. FFmpeg's muxer treats dts > pts as invalid and will "guess"
        // timestamps, which causes jitter/duplicates and breaks metrics alignment.
        //
        // We keep PTS unchanged (A/V sync), and shift DTS earlier by a fixed offset (in ticks)
        // derived from reorder depth and nominal frame duration.
        private var nominalFrameDurTicks: Int64 = 0
        private var encodeDtsOffsetTicks: Int64 = 0

        private struct WireSideData {
            let type: UInt32
            let data: Data
        }

        private class FrameContext {
            let seq: UInt64
            let pixelBuffer: CVPixelBuffer?
            let sideData: [WireSideData]
            let isWarmup: Bool
            init(
                seq: UInt64,
                pixelBuffer: CVPixelBuffer? = nil,
                sideData: [WireSideData] = [],
                isWarmup: Bool = false
            ) {
                self.seq = seq
                self.pixelBuffer = pixelBuffer
                self.sideData = sideData
                self.isWarmup = isWarmup
            }
        }

        private func clearPendingDecodeSideData() {
            callbackLock.lock()
            pendingDecodeSideDataByPts.removeAll(keepingCapacity: true)
            pendingDecodeSideDataOrder.removeAll(keepingCapacity: true)
            callbackLock.unlock()
        }

        private func storePendingDecodeSideData(ptsTicks: Int64, sideData: [WireSideData]) {
            guard !sideData.isEmpty else { return }
            guard ptsTicks != Self.noPtsTicks else {
                logger.debug("dropping decode side data without PTS")
                return
            }

            callbackLock.lock()
            if pendingDecodeSideDataByPts[ptsTicks] != nil {
                pendingDecodeSideDataOrder.removeAll { $0 == ptsTicks }
            }
            pendingDecodeSideDataByPts[ptsTicks] = sideData
            pendingDecodeSideDataOrder.append(ptsTicks)

            let limit = max(16, decodeReorderDepth + 8)
            while pendingDecodeSideDataOrder.count > limit {
                let evictedPts = pendingDecodeSideDataOrder.removeFirst()
                pendingDecodeSideDataByPts.removeValue(forKey: evictedPts)
            }
            callbackLock.unlock()
        }

        private func takePendingDecodeSideData(ptsTicks: Int64) -> [WireSideData] {
            guard ptsTicks != Self.noPtsTicks else { return [] }

            callbackLock.lock()
            let sideData = pendingDecodeSideDataByPts.removeValue(forKey: ptsTicks) ?? []
            if !sideData.isEmpty {
                pendingDecodeSideDataOrder.removeAll { $0 == ptsTicks }
            }
            callbackLock.unlock()
            return sideData
        }

        private struct PendingEncodedPacket {
            let ptsTicks: Int64
            let dtsTicks: Int64
            let durTicks: Int64
            let isKey: Bool
            let annex: Data
            let sideData: [WireSideData]
        }

        private struct TranscodeFramePayload {
            let pixelBuffer: CVPixelBuffer
            let durTicks: Int64
            let sideData: [WireSideData]
        }
        private let inputBufferPool = BufferPool()
        private let outputBufferPool = BufferPool()

        init(sender: @escaping MessageSender) {
            send = sender
        }

        private func nextEncodeSeq() -> UInt64 {
            callbackLock.lock()
            let seq = encodeSeqNext
            encodeSeqNext &+= 1
            callbackLock.unlock()
            return seq
        }

        private func takeForceKeyframeNext() -> Bool {
            callbackLock.lock()
            let shouldForceKeyframe = forceKeyframeNext
            forceKeyframeNext = false
            callbackLock.unlock()
            return shouldForceKeyframe
        }

        private static func decompressWirePayload(
            mode: Int,
            source: UnsafeRawBufferPointer,
            destination: UnsafeMutableRawPointer,
            expectedSize: Int
        ) -> Bool {
            switch mode {
            case 1:
                return LZ4Codec.decompressRaw(source, into: destination, expectedSize: expectedSize)
            case 2:
                return ZstdCodec.decompressRaw(source, into: destination, expectedSize: expectedSize)
            default:
                return false
            }
        }

        private static func compressWirePayload(mode: Int, data: Data) -> Data? {
            switch mode {
            case 1:
                return LZ4Codec.compress(data)
            case 2:
                return ZstdCodec.compress(data)
            default:
                return data
            }
        }

        private static func readWireSideData(_ reader: inout ByteReader) throws -> [WireSideData] {
            guard reader.remaining > 0 else { return [] }
            let count = Int(try reader.readUInt8())
            var records: [WireSideData] = []
            records.reserveCapacity(min(count, 16))
            for index in 0 ..< count {
                let type = try reader.readBEUInt32()
                let size = try Int(reader.readBEUInt32())
                let data = try reader.readBytes(count: size)
                if index < 16 {
                    records.append(WireSideData(type: type, data: data))
                }
            }
            return records
        }

        private static func writeWireSideData(_ sideData: [WireSideData]) -> Data {
            guard !sideData.isEmpty else { return Data() }
            var writer = ByteWriter()
            writer.write(UInt8(clamping: sideData.count))
            for record in sideData.prefix(16) {
                writer.writeBE(record.type)
                writer.writeBE(UInt32(clamping: record.data.count))
                writer.write(record.data)
            }
            return writer.data
        }

        // `heightHint` lets callers override inferred row count when wire payload includes padding.
        // swiftlint:disable:next function_parameter_count
        private static func copyPlaneBytes(
            source srcBase: UnsafePointer<UInt8>,
            destination dstBase: UnsafeMutablePointer<UInt8>,
            expectedSize: Int,
            stride: Int,
            destinationStride: Int,
            rowBytes: Int,
            heightHint: Int? = nil
        ) {
            if stride == destinationStride, stride == rowBytes {
                memcpy(dstBase, srcBase, expectedSize)
                return
            }

            let height = heightHint.map { max(0, $0) } ?? (expectedSize / stride)
            let copyBytes = min(rowBytes, min(stride, destinationStride))
            for row in 0 ..< height {
                memcpy(dstBase.advanced(by: row * destinationStride),
                       srcBase.advanced(by: row * stride),
                       copyBytes)
            }
        }

        // `flags` mirrors the FRAME wire keyframe request passed to VideoToolbox.
        private func encodePreparedFrame(
            session: VTCompressionSession,
            pixelBuffer: CVPixelBuffer,
            ptsTicks: Int64,
            durTicks: Int64,
            flags: UInt32,
            sideData: [WireSideData] = []
        ) throws {
            guard let config else { throw VTRemotedError.protocolViolation("FRAME before CONFIGURE") }

            let pts = cmTimeOrInvalid(fromTicks: ptsTicks, timebase: config.timebase)
            let duration = durTicks > 0 ? cmTime(fromTicks: durTicks, timebase: config.timebase) : .invalid
            let forceKey = (flags & 1) != 0 || takeForceKeyframeNext()
            let props: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil

            let seq = nextEncodeSeq()
            // Retain the pixel buffer until the encoder callback fires. VideoToolbox may consume frames
            // asynchronously, and the pool can otherwise recycle the buffer while it is still in use.
            let frameContext = FrameContext(seq: seq, pixelBuffer: pixelBuffer, sideData: sideData)
            let ctxPtr = Unmanaged.passRetained(frameContext).toOpaque()

            var infoFlags = VTEncodeInfoFlags()
            let encodeStatus = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: pts,
                duration: duration,
                frameProperties: props,
                sourceFrameRefcon: ctxPtr,
                infoFlagsOut: &infoFlags
            )
            if encodeStatus != noErr {
                Unmanaged<FrameContext>.fromOpaque(ctxPtr).release()
                logger.error(
                    "VTCompressionSessionEncodeFrame failed seq=\(seq) status=\(encodeStatus) " +
                        "infoFlags=\(infoFlags.rawValue) ptsTicks=\(ptsTicks) durTicks=\(durTicks)"
                )
                throw VTRemotedError.ioError(
                    code: Int32(encodeStatus),
                    message: "VTCompressionSessionEncodeFrame failed"
                )
            }
        }

        private func makeCompressionPixelBuffer(session: VTCompressionSession) throws -> CVPixelBuffer {
            guard let pool = VTCompressionSessionGetPixelBufferPool(session) else {
                throw VTRemotedError.videoToolboxUnavailable
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            guard status == kCVReturnSuccess, let pBuffer = pixelBuffer else {
                throw VTRemotedError.ioError(code: Int32(status), message: "CVPixelBufferPoolCreatePixelBuffer failed")
            }
            return pBuffer
        }

        private static func planeRowBytes(width: Int, pixelFormat: UInt8) -> (y: Int, uv: Int) {
            if pixelFormat == VTRPixelFormat.bgra || pixelFormat == VTRPixelFormat.ayuv {
                return (width * 4, 0)
            }
            let bytesPerSample = (pixelFormat == VTRPixelFormat.p010 || pixelFormat == VTRPixelFormat.p210) ? 2 : 1
            let rowBytes = width * bytesPerSample
            return (rowBytes, rowBytes)
        }

        private static func expectedPlaneCount(pixelFormat: UInt8) -> UInt8 {
            switch pixelFormat {
            case VTRPixelFormat.bgra, VTRPixelFormat.ayuv:
                return 1
            default:
                return 2
            }
        }

        private static func planeHeights(frameHeight: Int, pixelFormat: UInt8) -> (first: Int, second: Int) {
            switch pixelFormat {
            case VTRPixelFormat.bgra, VTRPixelFormat.ayuv:
                return (frameHeight, 0)
            case VTRPixelFormat.p210:
                return (frameHeight, frameHeight)
            default:
                return (frameHeight, frameHeight / 2)
            }
        }

        private static func baseAddressAndStride(
            pixelBuffer: CVPixelBuffer,
            planeIndex: Int
        ) -> (base: UnsafeMutableRawPointer, stride: Int)? {
            if CVPixelBufferIsPlanar(pixelBuffer) {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, planeIndex) else { return nil }
                return (base, CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, planeIndex))
            }
            guard planeIndex == 0, let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            return (base, CVPixelBufferGetBytesPerRow(pixelBuffer))
        }

        func configure(_ configuration: SessionConfiguration) throws -> Data {
            config = configuration
            encoderExtradata = nil
            callbackLock.lock()
            forceKeyframeNext = false
            callbackLock.unlock()
            encodeReorderBySeq = false
            encodeSeqNext = 0
            encodeSeqExpected = 0
            encodePendingPackets.removeAll(keepingCapacity: true)
            encodeDroppedSeqs.removeAll(keepingCapacity: true)
            encodeDtsReorderDepth = 0
            encodeDtsReorderBuffer = nil
            decodeAsyncEnabled = false
            decodeReorderDepth = 0
            decodeReorderBuffer = nil
            transcodeReorderBuffer = nil
            clearPendingDecodeSideData()
            transcodeOutputPool = nil
            transcodeTransferSession = nil
            transcodeOutputWidth = 0
            transcodeOutputHeight = 0
            transcodeNeedsTransfer = false
            nominalFrameDurTicks = 0
            encodeDtsOffsetTicks = 0
            switch configuration.mode {
            case .encode:
                encoderCodec = configuration.codec
                encodeReorderBySeq = configuration.options.maxBFrames <= 0
                let enforceMonotonicPts = encodeReorderBySeq
                timestampTracker.reset(enforceMonotonicPts: enforceMonotonicPts)
                try setupEncoder(configuration, codec: encoderCodec)
                let extra = encoderExtradata ?? Data()
                logger.info("CONFIGURE returning extradata size=\(extra.count)")
                return extra
            case .decode:
                timestampTracker.reset()
                decodeAsyncEnabled = configuration.options.decodeAsync != 0
                if decodeAsyncEnabled {
                    let depth = configuration.options.decodeReorderDepth
                    decodeReorderDepth = depth >= 0 ? depth : 2
                    decodeReorderBuffer = DecodeReorderBuffer(depth: decodeReorderDepth)
                }
                try setupDecoder(configuration)
                return Data()
            case .transcode:
                encoderCodec = configuration.outputCodec
                encodeReorderBySeq = configuration.options.maxBFrames <= 0
                let enforceMonotonicPts = encodeReorderBySeq
                timestampTracker.reset(enforceMonotonicPts: enforceMonotonicPts)
                decodeAsyncEnabled = configuration.options.decodeAsync != 0
                if decodeAsyncEnabled {
                    let depth = configuration.options.decodeReorderDepth
                    decodeReorderDepth = depth >= 0 ? depth : 2
                    transcodeReorderBuffer = DecodeReorderBuffer(depth: decodeReorderDepth)
                }
                try setupDecoder(configuration)
                try setupEncoder(configuration, codec: encoderCodec)
                setupTranscodeTransfer(configuration)
                let extra = encoderExtradata ?? Data()
                logger.info("CONFIGURE returning extradata size=\(extra.count)")
                return extra
            }
        }

        func handleFrameMessage(_ payload: Data) throws {
            guard let config else { throw VTRemotedError.protocolViolation("FRAME before CONFIGURE") }
            guard config.mode == .encode else { return }
            guard let session = compressionSession else { throw VTRemotedError.videoToolboxUnavailable }

            var reader = ByteReader(payload)
            let ptsTicks = try Int64(bitPattern: reader.readBEUInt64())
            let durTicks = try Int64(bitPattern: reader.readBEUInt64())
            let flags = try reader.readBEUInt32()
            let planes = try reader.readUInt8()
            let expectedPlanes = Self.expectedPlaneCount(pixelFormat: config.pixelFormat)
            guard planes == expectedPlanes else {
                throw VTRemotedError.protocolViolation("expected \(expectedPlanes) planes")
            }

            let stride0 = try Int(reader.readBEUInt32())
            let height0 = try Int(reader.readBEUInt32())
            let len0 = try Int(reader.readBEUInt32())
            // Zero-copy: get range instead of copying data
            let yRange = try reader.sliceRange(count: len0)

            let stride1: Int
            let height1: Int
            let uvRange: Range<Int>
            if planes > 1 {
                stride1 = try Int(reader.readBEUInt32())
                height1 = try Int(reader.readBEUInt32())
                let len1 = try Int(reader.readBEUInt32())
                // Zero-copy: get range instead of copying data
                uvRange = try reader.sliceRange(count: len1)
            } else {
                stride1 = 0
                height1 = 0
                uvRange = 0..<0
            }

            let expectedY = max(0, stride0 * height0)
            let expectedUV = max(0, stride1 * height1)

            let pBuffer = try makeCompressionPixelBuffer(session: session)

            CVPixelBufferLockBaseAddress(pBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pBuffer, []) }

            let rowBytes = Self.planeRowBytes(width: config.width, pixelFormat: config.pixelFormat)
            let rowBytesY = rowBytes.y
            let rowBytesUV = rowBytes.uv

            // Helper to process a plane with zero-copy source access
            func processPlane(
                planeIndex: Int,
                rawRange: Range<Int>,
                expectedSize: Int,
                stride: Int,
                rowBytes: Int
            ) throws {
                guard let destination = Self.baseAddressAndStride(pixelBuffer: pBuffer, planeIndex: planeIndex) else { return }
                let destBase = destination.base
                let destStride = destination.stride

                if config.options.wireCompression == 0 {
                    // No compression: copy directly from payload into the pixel buffer (avoid temp buffer).
                    guard rawRange.count >= expectedSize else {
                        throw VTRemotedError.protocolViolation("plane too small")
                    }
                    guard expectedSize > 0 else { return }
                    payload.withUnsafeBytes { payloadPtr in
                        guard let baseAddr = payloadPtr.baseAddress else { return }
                        let srcBase = baseAddr.advanced(by: rawRange.lowerBound)
                            .assumingMemoryBound(to: UInt8.self)
                        let dstBase = destBase.assumingMemoryBound(to: UInt8.self)
                        Self.copyPlaneBytes(
                            source: srcBase,
                            destination: dstBase,
                            expectedSize: expectedSize,
                            stride: stride,
                            destinationStride: destStride,
                            rowBytes: rowBytes
                        )
                    }
                    return
                }

                // Compressed path: decompress to temp buffer first (System Memory) to avoid
                // reading from WC memory during LZ4 back-references.
                var temp = inputBufferPool.get(capacity: expectedSize)
                defer { inputBufferPool.return(temp) }
                if temp.count != expectedSize {
                    temp.count = expectedSize
                }

                // Zero-copy access to source data
                guard expectedSize > 0, rawRange.count > 0 else {
                    throw VTRemotedError.protocolViolation("empty compressed plane")
                }
                let success: Bool = payload.withUnsafeBytes { payloadPtr in
                    guard let baseAddr = payloadPtr.baseAddress else { return false }
                    let rawPtr = UnsafeRawBufferPointer(
                        start: baseAddr.advanced(by: rawRange.lowerBound),
                        count: rawRange.count
                    )
                    return temp.withUnsafeMutableBytes { dstPtr in
                        guard let dstBase = dstPtr.baseAddress else { return false }
                        return Self.decompressWirePayload(
                            mode: config.options.wireCompression,
                            source: rawPtr,
                            destination: dstBase,
                            expectedSize: expectedSize
                        )
                    }
                }
                guard success else { throw VTRemotedError.protocolViolation("Decompress failed") }

                // Copy from System Memory to Video Memory (WC)
                temp.withUnsafeBytes { srcPtr in
                    guard let srcBase = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    let dstBase = destBase.assumingMemoryBound(to: UInt8.self)

                    Self.copyPlaneBytes(
                        source: srcBase,
                        destination: dstBase,
                        expectedSize: expectedSize,
                        stride: stride,
                        destinationStride: destStride,
                        rowBytes: rowBytes
                    )
                }
            }

            let planeIterations = Int(planes)
            let errorSlots = UnsafeMutableBufferPointer<Error?>.allocate(capacity: planeIterations)
            errorSlots.initialize(repeating: nil)
            defer { errorSlots.deallocate() }
            DispatchQueue.concurrentPerform(iterations: planeIterations) { plane in
                do {
                    if plane == 0 {
                        try processPlane(
                            planeIndex: 0,
                            rawRange: yRange,
                            expectedSize: expectedY,
                            stride: stride0,
                            rowBytes: rowBytesY
                        )
                    } else {
                        try processPlane(
                            planeIndex: 1,
                            rawRange: uvRange,
                            expectedSize: expectedUV,
                            stride: stride1,
                            rowBytes: rowBytesUV
                        )
                    }
                } catch {
                    errorSlots[plane] = error
                }
            }
            if let err = errorSlots[0] { throw err }
            if planeIterations > 1, let err = errorSlots[1] { throw err }

            let sideData = try Self.readWireSideData(&reader)

            try encodePreparedFrame(
                session: session,
                pixelBuffer: pBuffer,
                ptsTicks: ptsTicks,
                durTicks: durTicks,
                flags: flags,
                sideData: sideData
            )
        }

        func handleFrameStream(streamIO: VTRStreamIO, length: Int) throws {
            guard let config else { throw VTRemotedError.protocolViolation("FRAME before CONFIGURE") }
            guard config.mode == .encode else {
                try streamIO.skip(length: length)
                return
            }
            guard let session = compressionSession else { throw VTRemotedError.videoToolboxUnavailable }

            var remaining = length
            func require(_ byteCount: Int) throws {
                guard byteCount >= 0, remaining >= byteCount else {
                    throw VTRemotedError.protocolViolation("unexpected EOF")
                }
            }

            func readUInt8() throws -> UInt8 {
                try require(1)
                var value: UInt8 = 0
                try withUnsafeMutableBytes(of: &value) { raw in
                    try streamIO.readExact(into: raw.baseAddress!, count: 1)
                }
                remaining -= 1
                return value
            }

            func readBEUInt32() throws -> UInt32 {
                try require(4)
                var value: UInt32 = 0
                try withUnsafeMutableBytes(of: &value) { raw in
                    try streamIO.readExact(into: raw.baseAddress!, count: 4)
                }
                remaining -= 4
                return UInt32(bigEndian: value)
            }

            func readBEUInt64() throws -> UInt64 {
                try require(8)
                var value: UInt64 = 0
                try withUnsafeMutableBytes(of: &value) { raw in
                    try streamIO.readExact(into: raw.baseAddress!, count: 8)
                }
                remaining -= 8
                return UInt64(bigEndian: value)
            }

            let ptsTicks = Int64(bitPattern: try readBEUInt64())
            let durTicks = Int64(bitPattern: try readBEUInt64())
            let flags = try readBEUInt32()
            let planes = try readUInt8()
            let expectedPlanes = Self.expectedPlaneCount(pixelFormat: config.pixelFormat)
            guard planes == expectedPlanes else {
                throw VTRemotedError.protocolViolation("expected \(expectedPlanes) planes")
            }

            let stride0 = Int(try readBEUInt32())
            let height0 = Int(try readBEUInt32())
            let len0 = Int(try readBEUInt32())
            let expectedY = max(0, stride0 * height0)

            let pBuffer = try makeCompressionPixelBuffer(session: session)

            CVPixelBufferLockBaseAddress(pBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pBuffer, []) }

            let rowBytes = Self.planeRowBytes(width: config.width, pixelFormat: config.pixelFormat)
            let rowBytesY = rowBytes.y
            let rowBytesUV = rowBytes.uv

            func skipBytes(_ count: Int) throws {
                guard count > 0 else { return }
                try require(count)
                try streamIO.skip(length: count)
                remaining -= count
            }

            func readBytes(_ count: Int) throws -> Data {
                guard count > 0 else { return Data() }
                try require(count)
                var data = Data(count: count)
                try data.withUnsafeMutableBytes { raw in
                    guard let base = raw.baseAddress else {
                        throw VTRemotedError.protocolViolation("empty destination")
                    }
                    try streamIO.readExact(into: base, count: count)
                }
                remaining -= count
                return data
            }

            // Plane fields mirror wire metadata and destination buffer geometry.
            // swiftlint:disable:next function_parameter_count
            func processPlane(
                planeIndex: Int,
                wireLen: Int,
                expectedSize: Int,
                stride: Int,
                height: Int,
                rowBytes: Int
            ) throws {
                guard wireLen >= 0 else { throw VTRemotedError.protocolViolation("negative plane length") }
                try require(wireLen)

                guard let destination = Self.baseAddressAndStride(pixelBuffer: pBuffer, planeIndex: planeIndex) else {
                    try skipBytes(wireLen)
                    return
                }
                let destBase = destination.base
                let destStride = destination.stride

                if config.options.wireCompression == 0 {
                    guard wireLen >= expectedSize else {
                        throw VTRemotedError.protocolViolation("plane too small")
                    }

                    if stride == destStride, stride == rowBytes {
                        // Read directly into the pixel buffer plane (avoids temp buffer + memcpy).
                        try streamIO.readExact(into: destBase, count: expectedSize)
                        remaining -= expectedSize
                        try skipBytes(wireLen - expectedSize)
                        return
                    }

                    // Strided read: consume full rows (incl. padding) and copy the useful bytes.
                    var rowBuf = inputBufferPool.get(capacity: stride)
                    defer { inputBufferPool.return(rowBuf) }
                    if rowBuf.count != stride { rowBuf.count = stride }

                    let dstBase = destBase.assumingMemoryBound(to: UInt8.self)
                    let copyBytes = min(rowBytes, min(stride, destStride))
                    for row in 0 ..< max(0, height) {
                        try streamIO.readExact(into: &rowBuf, count: stride)
                        remaining -= stride
                        rowBuf.withUnsafeBytes { srcPtr in
                            guard let srcBase = srcPtr.baseAddress else { return }
                            memcpy(dstBase.advanced(by: row * destStride), srcBase, copyBytes)
                        }
                    }

                    let consumed = max(0, stride * height)
                    try skipBytes(wireLen - consumed)
                    return
                }

                // Compressed path: read compressed bytes, decompress to system memory, then memcpy into WC memory.
                var compressed = inputBufferPool.get(capacity: wireLen)
                defer { inputBufferPool.return(compressed) }
                if compressed.count != wireLen { compressed.count = wireLen }
                try streamIO.readExact(into: &compressed, count: wireLen)
                remaining -= wireLen

                var temp = inputBufferPool.get(capacity: expectedSize)
                defer { inputBufferPool.return(temp) }
                if temp.count != expectedSize { temp.count = expectedSize }

                guard expectedSize > 0, compressed.count > 0 else {
                    throw VTRemotedError.protocolViolation("empty compressed plane")
                }
                let success: Bool = compressed.withUnsafeBytes { compressedPtr in
                    let rawPtr = UnsafeRawBufferPointer(
                        start: compressedPtr.baseAddress,
                        count: compressed.count
                    )
                    return temp.withUnsafeMutableBytes { dstPtr in
                        guard let dstBase = dstPtr.baseAddress else { return false }
                        return Self.decompressWirePayload(
                            mode: config.options.wireCompression,
                            source: rawPtr,
                            destination: dstBase,
                            expectedSize: expectedSize
                        )
                    }
                }
                guard success else { throw VTRemotedError.protocolViolation("Decompress failed") }

                temp.withUnsafeBytes { srcPtr in
                    guard let srcBase = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    let dstBase = destBase.assumingMemoryBound(to: UInt8.self)
                    Self.copyPlaneBytes(
                        source: srcBase,
                        destination: dstBase,
                        expectedSize: expectedSize,
                        stride: stride,
                        destinationStride: destStride,
                        rowBytes: rowBytes,
                        heightHint: height
                    )
                }
            }

            try processPlane(
                planeIndex: 0,
                wireLen: len0,
                expectedSize: expectedY,
                stride: stride0,
                height: height0,
                rowBytes: rowBytesY
            )

            if planes > 1 {
                // Plane metadata is interleaved with plane bytes on the wire:
                // [plane0 meta][plane0 bytes][plane1 meta][plane1 bytes]...
                let stride1 = Int(try readBEUInt32())
                let height1 = Int(try readBEUInt32())
                let len1 = Int(try readBEUInt32())
                let expectedUV = max(0, stride1 * height1)

                try processPlane(
                    planeIndex: 1,
                    wireLen: len1,
                    expectedSize: expectedUV,
                    stride: stride1,
                    height: height1,
                    rowBytes: rowBytesUV
                )
            }

            var sideData: [WireSideData] = []
            if remaining > 0 {
                let sideDataCount = Int(try readUInt8())
                sideData.reserveCapacity(min(sideDataCount, 16))
                for index in 0 ..< sideDataCount {
                    let type = try readBEUInt32()
                    let size = Int(try readBEUInt32())
                    let data = try readBytes(size)
                    if index < 16 {
                        sideData.append(WireSideData(type: type, data: data))
                    }
                }
            }

            // Drain any unknown trailing bytes for forward-compatibility.
            if remaining > 0 {
                try streamIO.skip(length: remaining)
                remaining = 0
            }

            try encodePreparedFrame(
                session: session,
                pixelBuffer: pBuffer,
                ptsTicks: ptsTicks,
                durTicks: durTicks,
                flags: flags,
                sideData: sideData
            )
        }

        private func encodePixelBuffer(
            _ pixelBuffer: CVPixelBuffer,
            pts: CMTime,
            duration: CMTime,
            sideData: [WireSideData] = []
        ) {
            guard let session = compressionSession else { return }
            let forceKey = takeForceKeyframeNext()
            let props: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil

            let seq = nextEncodeSeq()
            let frameContext = FrameContext(seq: seq, pixelBuffer: pixelBuffer, sideData: sideData)
            let ctxPtr = Unmanaged.passRetained(frameContext).toOpaque()

            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: pts,
                duration: duration,
                frameProperties: props,
                sourceFrameRefcon: ctxPtr,
                infoFlagsOut: nil
            )
            if status != noErr {
                logger.error("encode frame failed: \(status)")
            }
        }

        func handlePacketMessage(_ payload: Data) throws {
            guard let config else { throw VTRemotedError.protocolViolation("PACKET before CONFIGURE") }
            guard config.mode == .decode || config.mode == .transcode else { return }
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
            let sideData = try Self.readWireSideData(&reader)
            storePendingDecodeSideData(ptsTicks: ptsTicks, sideData: sideData)

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
                guard let base = ptr.baseAddress else { return }
                _ = CMBlockBufferReplaceDataBytes(
                    with: base,
                    blockBuffer: bufferBlock,
                    offsetIntoDestination: 0,
                    dataLength: dataCount
                )
            }

            var timing = CMSampleTimingInfo(
                duration: durTicks > 0 ? cmTime(fromTicks: durTicks, timebase: config.timebase) : .invalid,
                presentationTimeStamp: cmTimeOrInvalid(fromTicks: ptsTicks, timebase: config.timebase),
                decodeTimeStamp: cmTimeOrInvalid(fromTicks: dtsTicks, timebase: config.timebase)
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

            var decodeFlags: VTDecodeFrameFlags = []
            if decodeAsyncEnabled {
                // kVTDecodeFrame_EnableAsynchronousDecompression (1<<0)
                decodeFlags = VTDecodeFrameFlags(rawValue: 1 << 0)
            }
            status = VTDecompressionSessionDecodeFrame(session,
                                                       sampleBuffer: sampleBuffer,
                                                       flags: decodeFlags,
                                                       frameRefcon: nil,
                                                       infoFlagsOut: nil)
            guard status == noErr else {
                throw VTRemotedError.ioError(code: Int32(status), message: "VTDecompressionSessionDecodeFrame failed")
            }
            if !decodeAsyncEnabled {
                _ = VTDecompressionSessionWaitForAsynchronousFrames(session)
            }
        }

        func flush() throws {
            // In transcode mode, the decoder can hold a small reorder buffer (especially with
            // B-frames) and only release the final frames on EOS flush. Those decoded frames must be
            // submitted to the encoder before we call VTCompressionSessionCompleteFrames, otherwise
            // the last frames can be silently dropped.
            if config?.mode == .transcode {
                if let session = decompressionSession {
                    _ = VTDecompressionSessionFinishDelayedFrames(session)
                    _ = VTDecompressionSessionWaitForAsynchronousFrames(session)
                    flushDecodedFrames()
                }
                if let session = compressionSession {
                    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                    callbackLock.lock()
                    if encodeReorderBySeq {
                        drainEncodePacketsLocked()
                    } else if let reorder = encodeDtsReorderBuffer {
                        let pkts = reorder.flush()
                        for pkt in pkts {
                            emitEncodedPacketLocked(pkt)
                        }
                    }
                    callbackLock.unlock()
                }
                return
            }

            if let session = compressionSession {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                callbackLock.lock()
                if encodeReorderBySeq {
                    drainEncodePacketsLocked()
                } else if let reorder = encodeDtsReorderBuffer {
                    let pkts = reorder.flush()
                    for pkt in pkts {
                        emitEncodedPacketLocked(pkt)
                    }
                }
                callbackLock.unlock()
            }
            if let session = decompressionSession {
                _ = VTDecompressionSessionFinishDelayedFrames(session)
                _ = VTDecompressionSessionWaitForAsynchronousFrames(session)
                flushDecodedFrames()
            }
        }

        func shutdown() {
            if let session = compressionSession {
                VTCompressionSessionInvalidate(session)
            }
            if let session = decompressionSession {
                VTDecompressionSessionInvalidate(session)
            }
            transcodeTransferSession = nil
            transcodeOutputPool = nil
            transcodeNeedsTransfer = false
            if decodeAsyncEnabled {
                callbackLock.lock()
                decodeReorderBuffer = nil
                transcodeReorderBuffer = nil
                callbackLock.unlock()
            }
        }

        // MARK: - Encoder

        private func setupEncoder(_ config: SessionConfiguration, codec: VideoCodec) throws {
            let codecType: CMVideoCodecType = switch codec {
            case .h264: kCMVideoCodecType_H264
            case .hevc: kCMVideoCodecType_HEVC
            }

            if codec == .h264, config.pixelFormat != VTRPixelFormat.nv12 {
                throw VTRemotedError.unsupported("h264 requires nv12")
            }

            cvPixelFormat = try pickCVPixelFormat(pixelFormat: config.pixelFormat)

            func makeSession() throws -> VTCompressionSession {
                // Setup session properties
                let encInfo = NSMutableDictionary()

                // HW Encoder
                if config.options.requireSoftware {
                    encInfo[VideoToolboxProperties.vtKeyEnableHWEncoder] = kCFBooleanFalse
                } else if !config.options.allowSoftware {
                    encInfo[VideoToolboxProperties.vtKeyRequireHWEncoder] = kCFBooleanTrue
                } else {
                    encInfo[VideoToolboxProperties.vtKeyEnableHWEncoder] = kCFBooleanTrue
                }

                // Low Latency
                if (config.options.flags & VideoToolboxConstants.AV_CODEC_FLAG_LOW_DELAY) != 0,
                   codec == .h264 || (codec == .hevc && isAppleSilicon()) {
                    if config.options.bitrate <= 0 {
                        throw VTRemotedError.protocolViolation("low_delay requires bitrate")
                    }
                    encInfo[VideoToolboxProperties.vtKeyLowLatencyRC] = kCFBooleanTrue
                }

                let pbInfo = NSMutableDictionary()
                pbInfo[kCVPixelBufferPixelFormatTypeKey] = NSNumber(value: cvPixelFormat)
                pbInfo[kCVPixelBufferWidthKey] = NSNumber(value: config.outputWidth)
                pbInfo[kCVPixelBufferHeightKey] = NSNumber(value: config.outputHeight)
                if let prim = mapColorPrimaries(config.options.colorPrimaries) {
                    pbInfo[kCVImageBufferColorPrimariesKey] = prim
                }
                if let trc = mapTransferFunction(config.options.colorTRC) {
                    pbInfo[kCVImageBufferTransferFunctionKey] = trc
                }
                if let mat = mapColorMatrix(config.options.colorSpace) {
                    pbInfo[kCVImageBufferYCbCrMatrixKey] = mat
                }

                var created: VTCompressionSession?
                let status = VTCompressionSessionCreate(
                    allocator: kCFAllocatorDefault,
                    width: Int32(config.outputWidth),
                    height: Int32(config.outputHeight),
                    codecType: codecType,
                    encoderSpecification: encInfo,
                    imageBufferAttributes: pbInfo,
                    compressedDataAllocator: nil,
                    outputCallback: { refCon, frameRefCon, status, infoFlags, sampleBuffer in
                        let session = Unmanaged<VideoToolboxCodecSession>.fromOpaque(refCon!).takeUnretainedValue()

                        // Native FFmpeg videotoolbox encoder assumes encoded output sample buffers are data-ready.
                        // Avoid dropping frames based on CMSampleBufferDataIsReady(), which can be false in edge
                        // cases even though the sample is valid and would become ready immediately.
                        if status == noErr, let sbuf = sampleBuffer {
                            let context = frameRefCon.map { Unmanaged<FrameContext>.fromOpaque($0).takeRetainedValue() }
                            session.handleEncodedSampleBuffer(sbuf, context: context)
                            return
                        }

                        // Frame dropped or error: still consume the retained FrameContext so we don't stall
                        // sequence-based reordering.
                        if let frameRefCon {
                            let context = Unmanaged<FrameContext>.fromOpaque(frameRefCon).takeRetainedValue()
                            session.handleEncodeFrameDropped(context: context, status: status, infoFlags: infoFlags)
                        }
                    },
                    refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                    compressionSessionOut: &created
                )
                guard status == noErr, let session = created else {
                    throw VTRemotedError.ioError(code: Int32(status), message: "VTCompressionSessionCreate failed")
                }

                try configureProperties(session: session, config: config, codec: codec)

                let preparation = VTCompressionSessionPrepareToEncodeFrames(session)
                guard preparation == noErr else {
                    throw VTRemotedError.ioError(code: Int32(preparation), message: "PrepareToEncodeFrames failed")
                }

                configureEncodeOutputOrdering(session: session, config: config)

                if logger.level.rawValue >= LogLevel.debug.rawValue {
                    dumpSessionProperties(session: session)
                }
                return session
            }

            // Warmup is required to obtain codec extradata for CONFIGURE_ACK, but encoding a warmup frame
            // on the real session can perturb GOP/keyframe cadence and (observed) HEVC correctness.
            // Run warmup on a throwaway session, then recreate a fresh session for actual encoding.
            let warmupSession = try makeSession()
            compressionSession = warmupSession
            try warmup()
            VTCompressionSessionInvalidate(warmupSession)
            compressionSession = nil

            let realSession = try makeSession()
            compressionSession = realSession

            // Ensure the first real frame is a clean keyframe.
            callbackLock.lock()
            forceKeyframeNext = true
            callbackLock.unlock()
        }

        private func configureProperties(
            session: VTCompressionSession,
            config: SessionConfiguration,
            codec: VideoCodec
        ) throws {
            var hasBFrames = config.options.maxBFrames > 0
            var entropy = config.options.entropy
            let profile = config.options.profile

            if codec == .h264 {
                if hasBFrames, (profile & 0xFF) == VideoToolboxConstants.AV_PROFILE_H264_BASELINE {
                    logger.info("WARN baseline profile cannot use B-frames; disabling")
                    hasBFrames = false
                }
                if entropy == 2, (profile & 0xFF) == VideoToolboxConstants.AV_PROFILE_H264_BASELINE {
                    logger.info("WARN CABAC requires main/high profile; disabling entropy override")
                    entropy = 0
                }
            }

            try configureBitrate(session: session, config: config, codec: codec)
            try configureFrameProperties(session: session, config: config)
            try configureColors(session: session, config: config)
            try configureProfileLevel(
                session: session,
                config: config,
                codec: codec,
                profile: profile,
                hasBFrames: hasBFrames
            )
            try configureH264(session: session, config: config, codec: codec, entropy: entropy)

            // Misc properties

            // Set expected frame rate to help VideoToolbox optimize encoding pipeline
            if config.frameRate.num > 0 && config.frameRate.den > 0 {
                var fps = Float(config.frameRate.num) / Float(config.frameRate.den)
                let fpsNum = CFNumberCreate(kCFAllocatorDefault, .floatType, &fps)
                try setProp(
                    session,
                    kVTCompressionPropertyKey_ExpectedFrameRate,
                    fpsNum!,
                    "expected_fps"
                )
            }

            // Realtime mode - match ffmpeg default (False)
            let isRealtime: CFBoolean
            if config.options.realtime >= 0 {
                isRealtime = config.options.realtime != 0 ? kCFBooleanTrue! : kCFBooleanFalse!
            } else {
                isRealtime = kCFBooleanFalse!
            }
            try setProp(session, kVTCompressionPropertyKey_RealTime, isRealtime, "realtime")

            // Power efficiency mode
            if config.options.powerEfficient >= 0 {
                let powerEfficient = config.options.powerEfficient != 0 ? kCFBooleanTrue! : kCFBooleanFalse!
                try setProp(
                    session,
                    VideoToolboxProperties.vtKeyMaximizePowerEfficiency,
                    powerEfficient,
                    "power_efficient"
                )
            } else {
                try setProp(
                    session,
                    VideoToolboxProperties.vtKeyMaximizePowerEfficiency,
                    kCFBooleanFalse,
                    "power_efficient"
                )
            }
            if config.options.maxReferenceFrames > 0 {
                var val = Int32(clamping: config.options.maxReferenceFrames)
                let num = CFNumberCreate(kCFAllocatorDefault, .intType, &val)
                // Keep parity with local FFmpeg VideoToolbox behavior: best-effort when unsupported.
                try setProp(
                    session,
                    VideoToolboxProperties.vtKeyReferenceBufferCount,
                    num!,
                    "max_ref_frames"
                )
            }
            if config.options.spatialAQ >= 0 {
                var val: Int32 = config.options.spatialAQ != 0 ?
                    VideoToolboxConstants.kVTQPModulationLevel_Default :
                    VideoToolboxConstants.kVTQPModulationLevel_Disable
                let num = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &val)
                try setProp(session, VideoToolboxProperties.vtKeySpatialAdaptiveQP, num!, "spatial_aq")
            }

            if codec == .hevc, config.options.alphaQuality > 0.0 {
                var alphaVal = config.options.alphaQuality
                let num = CFNumberCreate(kCFAllocatorDefault, .doubleType, &alphaVal)
                try setProp(session, VideoToolboxProperties.vtKeyTargetQualityForAlpha, num!, "alpha_quality")
            }

            // QMin/QMax
            if config.options.qmin >= 0 {
                var val = Int32(clamping: config.options.qmin)
                let num = CFNumberCreate(kCFAllocatorDefault, .intType, &val)
                try setProp(
                    session,
                    VideoToolboxProperties.vtKeyMinAllowedFrameQP,
                    num!,
                    "qmin",
                    fatal: true
                )
            }
            if config.options.qmax >= 0 {
                var val = Int32(clamping: config.options.qmax)
                let num = CFNumberCreate(kCFAllocatorDefault, .intType, &val)
                try setProp(
                    session,
                    VideoToolboxProperties.vtKeyMaxAllowedFrameQP,
                    num!,
                    "qmax",
                    fatal: true
                )
            }

            // Encoder ID log
            var value: CFTypeRef?
            let status = withUnsafeMutablePointer(to: &value) { ptr in
                VTSessionCopyProperty(session,
                                      key: VideoToolboxProperties.vtKeyEncoderID,
                                      allocator: kCFAllocatorDefault,
                                      valueOut: UnsafeMutableRawPointer(ptr))
            }
            if status == noErr, let encoderString = value as? String {
                logger.debug("EncoderID \(encoderString)")
            }
        }

        private func configureBitrate(
            session: VTCompressionSession,
            config: SessionConfiguration,
            codec: VideoCodec
        ) throws {
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
                try setProp(session, kVTCompressionPropertyKey_Quality, qualityNum!, "quality", fatal: true)
            } else if config.options.bitrate > 0 {
                var br32 = Int32(clamping: config.options.bitrate)
                let bitrate = CFNumberCreate(kCFAllocatorDefault,
                                             .sInt32Type,
                                             &br32)
                if config.options.constantBitRate {
                    let status = VTSessionSetProperty(session,
                                                      key: VideoToolboxProperties.vtKeyConstantBitRate,
                                                      value: bitrate)
                    if status == VideoToolboxProperties.kVTPropertyNotSupportedErr {
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

            // Prioritize encoding speed - only set if explicitly requested
            if config.options.prioritizeSpeed >= 0 {
                let shouldPrioritizeSpeed = config.options.prioritizeSpeed != 0
                try setProp(
                    session,
                    VideoToolboxProperties.vtKeyPrioritizeSpeed,
                    shouldPrioritizeSpeed ? kCFBooleanTrue : kCFBooleanFalse,
                    "prio_speed"
                )
            }

            if codec == .h264 || codec == .hevc, config.options.maxRate > 0 {
                let bytesPerSecond = Int64(config.options.maxRate >> 3)
                let oneSecond: Int64 = 1
                let arr = [NSNumber(value: bytesPerSecond), NSNumber(value: oneSecond)] as CFArray
                let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: arr)
                if status != noErr, codec != .hevc {
                    throw VTRemotedError.ioError(code: Int32(status), message: "set DataRateLimits failed")
                }
            }
        }

        private func configureFrameProperties(session: VTCompressionSession, config: SessionConfiguration) throws {
            // Respect max_b_frames by explicitly toggling frame reordering and delay.
            if config.options.maxBFrames >= 0 {
                let allowReorder = config.options.maxBFrames > 0
                try setProp(session,
                            kVTCompressionPropertyKey_AllowFrameReordering,
                            allowReorder ? kCFBooleanTrue! : kCFBooleanFalse!,
                            "allow_frame_reordering")
                var delay = Int32(clamping: max(0, config.options.maxBFrames))
                let num = CFNumberCreate(kCFAllocatorDefault, .intType, &delay)
                try setProp(session,
                            kVTCompressionPropertyKey_MaxFrameDelayCount,
                            num!,
                            "max_frame_delay")
            }

            if config.options.gop > 0 {
                var gopVal = Int32(clamping: config.options.gop)
                let gopNum = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &gopVal)
                try setProp(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, gopNum!, "gop", fatal: true)
            }

            if config.options.framesBefore {
                try setProp(session, kVTCompressionPropertyKey_MoreFramesBeforeStart, kCFBooleanTrue, "frames_before")
            }
            if config.options.framesAfter {
                try setProp(session, kVTCompressionPropertyKey_MoreFramesAfterEnd, kCFBooleanTrue, "frames_after")
            }

            if config.options.sarNum > 0, config.options.sarDen > 0 {
                let par = NSMutableDictionary()
                par[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing] = NSNumber(value: config.options.sarNum)
                par[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing] = NSNumber(value: config.options.sarDen)
                try setProp(session, kVTCompressionPropertyKey_PixelAspectRatio, par, "sar", fatal: true)
            }
        }

        private func configureColors(session: VTCompressionSession, config: SessionConfiguration) throws {
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
        }

        private func configureProfileLevel(
            session: VTCompressionSession,
            config: SessionConfiguration,
            codec: VideoCodec,
            profile: Int,
            hasBFrames: Bool
        ) throws {
            let profileLevel = try VideoToolboxProperties.profileLevelString(
                codec: codec,
                profile: profile,
                level: config.options.level,
                pixelFormat: config.pixelFormat,
                hasBFrames: hasBFrames
            )
            if let prof = profileLevel {
                try setProp(session, kVTCompressionPropertyKey_ProfileLevel, prof, "profile_level")
            }
        }

        private func configureH264(
            session: VTCompressionSession,
            config: SessionConfiguration,
            codec: VideoCodec,
            entropy: Int
        ) throws {
            if codec == .h264, entropy != 0 {
                let ent = entropy == 2
                    ? VideoToolboxProperties.vtH264EntropyCABAC
                    : VideoToolboxProperties.vtH264EntropyCAVLC
                try setProp(session, VideoToolboxProperties.vtKeyH264EntropyMode, ent, "entropy")
            }

            if (config.options.flags & VideoToolboxConstants.AV_CODEC_FLAG_CLOSED_GOP) != 0 {
                try setProp(session, VideoToolboxProperties.vtKeyAllowOpenGOP, kCFBooleanFalse, "closed_gop")
            }

            if config.options.maxSliceBytes >= 0, codec == .h264 {
                var val = Int32(clamping: config.options.maxSliceBytes)
                let num = CFNumberCreate(kCFAllocatorDefault, .intType, &val)
                try setProp(
                    session,
                    VideoToolboxProperties.vtKeyMaxH264SliceBytes,
                    num!,
                    "max_slice_bytes",
                    fatal: true
                )
            }
        }

        private func setProp(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef, 
                             _ name: String, fatal: Bool = false) throws {
            let status = VTSessionSetProperty(session,
                                              key: key,
                                              value: value)
            if status == VideoToolboxProperties.kVTPropertyNotSupportedErr {
                if fatal { throw VTRemotedError.ioError(code: Int32(status), message: "set \(name) failed") }
                logger.info("WARN \(name) not supported")
                return
            }
            if status != noErr {
                if fatal { throw VTRemotedError.ioError(code: Int32(status), message: "set \(name) failed") }
                logger.info("WARN set \(name) failed \(status)")
            }
        }

        private func copyCompressionProp(_ session: VTCompressionSession, key: CFString) -> (OSStatus, CFTypeRef?) {
            var value: CFTypeRef?
            let status = withUnsafeMutablePointer(to: &value) { ptr in
                VTSessionCopyProperty(session,
                                      key: key,
                                      allocator: kCFAllocatorDefault,
                                      valueOut: UnsafeMutableRawPointer(ptr))
            }
            return (status, value)
        }

        private func boolCompressionProp(_ session: VTCompressionSession, key: CFString) -> Bool? {
            let (status, value) = copyCompressionProp(session, key: key)
            guard status == noErr, let value else { return nil }
            if let boolValue = value as? Bool { return boolValue }
            if let numberValue = value as? NSNumber { return numberValue.boolValue }
            return nil
        }

        private func intCompressionProp(_ session: VTCompressionSession, key: CFString) -> Int? {
            let (status, value) = copyCompressionProp(session, key: key)
            guard status == noErr, let value else { return nil }
            if let numberValue = value as? NSNumber { return numberValue.intValue }
            if let stringValue = value as? String { return Int(stringValue) }
            return nil
        }

        private func configureEncodeOutputOrdering(session: VTCompressionSession, config: SessionConfiguration) {
            // Prefer the encoder's reported properties when available, falling back to requested values.
            let reportedAllowReorder = boolCompressionProp(session, key: kVTCompressionPropertyKey_AllowFrameReordering)
            let reportedDelay = intCompressionProp(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount)

            let requestedDelay = max(0, config.options.maxBFrames)
            let allowReorder = reportedAllowReorder ?? (requestedDelay > 0)
            let frameDelay = max(0, reportedDelay ?? requestedDelay)

            let useDtsReorder = allowReorder || frameDelay > 0
            let useSeqReorder = !useDtsReorder

            callbackLock.lock()
            encodeReorderBySeq = useSeqReorder
            encodeSeqExpected = 0
            encodePendingPackets.removeAll(keepingCapacity: true)
            encodeDroppedSeqs.removeAll(keepingCapacity: true)

            encodeDtsReorderBuffer = nil
            encodeDtsReorderDepth = 0
            if useDtsReorder {
                encodeDtsReorderDepth = min(64, max(2, frameDelay))
                encodeDtsReorderBuffer = EncodeReorderBuffer(depth: encodeDtsReorderDepth)
            }

            // If we already observed a nominal duration, (re)compute the DTS shift now.
            if useDtsReorder, nominalFrameDurTicks > 0 {
                // Add a small cushion to cover mixed 41/42ms timecode patterns (e.g. 24000/1001 into 1/1000).
                encodeDtsOffsetTicks = Int64(encodeDtsReorderDepth + 1) * nominalFrameDurTicks
                logger.info(
                    "ENCODE dts_offset_ticks=\(encodeDtsOffsetTicks) " +
                        "(depth=\(encodeDtsReorderDepth) dur_ticks=\(nominalFrameDurTicks))"
                )
            } else {
                encodeDtsOffsetTicks = 0
            }
            callbackLock.unlock()

            timestampTracker.reset(enforceMonotonicPts: useSeqReorder)

            let allowStr = reportedAllowReorder.map { $0 ? "1" : "0" } ?? "?"
            let delayStr = reportedDelay.map { String($0) } ?? "?"
            if useSeqReorder {
                logger.info("ENCODE ordering=seq allow_reorder=\(allowStr) max_delay=\(delayStr)")
            } else {
                if requestedDelay == 0 {
                    logger.info(
                        "WARN VT frame reordering enabled (allow_reorder=\(allowStr) max_delay=\(delayStr)) " +
                            "even though max_b_frames=0; emitting in DTS order"
                    )
                }
                logger.info(
                    "ENCODE ordering=dts depth=\(encodeDtsReorderDepth) allow_reorder=\(allowStr) max_delay=\(delayStr)"
                )
            }
        }
        
        private func dumpSessionProperties(session: VTCompressionSession) {
            var supported: CFDictionary?
            let supStatus = VTSessionCopySupportedPropertyDictionary(
                session,
                supportedPropertyDictionaryOut: &supported
            )
            if supStatus != noErr {
                logger.debug("VT supported properties unavailable status=\(supStatus)")
            }
            let supportedDict = supported as NSDictionary?

            func describe(_ value: CFTypeRef?) -> String {
                guard let value else { return "nil" }
                return CFCopyDescription(value) as String
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

            func logProp(_ name: String, _ key: CFString) {
                let supportedStr = (supportedDict?[key] != nil) ? "supported" : "unknown"
                let (status, val) = copyProp(key)
                if status == noErr {
                    logger.debug("VT prop \(name) (\(supportedStr)) = \(describe(val))")
                } else if status == VideoToolboxProperties.kVTPropertyNotSupportedErr {
                    logger.debug("VT prop \(name) (\(supportedStr)) = not supported")
                } else {
                    logger.debug("VT prop \(name) (\(supportedStr)) read failed \(status)")
                }
            }

            logger.debug("VT property dump post-PrepareToEncodeFrames")
            logProp("AverageBitRate", kVTCompressionPropertyKey_AverageBitRate)
            logProp("DataRateLimits", kVTCompressionPropertyKey_DataRateLimits)
            logProp("ConstantBitRate", VideoToolboxProperties.vtKeyConstantBitRate)
            logProp("Quality", kVTCompressionPropertyKey_Quality)
            logProp("MaxKeyFrameInterval", kVTCompressionPropertyKey_MaxKeyFrameInterval)
            logProp("AllowFrameReordering", kVTCompressionPropertyKey_AllowFrameReordering)
            logProp("ProfileLevel", kVTCompressionPropertyKey_ProfileLevel)
            logProp("RealTime", kVTCompressionPropertyKey_RealTime)
            logProp("MinAllowedFrameQP", VideoToolboxProperties.vtKeyMinAllowedFrameQP)
            logProp("MaxAllowedFrameQP", VideoToolboxProperties.vtKeyMaxAllowedFrameQP)
            logProp("MaxH264SliceBytes", VideoToolboxProperties.vtKeyMaxH264SliceBytes)
            logProp("H264EntropyMode", VideoToolboxProperties.vtKeyH264EntropyMode)
            logProp("AllowOpenGOP", VideoToolboxProperties.vtKeyAllowOpenGOP)
            logProp("MaximizePowerEfficiency", VideoToolboxProperties.vtKeyMaximizePowerEfficiency)
            logProp("SpatialAdaptiveQP", VideoToolboxProperties.vtKeySpatialAdaptiveQP)
            logProp("ReferenceBufferCount", VideoToolboxProperties.vtKeyReferenceBufferCount)
        }

        private func handleEncodeFrameDropped(context: FrameContext, status: OSStatus, infoFlags: VTEncodeInfoFlags) {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            if context.isWarmup {
                logger.error("warmup encode dropped status=\(status) infoFlags=\(infoFlags.rawValue)")
                forceKeyframeNext = true
                warmupSemaphore.signal()
                return
            }
            let seq = context.seq
            if status != noErr {
                logger.error("encode output callback error seq=\(seq) status=\(status) infoFlags=\(infoFlags.rawValue)")
            } else {
                logger.info("WARN encode frame dropped seq=\(seq) infoFlags=\(infoFlags.rawValue)")
            }

            // Only seq-order the no-reorder (max_b_frames == 0) mode.
            guard encodeReorderBySeq else { return }

            if seq < encodeSeqExpected {
                logger.info("WARN dropped encode frame seq=\(seq) already past expected=\(encodeSeqExpected)")
                return
            }

            encodeDroppedSeqs.insert(seq)
            drainEncodePacketsLocked()
        }

        private func emitEncodedPacketLocked(_ pkt: PendingEncodedPacket) {
            guard config != nil else { return }

            let ptsTicks = pkt.ptsTicks
            var dtsTicks = pkt.dtsTicks

            // If we're in DTS-reorder mode, shift DTS earlier by a fixed amount so that dts <= pts.
            // This prevents FFmpeg muxers from rewriting timestamps (which causes jitter and duplicate PTS).
            if !encodeReorderBySeq && encodeDtsOffsetTicks > 0 && dtsTicks != Self.noPtsTicks {
                let (shifted, overflow) = dtsTicks.subtractingReportingOverflow(encodeDtsOffsetTicks)
                if !overflow {
                    dtsTicks = shifted
                }
            }

            let result = timestampTracker.process(ptsTicks: ptsTicks, dtsTicks: dtsTicks)
            let adjustedPtsTicks: Int64
            let adjustedDtsTicks: Int64
            switch result {
            case .emit(let ptsValue, let dtsValue, _):
                adjustedPtsTicks = ptsValue
                adjustedDtsTicks = dtsValue
            }

            var meta = ByteWriter(reserveCapacity: 32)
            meta.writeBE(UInt64(bitPattern: adjustedPtsTicks))
            meta.writeBE(UInt64(bitPattern: adjustedDtsTicks))
            meta.writeBE(UInt64(bitPattern: pkt.durTicks))
            meta.writeBE(UInt32(pkt.isKey ? 1 : 0))
            meta.writeBE(UInt32(pkt.annex.count))

            do {
                // Avoid copying potentially large Annex-B payload into the meta buffer.
                let sideDataBlob = Self.writeWireSideData(pkt.sideData)
                if sideDataBlob.isEmpty {
                    try send(.packet, [meta.data, pkt.annex])
                } else {
                    try send(.packet, [meta.data, pkt.annex, sideDataBlob])
                }
            } catch {
                logger.error("send packet failed: \(error)")
            }
        }

        private func drainEncodePacketsLocked() {
            while true {
                if encodeDroppedSeqs.remove(encodeSeqExpected) != nil {
                    encodeSeqExpected &+= 1
                    continue
                }
                guard let pkt = encodePendingPackets.removeValue(forKey: encodeSeqExpected) else {
                    break
                }
                emitEncodedPacketLocked(pkt)
                encodeSeqExpected &+= 1
            }
        }

        private func handleEncodedSampleBuffer(_ sbuf: CMSampleBuffer, context: FrameContext?) {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            guard let config else { return }

            // Capture extradata once.
            if encoderExtradata == nil, let fmt = CMSampleBufferGetFormatDescription(sbuf) {
                let atom = (encoderCodec == .hevc) ? "hvcC" : "avcC"
                if let data = sampleDescriptionAtom(fmt, atom: atom) {
                    let stripped = AnnexB.stripAtomHeaderIfPresent(data, fourCC: atom)
                    encoderExtradata = stripped
                    if encoderCodec == .h264, stripped.count > 4 {
                        nalLengthField = Int((stripped[4] & 0x3) + 1)
                    } else if encoderCodec == .hevc, stripped.count > 21 {
                        nalLengthField = Int((stripped[21] & 0x3) + 1)
                    }
                    if !(1 ... 4).contains(nalLengthField) {
                        logger.info("WARN invalid nalLengthField=\(nalLengthField); defaulting to 4")
                        nalLengthField = 4
                    }
                }
            }

            // Warmup discard: drop warmup output (but keep any captured extradata) and force a clean keyframe
            // on the next real frame.
            if let context, context.isWarmup {
                forceKeyframeNext = true
                warmupSemaphore.signal()
                return
            }

            if !CMSampleBufferDataIsReady(sbuf) {
                let makeStatus = CMSampleBufferMakeDataReady(sbuf)
                if makeStatus != noErr {
                    logger.error("encode sample buffer not ready; MakeDataReady failed status=\(makeStatus)")
                    if encodeReorderBySeq, let context {
                        encodeDroppedSeqs.insert(context.seq)
                        drainEncodePacketsLocked()
                    }
                    return
                }
            }
            guard let block = CMSampleBufferGetDataBuffer(sbuf) else {
                logger.error("encode sample buffer missing CMBlockBuffer")
                if encodeReorderBySeq, let context {
                    encodeDroppedSeqs.insert(context.seq)
                    drainEncodePacketsLocked()
                }
                return
            }

            // Important: use the sample's total size, not the underlying CMBlockBuffer length.
            // CMBlockBufferGetDataLength() can include trailing bytes beyond the sample payload.
            let sampleLen = CMSampleBufferGetTotalSampleSize(sbuf)
            let annex = convertToAnnexB(block: block, sampleLen: sampleLen, nalLengthField: nalLengthField)
            if annex.isEmpty {
                logger.error("encode produced empty Annex-B payload (sampleLen=\(sampleLen))")
                if encodeReorderBySeq, let context {
                    encodeDroppedSeqs.insert(context.seq)
                    drainEncodePacketsLocked()
                }
                return
            }

            let pts = sbuf.presentationTimeStamp
            let ptsTicks = ticksOrNoPts(from: pts, timebase: config.timebase)

            // Get DTS from VideoToolbox, falling back to PTS when invalid (common when B-frames disabled).
            let rawDts = CMSampleBufferGetDecodeTimeStamp(sbuf)
            let rawDtsTicks: Int64
            if rawDts.isValid && rawDts.isNumeric {
                rawDtsTicks = ticksOrNoPts(from: rawDts, timebase: config.timebase)
            } else if ptsTicks != Self.noPtsTicks {
                rawDtsTicks = ptsTicks
            } else {
                rawDtsTicks = Self.noPtsTicks
            }

            let dur = sbuf.duration.isNumeric ? sbuf.duration : .invalid
            let durTicks = dur.isNumeric ?
                config.timebase.ticks(from: RationalTime(value: dur.value, timescale: dur.timescale)) : 0

            if nominalFrameDurTicks == 0 && durTicks > 0 {
                nominalFrameDurTicks = durTicks
                if !encodeReorderBySeq && encodeDtsReorderDepth > 0 {
                    // Add a small cushion to cover mixed timecode patterns.
                    encodeDtsOffsetTicks = Int64(encodeDtsReorderDepth + 1) * nominalFrameDurTicks
                    logger.info(
                        "ENCODE observed dur_ticks=\(nominalFrameDurTicks); " +
                            "dts_offset_ticks=\(encodeDtsOffsetTicks) (depth=\(encodeDtsReorderDepth))"
                    )
                }
            }

            let attachments = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false)
            let isKey = (attachments as? [[NSObject: Any]])?.first?[kCMSampleAttachmentKey_NotSync as NSObject] == nil

            let pkt = PendingEncodedPacket(
                ptsTicks: ptsTicks,
                dtsTicks: rawDtsTicks,
                durTicks: durTicks,
                isKey: isKey,
                annex: annex,
                sideData: context?.sideData ?? []
            )

            if encodeReorderBySeq {
                guard let context else {
                    logger.error("encode packet missing context in seq-reorder mode")
                    emitEncodedPacketLocked(pkt)
                    return
                }
                let seq = context.seq
                if seq < encodeSeqExpected {
                    logger.info("WARN late encode packet seq=\(seq) expected=\(encodeSeqExpected); dropping")
                    return
                }
                if encodeDroppedSeqs.contains(seq) {
                    logger.info("WARN encode packet arrived after drop seq=\(seq); dropping")
                    return
                }
                if encodePendingPackets[seq] != nil {
                    logger.info("WARN duplicate encode packet seq=\(seq); dropping")
                    return
                }
                encodePendingPackets[seq] = pkt
                drainEncodePacketsLocked()
                return
            }

            if let reorder = encodeDtsReorderBuffer {
                guard let context else {
                    logger.error("encode packet missing context in dts-reorder mode")
                    emitEncodedPacketLocked(pkt)
                    return
                }
                let seq = context.seq
                let toEmit = reorder.enqueue(dtsTicks: pkt.dtsTicks, seq: seq, payload: pkt)
                for pkt in toEmit {
                    emitEncodedPacketLocked(pkt)
                }
                return
            }

            emitEncodedPacketLocked(pkt)
        }

        private func convertToAnnexB(block: CMBlockBuffer, sampleLen: Int, nalLengthField: Int) -> Data {
            let totalLen = max(0, min(sampleLen, CMBlockBufferGetDataLength(block)))
            if totalLen == 0 { return Data() }

            var data = Data(count: totalLen)
            let copyStatus: OSStatus = data.withUnsafeMutableBytes { ptr in
                guard let dst = ptr.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: totalLen, destination: dst)
            }
            if copyStatus != noErr {
                logger.error("CMBlockBufferCopyDataBytes failed status=\(copyStatus)")
                return Data()
            }

            func containsStartCode(_ data: Data) -> Bool {
                // Conservative scan for Annex-B start codes anywhere in the buffer.
                data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
                    if totalLen < 3 { return false }
                    var scanIndex = 0
                    while scanIndex + 3 < totalLen {
                        if base[scanIndex] == 0 && base[scanIndex + 1] == 0 {
                            if base[scanIndex + 2] == 1 { return true }
                            if base[scanIndex + 2] == 0 && base[scanIndex + 3] == 1 { return true }
                        }
                        scanIndex += 1
                    }
                    return false
                }
            }

            func validateLengthPrefixed() -> (end: Int, annexSize: Int)? {
                guard (1 ... 4).contains(nalLengthField) else { return nil }
                var index = 0
                var end = 0
                var annexSize = 0
                var valid = true
                data.withUnsafeBytes { inPtr in
                    guard let inBase = inPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        valid = false
                        return
                    }
                    while index + nalLengthField <= totalLen {
                        var len: UInt32 = 0
                        for idx in 0 ..< nalLengthField {
                            len = (len << 8) | UInt32(inBase[index + idx])
                        }
                        if len == 0 {
                            break
                        }
                        let next = index + nalLengthField + Int(len)
                        if next > totalLen {
                            valid = false
                            break
                        }
                        annexSize += 4 + Int(len)
                        index = next
                        end = index
                    }
                    if valid, index < totalLen {
                        for byteIndex in index ..< totalLen where inBase[byteIndex] != 0 {
                            valid = false
                            break
                        }
                    }
                }
                guard valid, end > 0 else { return nil }
                return (end: end, annexSize: annexSize)
            }

            func buildAnnexB(end: Int, annexSize: Int) -> Data {
                var annex = Data(count: annexSize)
                var index = 0
                var outIdx = 0
                annex.withUnsafeMutableBytes { outPtr in
                    guard let outBase = outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    data.withUnsafeBytes { inPtr in
                        guard let inBase = inPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                        while index + nalLengthField <= end {
                            var len: UInt32 = 0
                            for idx in 0 ..< nalLengthField {
                                len = (len << 8) | UInt32(inBase[index + idx])
                            }
                            if len == 0 { break }
                            let next = index + nalLengthField + Int(len)
                            if next > end { break }

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

            if let validated = validateLengthPrefixed() {
                // Trim any trailing zero padding before emitting.
                if validated.end < data.count {
                    data.count = validated.end
                }

                if nalLengthField == 4 {
                    // Fast path: replace length headers with start codes in-place.
                    let effectiveLen = validated.end
                    var index = 0
                    data.withUnsafeMutableBytes { ptr in
                        guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                        while index + 4 <= effectiveLen {
                            let len: UInt32 =
                                (UInt32(base[index]) << 24) |
                                    (UInt32(base[index + 1]) << 16) |
                                    (UInt32(base[index + 2]) << 8) |
                                    UInt32(base[index + 3])
                            base[index] = 0
                            base[index + 1] = 0
                            base[index + 2] = 0
                            base[index + 3] = 1
                            index += 4 + Int(len)
                        }
                    }
                    return data
                }

                return buildAnnexB(end: validated.end, annexSize: validated.annexSize)
            }

            // Not valid length-prefixed: if it already looks like Annex-B, pass through.
            if containsStartCode(data) {
                return data
            }
            return Data()
        }

        private func warmup() throws {
            guard let session = compressionSession, let config else { return }
            logger.debug("warmup start")

            // Prefer allocating from the session's pool so pixel buffers have the expected attachments.
            var buffer: CVPixelBuffer?
            if let pool = VTCompressionSessionGetPixelBufferPool(session) {
                _ = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            }
            if buffer == nil {
                let createStatus = CVPixelBufferCreate(
                    kCFAllocatorDefault,
                    config.outputWidth,
                    config.outputHeight,
                    cvPixelFormat,
                    nil,
                    &buffer
                )
                guard createStatus == kCVReturnSuccess else {
                    logger.error("warmup CVPixelBufferCreate failed status=\(createStatus)")
                    return
                }
            }
            guard let pixelBuffer = buffer else { return }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
            if planeCount > 0 {
                for plane in 0 ..< planeCount {
                    guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { continue }
                    let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                    let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
                    memset(base, 0, max(0, bytesPerRow * height))
                }
            } else if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, 0, CVPixelBufferGetDataSize(pixelBuffer))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            // Avoid PTS collision with the first real frame (often PTS=0). Some encoders appear to get
            // confused when the session sees two frames with identical PTS at the start.
            let duration = cmTime(fromTicks: 1, timebase: config.timebase)
            let presentationCandidates = [
                cmTime(fromTicks: -1, timebase: config.timebase),
                cmTime(fromTicks: 0, timebase: config.timebase)
            ]

            var lastStatus: OSStatus = noErr
            var lastInfoFlags = VTEncodeInfoFlags()
            var warmupSubmitted = false

            for (idx, pts) in presentationCandidates.enumerated() {
                let warmupContext = FrameContext(seq: UInt64.max, isWarmup: true)
                let ctxPtr = Unmanaged.passRetained(warmupContext).toOpaque()

                var infoFlags = VTEncodeInfoFlags()
                let encodeStatus = VTCompressionSessionEncodeFrame(
                    session,
                    imageBuffer: pixelBuffer,
                    presentationTimeStamp: pts,
                    duration: duration,
                    frameProperties: nil,
                    sourceFrameRefcon: ctxPtr,
                    infoFlagsOut: &infoFlags
                )
                if encodeStatus == noErr {
                    warmupSubmitted = true
                    break
                }

                Unmanaged<FrameContext>.fromOpaque(ctxPtr).release()
                lastStatus = encodeStatus
                lastInfoFlags = infoFlags
                logger.error(
                    "warmup VTCompressionSessionEncodeFrame failed attempt=\(idx) status=\(encodeStatus) " +
                        "infoFlags=\(infoFlags.rawValue)"
                )
            }

            if !warmupSubmitted {
                throw VTRemotedError.ioError(
                    code: Int32(lastStatus),
                    message: "warmup encode failed status=\(lastStatus) infoFlags=\(lastInfoFlags.rawValue)"
                )
            }

            if warmupSemaphore.wait(timeout: .now() + 5.0) == .timedOut {
                logger.error("warmup timed out waiting for encoder output")
                throw VTRemotedError.ioError(code: -1, message: "warmup timed out")
            }
            logger.debug("warmup done")
        }

        private func makeDecodedFrameMeta(ptsTicks: Int64, durTicks: Int64) -> Data {
            var meta = ByteWriter()
            meta.writeBE(UInt64(bitPattern: ptsTicks))
            meta.writeBE(UInt64(bitPattern: durTicks))
            meta.writeBE(UInt32(0))
            meta.write(UInt8(2))
            return meta.data
        }

        private func sendDecodedFrames(_ frames: [ReorderedDecodedFrame<[Data]>]) {
            for frame in frames {
                var chunks = frame.payload
                if frame.clamped {
                    logger.info(
                        "WARN decode async late frame pts=\(frame.originalPtsTicks) " +
                            "clamped=\(frame.ptsTicks) depth=\(decodeReorderDepth)"
                    )
                    if !chunks.isEmpty {
                        chunks[0] = makeDecodedFrameMeta(ptsTicks: frame.ptsTicks, durTicks: frame.durTicks)
                    }
                }
                do {
                    try send(.frame, chunks)
                } catch {
                    logger.error("send frame failed: \(error)")
                }
            }
        }

        private func enqueueDecodedFrame(ptsTicks: Int64, durTicks: Int64, chunks: [Data]) {
            callbackLock.lock()
            let frames: [ReorderedDecodedFrame<[Data]>]
            if !decodeAsyncEnabled {
                let frame = ReorderedDecodedFrame(originalPtsTicks: ptsTicks,
                                                  ptsTicks: ptsTicks,
                                                  durTicks: durTicks,
                                                  payload: chunks,
                                                  clamped: false)
                frames = [frame]
            } else {
                if decodeReorderBuffer == nil {
                    decodeReorderBuffer = DecodeReorderBuffer(depth: decodeReorderDepth)
                }
                frames = decodeReorderBuffer?.enqueue(ptsTicks: ptsTicks, durTicks: durTicks, payload: chunks) ?? []
            }
            callbackLock.unlock()
            sendDecodedFrames(frames)
        }

        private func encodeTranscodeFrames(_ frames: [ReorderedDecodedFrame<TranscodeFramePayload>]) {
            guard let config else { return }
            for frame in frames {
                let pts = cmTimeOrInvalid(fromTicks: frame.ptsTicks, timebase: config.timebase)
                let duration: CMTime
                if frame.durTicks > 0 {
                    duration = cmTime(fromTicks: frame.durTicks, timebase: config.timebase)
                } else {
                    duration = .invalid
                }
                guard let outputBuffer = prepareTranscodePixelBuffer(frame.payload.pixelBuffer, config: config) else {
                    continue
                }
                encodePixelBuffer(
                    outputBuffer,
                    pts: pts,
                    duration: duration,
                    sideData: frame.payload.sideData
                )
            }
        }

        private func enqueueTranscodeFrame(pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
            guard let config else { return }
            let ptsTicks = ticksOrNoPts(from: pts, timebase: config.timebase)
            let durTicks: Int64 = if duration.isNumeric {
                config.timebase.ticks(from: RationalTime(value: duration.value, timescale: duration.timescale))
            } else {
                0
            }
            let sideData = takePendingDecodeSideData(ptsTicks: ptsTicks)
            let payload = TranscodeFramePayload(pixelBuffer: pixelBuffer, durTicks: durTicks, sideData: sideData)

            callbackLock.lock()
            let frames: [ReorderedDecodedFrame<TranscodeFramePayload>]
            if !decodeAsyncEnabled {
                let frame = ReorderedDecodedFrame(originalPtsTicks: ptsTicks,
                                                  ptsTicks: ptsTicks,
                                                  durTicks: durTicks,
                                                  payload: payload,
                                                  clamped: false)
                frames = [frame]
            } else {
                if transcodeReorderBuffer == nil {
                    transcodeReorderBuffer = DecodeReorderBuffer(depth: decodeReorderDepth)
                }
                frames = transcodeReorderBuffer?.enqueue(ptsTicks: ptsTicks, durTicks: durTicks, payload: payload) ?? []
            }
            callbackLock.unlock()
            encodeTranscodeFrames(frames)
        }

        private func flushDecodedFrames() {
            guard decodeAsyncEnabled else { return }
            if config?.mode == .transcode {
                callbackLock.lock()
                let frames = transcodeReorderBuffer?.flush() ?? []
                callbackLock.unlock()
                encodeTranscodeFrames(frames)
                return
            }
            callbackLock.lock()
            let frames = decodeReorderBuffer?.flush() ?? []
            callbackLock.unlock()
            sendDecodedFrames(frames)
        }

        private func setupTranscodeTransfer(_ config: SessionConfiguration) {
            transcodeOutputWidth = config.outputWidth
            transcodeOutputHeight = config.outputHeight
            transcodeNeedsTransfer = config.outputWidth != config.width || config.outputHeight != config.height
            if let session = compressionSession {
                transcodeOutputPool = VTCompressionSessionGetPixelBufferPool(session)
            }
            if transcodeNeedsTransfer {
                _ = ensureTranscodeTransferSession(config)
            }
        }

        private func ensureTranscodeTransferSession(_ config: SessionConfiguration) -> VTPixelTransferSession? {
            if let session = transcodeTransferSession {
                return session
            }
            var transfer: VTPixelTransferSession?
            let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault,
                                                     pixelTransferSessionOut: &transfer)
            guard status == noErr, let session = transfer else {
                logger.error("VTPixelTransferSessionCreate failed: \(status)")
                return nil
            }
            transcodeTransferSession = session

            let mode: CFString
            switch config.scaleMode {
            case .stretch:
                mode = kVTScalingMode_Normal
            case .aspect:
                mode = kVTScalingMode_Letterbox
            case .aspectFill:
                mode = kVTScalingMode_Trim
            }
            _ = VTSessionSetProperty(session,
                                     key: kVTPixelTransferPropertyKey_ScalingMode,
                                     value: mode)
            return session
        }

        private func prepareTranscodePixelBuffer(
            _ pixelBuffer: CVPixelBuffer,
            config: SessionConfiguration
        ) -> CVPixelBuffer? {
            let inputWidth = CVPixelBufferGetWidth(pixelBuffer)
            let inputHeight = CVPixelBufferGetHeight(pixelBuffer)
            let inputFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let needsTransfer = transcodeNeedsTransfer ||
                inputWidth != config.outputWidth ||
                inputHeight != config.outputHeight ||
                inputFormat != cvPixelFormat
            if !needsTransfer {
                return pixelBuffer
            }

            guard let transfer = ensureTranscodeTransferSession(config) else {
                return nil
            }
            guard let outputBuffer = makeTranscodeOutputPixelBuffer(width: config.outputWidth,
                                                                    height: config.outputHeight) else {
                return nil
            }
            let status = VTPixelTransferSessionTransferImage(transfer,
                                                             from: pixelBuffer,
                                                             to: outputBuffer)
            guard status == noErr else {
                logger.error("VTPixelTransferSessionTransferImage failed: \(status)")
                return nil
            }
            return outputBuffer
        }

        private func makeTranscodeOutputPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
            var pixelBuffer: CVPixelBuffer?
            if let pool = transcodeOutputPool {
                let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
                if status == kCVReturnSuccess, let buffer = pixelBuffer {
                    return buffer
                }
            }

            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: cvPixelFormat,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ]
            let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                             width,
                                             height,
                                             cvPixelFormat,
                                             attrs as CFDictionary,
                                             &pixelBuffer)
            guard status == kCVReturnSuccess else {
                logger.error("CVPixelBufferCreate failed: \(status)")
                return nil
            }
            return pixelBuffer
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
            
            // Apply RealTime property
            let isRealtime: CFBoolean
            if config.options.realtime >= 0 {
                isRealtime = (config.options.realtime != 0) ? kCFBooleanTrue! : kCFBooleanFalse!
            } else {
                isRealtime = kCFBooleanFalse!
            }
            _ = VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: isRealtime)
            
            decompressionSession = session
        }

        private func handleDecodedFrame(pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
            guard let config else { return }
            if config.mode == .transcode {
                enqueueTranscodeFrame(pixelBuffer: pixelBuffer, pts: pts, duration: duration)
                return
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return }

            let ptsTicks = ticksOrNoPts(from: pts, timebase: config.timebase)
            let durTicks: Int64 = if duration.isNumeric {
                config.timebase.ticks(from: RationalTime(value: duration.value, timescale: duration.timescale))
            } else {
                0
            }
            let sideData = takePendingDecodeSideData(ptsTicks: ptsTicks)

            var chunks: [Data] = []
            chunks.reserveCapacity(sideData.isEmpty ? 5 : 6)
            chunks.append(makeDecodedFrameMeta(ptsTicks: ptsTicks, durTicks: durTicks))

            struct PlaneResult {
                let meta: Data
                let data: Data
            }

            let compressionErrorMessage = config.options.wireCompression == 1 ?
                "lz4 compress failed" : "zstd compress failed"

            let makePlaneResult: (Int) -> PlaneResult? = { plane in
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
                let len = stride * height

                var planeMeta = ByteWriter()
                planeMeta.writeBE(UInt32(stride))
                planeMeta.writeBE(UInt32(height))
                
                // Always copy to system memory first to avoid reading from WC memory during compression
                var raw = self.outputBufferPool.get(capacity: len)
                defer { self.outputBufferPool.return(raw) }
                
                if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane), len > 0 {
                    raw.count = len
                    raw.withUnsafeMutableBytes { dstPtr in
                        guard let dst = dstPtr.baseAddress else { return }
                        _ = memcpy(dst, base, len)
                    }
                } else {
                    raw.count = len
                }
                
                guard let compressed = Self.compressWirePayload(
                    mode: config.options.wireCompression,
                    data: raw
                ) else {
                    return nil
                }
                
                planeMeta.writeBE(UInt32(compressed.count))
                return PlaneResult(meta: planeMeta.data, data: compressed)
            }

            var results = [PlaneResult?](repeating: nil, count: 2)
            var error: Error?

            let totalPlaneBytes =
                CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) * CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
                + CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) * CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            let serialCompressionThresholdBytes = 256 * 1024

            if totalPlaneBytes <= serialCompressionThresholdBytes {
                for plane in 0..<2 {
                    guard let res = makePlaneResult(plane) else {
                        error = VTRemotedError.protocolViolation(compressionErrorMessage)
                        break
                    }
                    results[plane] = res
                }
            } else {
                let resultLock = NSLock()
                DispatchQueue.concurrentPerform(iterations: 2) { plane in
                    guard let res = makePlaneResult(plane) else {
                        resultLock.lock()
                        if error == nil {
                            error = VTRemotedError.protocolViolation(compressionErrorMessage)
                        }
                        resultLock.unlock()
                        return
                    }

                    resultLock.lock()
                    results[plane] = res
                    resultLock.unlock()
                }
            }
            
            if let err = error {
                logger.error("encode frame failed: \(err)")
                return
            }

            guard let res0 = results[0], let res1 = results[1] else { return }
            chunks.append(res0.meta)
            chunks.append(res0.data)
            chunks.append(res1.meta)
            chunks.append(res1.data)
            let sideDataBlob = Self.writeWireSideData(sideData)
            if !sideDataBlob.isEmpty {
                chunks.append(sideDataBlob)
            }

            enqueueDecodedFrame(ptsTicks: ptsTicks, durTicks: durTicks, chunks: chunks)
        }

        // MARK: - Helpers

        private func pickCVPixelFormat(pixelFormat: UInt8) throws -> OSType {
            switch pixelFormat {
            case VTRPixelFormat.nv12:
                return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            case VTRPixelFormat.p010:
                return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            case VTRPixelFormat.bgra:
                return kCVPixelFormatType_32BGRA
            case VTRPixelFormat.ayuv:
                return kCVPixelFormatType_4444AYpCbCr8
            case VTRPixelFormat.p210:
                return kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            default:
                throw VTRemotedError.unsupported("pix_fmt=\(pixelFormat)(\(VTRPixelFormat.name(pixelFormat)))")
            }
        }

        private func isAppleSilicon() -> Bool {
            #if arch(arm64)
                return true
            #else
                return false
            #endif
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

        private func cmTimeOrInvalid(fromTicks ticks: Int64, timebase: Timebase) -> CMTime {
            if ticks == Self.noPtsTicks { return .invalid }
            return cmTime(fromTicks: ticks, timebase: timebase)
        }

        private func ticksOrNoPts(from time: CMTime, timebase: Timebase) -> Int64 {
            guard time.isValid && time.isNumeric else { return Self.noPtsTicks }
            return timebase.ticks(from: RationalTime(value: time.value, timescale: time.timescale))
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
