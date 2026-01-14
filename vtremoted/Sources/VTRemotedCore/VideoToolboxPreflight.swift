import Foundation

#if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo)
    import CoreMedia
    import CoreVideo
    import VideoToolbox
#endif

public enum VideoToolboxPreflight {
    public static func checkOrExit(logger: Logger = .shared) {
        #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo)
            var compressionSession: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: 16,
                height: 16,
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &compressionSession
            )
            if status == noErr, let session = compressionSession {
                VTCompressionSessionInvalidate(session)
                return
            }
        #else
            _ = logger
        #endif
    }
}
