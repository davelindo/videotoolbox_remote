import CZstd
import Foundation

public enum ZstdCodec {
    public static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }

        let bound = ZSTD_compressBound(data.count)
        var out = Data(count: bound)
        let written: Int = out.withUnsafeMutableBytes { outPtr in
            guard let outBase = outPtr.baseAddress else { return 0 }
            return data.withUnsafeBytes { srcPtr in
                guard let srcBase = srcPtr.baseAddress else { return 0 }
                return ZSTD_compress(
                    outBase,
                    bound,
                    srcBase,
                    data.count,
                    1 // Default compression level
                )
            }
        }
        guard ZSTD_isError(written) == 0 else { return nil }
        out.removeSubrange(written ..< out.count)
        return out
    }

    public static func decompress(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize >= 0 else { return nil }
        guard expectedSize > 0 else { return Data() }

        var out = Data(count: expectedSize)
        let decoded: Int = out.withUnsafeMutableBytes { outPtr in
            guard let outBase = outPtr.baseAddress else { return 0 }
            return data.withUnsafeBytes { srcPtr in
                guard let srcBase = srcPtr.baseAddress else { return 0 }
                return ZSTD_decompress(
                    outBase,
                    expectedSize,
                    srcBase,
                    data.count
                )
            }
        }
        guard ZSTD_isError(decoded) == 0, decoded == expectedSize else { return nil }
        return out
    }
}
