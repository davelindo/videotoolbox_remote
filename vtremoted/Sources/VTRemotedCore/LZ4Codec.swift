import CLZ4
import Foundation

public enum LZ4Codec {
    public static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }

        let bound = Int(LZ4_compressBound(Int32(data.count)))
        var out = Data(count: bound)
        var written: Int32 = 0
        out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { srcPtr in
                if let srcBase = srcPtr.baseAddress, let outBase = outPtr.baseAddress {
                    written = LZ4_compress_default(
                        srcBase.assumingMemoryBound(to: Int8.self),
                        outBase.assumingMemoryBound(to: Int8.self),
                        Int32(data.count),
                        Int32(bound)
                    )
                }
            }
        }
        guard written > 0 else { return nil }
        out.removeSubrange(Int(written) ..< out.count)
        return out
    }

    public static func compress(_ src: UnsafeRawPointer, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        let bound = Int(LZ4_compressBound(Int32(count)))
        var out = Data(count: bound)
        var written: Int32 = 0
        out.withUnsafeMutableBytes { outPtr in
            if let outBase = outPtr.baseAddress {
                written = LZ4_compress_default(
                    src.assumingMemoryBound(to: Int8.self),
                    outBase.assumingMemoryBound(to: Int8.self),
                    Int32(count),
                    Int32(bound)
                )
            }
        }
        guard written > 0 else { return nil }
        out.removeSubrange(Int(written) ..< out.count)
        return out
    }

    public static func decompress(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize >= 0 else { return nil }
        guard expectedSize > 0 else { return Data() }

        var out = Data(count: expectedSize)
        var decoded: Int32 = 0
        out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { srcPtr in
                if let srcBase = srcPtr.baseAddress, let outBase = outPtr.baseAddress {
                    decoded = LZ4_decompress_safe(
                        srcBase.assumingMemoryBound(to: Int8.self),
                        outBase.assumingMemoryBound(to: Int8.self),
                        Int32(data.count),
                        Int32(expectedSize)
                    )
                }
            }
        }
        guard decoded == Int32(expectedSize) else { return nil }
        return out
    }

    public static func decompress(_ data: Data, into dst: UnsafeMutableRawPointer, expectedSize: Int) -> Bool {
        guard expectedSize > 0 else { return true }
        var decoded: Int32 = 0
        data.withUnsafeBytes { srcPtr in
            if let srcBase = srcPtr.baseAddress {
                decoded = LZ4_decompress_safe(
                    srcBase.assumingMemoryBound(to: Int8.self),
                    dst.assumingMemoryBound(to: Int8.self),
                    Int32(data.count),
                    Int32(expectedSize)
                )
            }
        }
        return decoded == Int32(expectedSize)
    }
}
