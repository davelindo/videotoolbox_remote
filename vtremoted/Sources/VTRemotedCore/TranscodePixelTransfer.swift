#if canImport(VideoToolbox) && canImport(CoreVideo)
    import CoreVideo
    import Foundation
    import VideoToolbox

    /// Keeps resize sampling independent of the decoder's buffer storage.
    final class TranscodePixelTransfer {
        private let lock = NSLock()
        private var stagingBuffer: CVPixelBuffer?

        func reset() {
            lock.lock()
            defer { lock.unlock() }
            stagingBuffer = nil
        }

        func transfer(
            _ session: VTPixelTransferSession,
            from source: CVPixelBuffer,
            to destination: CVPixelBuffer
        ) throws {
            lock.lock()
            defer { lock.unlock() }

            let resizing = CVPixelBufferGetWidth(source) != CVPixelBufferGetWidth(destination) ||
                CVPixelBufferGetHeight(source) != CVPixelBufferGetHeight(destination)
            let input: CVPixelBuffer
            if resizing, CVPixelBufferGetIOSurface(source) != nil,
               CVPixelBufferGetIOSurface(destination) != nil {
                // On M2/macOS 15.7.5, IOSurface-to-IOSurface downscaling shifts
                // the sampling origin. Ordinary-memory input avoids that path.
                // Preserve the encoder's IOSurface output and all source metadata.
                input = try copyToMemory(source)
            } else {
                input = source
            }
            try check(VTPixelTransferSessionTransferImage(session, from: input, to: destination),
                      "transcode pixel transfer")
        }

        private func copyToMemory(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
            let width = CVPixelBufferGetWidth(source)
            let height = CVPixelBufferGetHeight(source)
            let format = CVPixelBufferGetPixelFormatType(source)
            if stagingBuffer.map({
                CVPixelBufferGetWidth($0) != width || CVPixelBufferGetHeight($0) != height ||
                    CVPixelBufferGetPixelFormatType($0) != format
            }) ?? true {
                var buffer: CVPixelBuffer?
                // Deliberately omit kCVPixelBufferIOSurfacePropertiesKey.
                try check(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                              nil, &buffer), "allocate transcode resize input")
                guard let buffer, CVPixelBufferGetIOSurface(buffer) == nil else {
                    throw VTRemotedError.unsupported("resize input requires ordinary memory")
                }
                stagingBuffer = buffer
            }
            guard let buffer = stagingBuffer else {
                throw VTRemotedError.videoToolboxUnavailable
            }
            try check(CVPixelBufferLockBaseAddress(source, .readOnly), "lock resize source")
            defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
            try check(CVPixelBufferLockBaseAddress(buffer, []), "lock resize input")
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

            let planes = CVPixelBufferGetPlaneCount(source)
            guard planes == CVPixelBufferGetPlaneCount(buffer) else {
                throw VTRemotedError.unsupported("resize input plane layout differs")
            }
            for plane in 0..<max(planes, 1) {
                let sourceBase = planes == 0 ? CVPixelBufferGetBaseAddress(source) :
                    CVPixelBufferGetBaseAddressOfPlane(source, plane)
                let destinationBase = planes == 0 ? CVPixelBufferGetBaseAddress(buffer) :
                    CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
                let sourceStride = planes == 0 ? CVPixelBufferGetBytesPerRow(source) :
                    CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let destinationStride = planes == 0 ? CVPixelBufferGetBytesPerRow(buffer) :
                    CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let rows = planes == 0 ? height : CVPixelBufferGetHeightOfPlane(source, plane)
                let destinationRows = planes == 0 ? height : CVPixelBufferGetHeightOfPlane(buffer, plane)
                guard let sourceBase, let destinationBase, sourceStride > 0,
                      destinationStride > 0, rows == destinationRows else {
                    throw VTRemotedError.unsupported("invalid resize input plane")
                }
                // CoreVideo allocated the same format and dimensions. Both strides
                // contain a full active row; padding lengths may differ.
                let bytes = min(sourceStride, destinationStride)
                for row in 0..<rows {
                    let output = destinationBase.advanced(by: row * destinationStride)
                    memcpy(output, sourceBase.advanced(by: row * sourceStride), bytes)
                    if destinationStride > bytes {
                        memset(output.advanced(by: bytes), 0, destinationStride - bytes)
                    }
                }
            }

            CVBufferRemoveAllAttachments(buffer)
            for mode in [CVAttachmentMode.shouldPropagate, .shouldNotPropagate] {
                if let attachments = CVBufferCopyAttachments(source, mode) {
                    CVBufferSetAttachments(buffer, attachments, mode)
                }
            }
            return buffer
        }

        private func check(_ status: OSStatus, _ operation: String) throws {
            guard status == noErr else {
                throw VTRemotedError.ioError(code: status, message: operation + " failed")
            }
        }
    }
#endif
