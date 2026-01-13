import Foundation
import CLZ4

public enum LZ4Codec {
    public static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }

        let bound = Int(LZ4_compressBound(Int32(data.count)))
        var out = Data(count: bound)
        let written: Int32 = out.withUnsafeMutableBytes { outPtr in
            guard let outBase = outPtr.baseAddress else { return 0 }
            return data.withUnsafeBytes { srcPtr in
                guard let srcBase = srcPtr.baseAddress else { return 0 }
                return LZ4_compress_default(
                    srcBase.assumingMemoryBound(to: Int8.self),
                    outBase.assumingMemoryBound(to: Int8.self),
                    Int32(data.count),
                    Int32(bound)
                )
            }
        }
        guard written > 0 else { return nil }
        out.removeSubrange(Int(written)..<out.count)
        return out
    }

    public static func decompress(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize >= 0 else { return nil }
        guard expectedSize > 0 else { return Data() }

        var out = Data(count: expectedSize)
        let decoded: Int32 = out.withUnsafeMutableBytes { outPtr in
            guard let outBase = outPtr.baseAddress else { return -1 }
            return data.withUnsafeBytes { srcPtr in
                guard let srcBase = srcPtr.baseAddress else { return -1 }
                return LZ4_decompress_safe(
                    srcBase.assumingMemoryBound(to: Int8.self),
                    outBase.assumingMemoryBound(to: Int8.self),
                    Int32(data.count),
                    Int32(expectedSize)
                )
            }
        }
        guard decoded == Int32(expectedSize) else { return nil }
        return out
    }
}
