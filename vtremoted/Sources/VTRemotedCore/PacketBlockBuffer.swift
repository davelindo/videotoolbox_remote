#if canImport(CoreMedia)
import CoreMedia
import Foundation

enum PacketBlockBuffer {
    static func make(_ data: Data) throws -> CMBlockBuffer {
        guard !data.isEmpty else {
            throw VTRemotedError.protocolViolation("empty decode block buffer")
        }
        // NSData supplies a stable byte pointer, including for small inline Data.
        // Its retain keeps pooled storage alive through asynchronous VT callbacks.
        let retained = autoreleasepool { Unmanaged.passRetained(data as NSData) }
        let storage = retained.takeUnretainedValue()
        var source = CMBlockBufferCustomBlockSource()
        source.version = UInt32(kCMBlockBufferCustomBlockSourceVersion)
        source.refCon = retained.toOpaque()
        source.FreeBlock = { context, _, _ in
            if let context { Unmanaged<NSData>.fromOpaque(context).release() }
        }
        var block: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: UnsafeMutableRawPointer(mutating: storage.bytes),
            blockLength: storage.length,
            blockAllocator: nil,
            customBlockSource: &source,
            offsetToData: 0,
            dataLength: storage.length,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == noErr, let block else {
            retained.release()
            throw VTRemotedError.ioError(code: Int32(status), message: "CMBlockBufferCreateWithMemoryBlock failed")
        }
        return block
    }
}
#endif
