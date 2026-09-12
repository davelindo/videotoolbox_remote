import Foundation

/// Wall time in each plane stage; concurrent plane times overlap.
final class DecodeStageStats: @unchecked Sendable {
    private let lock = NSLock()
    private var copyNanoseconds: UInt64 = 0
    private var compressNanoseconds: UInt64 = 0
    private var planes: UInt64 = 0
    private var rawBytes: UInt64 = 0

    func record(copy: UInt64, compress: UInt64, bytes: Int) {
        lock.lock()
        copyNanoseconds += copy
        compressNanoseconds += compress
        rawBytes += UInt64(bytes)
        planes += 1
        lock.unlock()
    }

    func summary() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(format: "DECODE_STAGES planes=%llu raw_bytes=%llu copy_ms=%.3f compress_ms=%.3f",
                      planes, rawBytes, Double(copyNanoseconds) / 1_000_000,
                      Double(compressNanoseconds) / 1_000_000)
    }
}
