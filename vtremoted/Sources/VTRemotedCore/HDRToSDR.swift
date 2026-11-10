import Foundation

struct HDRToSDRSettings: Sendable {
    let sourceTransfer: Int
    let sourcePeakNits: Double?

    init?(codec: VideoCodec, mode: SessionMode, pixelFormat: UInt8,
          options: [String: String]) throws {
        let enabled = options["hdr_to_sdr"] ?? "0"
        guard enabled == "0" || enabled == "1" else {
            throw VTRemotedError.unsupported("hdr_to_sdr must be 0 or 1")
        }
        guard enabled == "1" else { return nil }
        guard mode == .transcode, codec == .hevc,
              pixelFormat == VTRPixelFormat.nv12 || pixelFormat == VTRPixelFormat.p010 else {
            throw VTRemotedError.unsupported("HDR-to-SDR requires HEVC transcode with NV12 or P010 output")
        }
        guard let transfer = Int(options["hdr_source_transfer"] ?? ""), transfer == 16 || transfer == 18 else {
            throw VTRemotedError.unsupported("HDR-to-SDR requires BT.2020 PQ or HLG input")
        }
        sourceTransfer = transfer
        if let raw = options["hdr_source_peak"] {
            guard let peak = Double(raw), peak.isFinite, peak > 0, peak <= 10000 else {
                throw VTRemotedError.unsupported("HDR source peak must be in (0, 10000] nits")
            }
            sourcePeakNits = peak
        } else {
            sourcePeakNits = nil
        }
        for key in ["color_range", "colorspace", "color_primaries", "color_trc"] {
            if let raw = options[key] {
                let unspecified = key == "color_range" ? 0 : 2
                guard let value = Int(raw), value == 1 || value == unspecified else {
                    throw VTRemotedError.unsupported("HDR-to-SDR output must be limited-range BT.709 (\(key))")
                }
            }
        }
    }

    // FFmpeg AVPacketSideDataType values used by the existing side_data.v2 wire
    // contract. Preserve captions, timecodes and other unrelated records.
    static func isHDRSideData(_ type: UInt32) -> Bool {
        switch type {
        case 20, 22, 28, 29, 31, 41: true
        default: false
        }
    }
}

