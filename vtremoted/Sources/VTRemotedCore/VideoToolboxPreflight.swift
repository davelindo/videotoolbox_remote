import Foundation

#if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo)
import CoreMedia
import CoreVideo
import VideoToolbox
#endif

public enum VideoToolboxPreflight {
    public static func checkOrExit(logger: Logger = .shared) {
        #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo)
        var cs: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 16,
            height: 16,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &cs
        )
        if status != noErr || cs == nil {
            logger.error("FATAL: VideoToolbox encoder unavailable status=\(status)")
            exit(1)
        }
        VTCompressionSessionInvalidate(cs!)
        #else
        _ = logger
        #endif
    }
}
