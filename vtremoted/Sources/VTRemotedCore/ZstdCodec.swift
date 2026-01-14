import CZstd
import Foundation

public enum ZstdCodec {
    public static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }

        let bound = ZSTD_compressBound(data.count)
        var out = Data(count: bound)
        var written: Int = 0
        out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { srcPtr in
                if let srcBase = srcPtr.baseAddress, let outBase = outPtr.baseAddress {
                    written = ZSTD_compress(
                        outBase,
                        bound,
                        srcBase,
                        data.count,
                        1
                    )
                }
            }
        }
        guard ZSTD_isError(written) == 0 else { return nil }
        out.removeSubrange(written ..< out.count)
        return out
    }

    public static func compress(_ src: UnsafeRawPointer, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        let bound = ZSTD_compressBound(count)
        var out = Data(count: bound)
        var written: Int = 0
        out.withUnsafeMutableBytes { outPtr in
            if let outBase = outPtr.baseAddress {
                written = ZSTD_compress(
                    outBase,
                    bound,
                    src,
                    count,
                    1
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
        var decoded: Int = 0
        out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { srcPtr in
                if let srcBase = srcPtr.baseAddress, let outBase = outPtr.baseAddress {
                    decoded = ZSTD_decompress(
                        outBase,
                        expectedSize,
                        srcBase,
                        data.count
                    )
                }
            }
        }
        guard ZSTD_isError(decoded) == 0, decoded == expectedSize else { return nil }
        return out
    }

    public static func decompress(_ data: Data, into dst: UnsafeMutableRawPointer, expectedSize: Int) -> Bool {
        guard expectedSize > 0 else { return true }
        var decoded: Int = 0
        data.withUnsafeBytes { srcPtr in
            if let srcBase = srcPtr.baseAddress {
                decoded = ZSTD_decompress(
                    dst,
                    expectedSize,
                    srcBase,
                    data.count
                )
            }
        }
        return ZSTD_isError(decoded) == 0 && decoded == expectedSize
    }

    /// Zero-copy decompression from raw buffer pointer
    public static func decompressRaw(_ src: UnsafeRawBufferPointer, into dst: UnsafeMutableRawPointer, expectedSize: Int) -> Bool {
        guard expectedSize > 0 else { return true }
        guard let srcBase = src.baseAddress else { return false }
        let decoded = ZSTD_decompress(
            dst,
            expectedSize,
            srcBase,
            src.count
        )
        return ZSTD_isError(decoded) == 0 && decoded == expectedSize
    }
}