#if canImport(CoreImage) && canImport(CoreVideo)
    import CoreImage
    import CoreImage.CIFilterBuiltins
    import CoreVideo

    final class HDRToneMapper {
        private let context: CIContext
        private let encoded709: CGColorSpace
        private let maxFrameBytes: Int
        private let lock = NSLock()
        private var pool: CVPixelBufferPool?
        private var poolWidth = 0
        private var poolHeight = 0

        init(maxFrameBytes: Int) throws {
            guard #available(macOS 15.0, *) else {
                throw VTRemotedError.unsupported("HDR-to-SDR tone mapping requires macOS 15 or later")
            }
            guard let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020),
                  let encoded = CGColorSpace(name: CGColorSpace.itur_709) else {
                throw VTRemotedError.unsupported("HDR-to-SDR color spaces are unavailable")
            }
            encoded709 = encoded
            self.maxFrameBytes = maxFrameBytes
            var options: [CIContextOption: Any] = [.workingColorSpace: working,
                                                  .workingFormat: CIFormat.RGBAf.rawValue,
                                                  .cacheIntermediates: false]
            #if arch(x86_64)
                // Preserve neutral P010 chroma on Intel's rendering path.
                options[.useSoftwareRenderer] = true
            #endif
            context = CIContext(options: options)
        }

        func map(_ source: CVPixelBuffer, settings: HDRToSDRSettings) throws -> CVPixelBuffer {
            let mapped = try mappedImage(source, settings: settings)
            let output = try makeBuffer(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
            CVBufferRemoveAllAttachments(output)
            for key in [kCVImageBufferCleanApertureKey, kCVImageBufferPixelAspectRatioKey] {
                if let value = CVBufferCopyAttachment(source, key, nil) {
                    CVBufferSetAttachment(output, key, value, .shouldPropagate)
                }
            }
            tagOutput(output)
            // Quantize only after mapping and gamut conversion. P010 also keeps
            // the existing VideoToolbox resize path usable on macOS 15 hardware.
            let destination = CIRenderDestination(pixelBuffer: output)
            destination.colorSpace = encoded709
            try render(mapped, to: destination)
            return output
        }

        func render(_ image: CIImage, to destination: CIRenderDestination) throws {
            let task = try context.startTask(toRender: image, to: destination)
            _ = try task.waitUntilCompleted()
        }

        func mappedImage(_ source: CVPixelBuffer, settings: HDRToSDRSettings) throws -> CIImage {
            guard #available(macOS 15.0, *) else {
                throw VTRemotedError.unsupported("HDR-to-SDR tone mapping requires macOS 15 or later")
            }
            guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange else {
                throw VTRemotedError.unsupported("HDR-to-SDR requires 10-bit decoded P010 input")
            }
            let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
            guard width > 0, height > 0, width <= maxFrameBytes / 16 / height else {
                throw VTRemotedError.unsupported("HDR tone-mapping intermediate exceeds max frame bytes")
            }
            // hvcC-only decoder formats can leave guessed SDR attachments on
            // unchanged HDR samples. Derive the HDR colour space from validated
            // video tags so Core Image uses the video HDR reference white/OOTF.
            for key in [kCVImageBufferCGColorSpaceKey, kCVImageBufferICCProfileKey, kCVImageBufferGammaLevelKey] {
                CVBufferRemoveAttachment(source, key)
            }
            CVBufferSetAttachment(source, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(source, kCVImageBufferTransferFunctionKey, settings.sourceTransfer == 16 ?
                kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
            CVBufferSetAttachment(source, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            var peak = settings.sourcePeakNits ?? (settings.sourceTransfer == 16 ? 10000 : 1000)
            if let light = CVBufferCopyAttachment(source, kCVImageBufferContentLightLevelInfoKey, nil) as? Data,
               light.count >= 4 {
                let maxCLL = Int(light[0]) << 8 | Int(light[1])
                if maxCLL > 0 { peak = Double(maxCLL) }
            }
            guard peak <= 10000 else { throw VTRemotedError.unsupported("HDR source peak exceeds 10000 nits") }
            // Zero MaxCLL means unknown. Use the static/default peak instead of
            // treating it as SDR. Video HDR uses the standard 203-nit reference white.
            let options: [CIImageOption: Any] = [.toneMapHDRtoSDR: false, .contentHeadroom: max(1, peak / 203)]
            let input = CIImage(cvPixelBuffer: source, options: options)
            guard input.contentHeadroom.isFinite, input.contentHeadroom >= 1 else {
                throw VTRemotedError.unsupported("HDR source headroom is unknown")
            }
            let filter = CIFilter.toneMapHeadroom()
            filter.inputImage = input
            filter.sourceHeadroom = input.contentHeadroom
            filter.targetHeadroom = 1
            guard let mapped = filter.outputImage else {
                throw VTRemotedError.unsupported("HDR-to-SDR tone mapping is unavailable")
            }
            return mapped
        }

        func tagOutput(_ output: CVPixelBuffer) {
            for key in [kCVImageBufferMasteringDisplayColorVolumeKey, kCVImageBufferContentLightLevelInfoKey,
                        kCVImageBufferICCProfileKey, kCVImageBufferGammaLevelKey] {
                CVBufferRemoveAttachment(output, key)
            }
            CVBufferSetAttachment(output, kCVImageBufferCGColorSpaceKey, encoded709, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }

        private func makeBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
            lock.lock()
            defer { lock.unlock() }
            if pool == nil || poolWidth != width || poolHeight != height {
                let attributes: [CFString: Any] = [
                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                    kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                    kCVPixelBufferIOSurfacePropertiesKey: [:]
                ]
                var created: CVPixelBufferPool?
                guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created) == kCVReturnSuccess else {
                    throw VTRemotedError.unsupported("cannot allocate HDR tone-mapping pool")
                }
                pool = created
                poolWidth = width
                poolHeight = height
            }
            var buffer: CVPixelBuffer?
            guard let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
                  let buffer else {
                throw VTRemotedError.unsupported("cannot allocate HDR tone-mapping buffer")
            }
            return buffer
        }
    }
#endif
