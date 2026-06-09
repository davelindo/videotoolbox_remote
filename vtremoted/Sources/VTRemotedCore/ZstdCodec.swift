import Foundation

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

public enum ZstdCodec {
    private typealias CompressBoundFn = @convention(c) (Int) -> Int
    private typealias CompressFn = @convention(c) (
        UnsafeMutableRawPointer?,
        Int,
        UnsafeRawPointer?,
        Int,
        Int32
    ) -> Int
    private typealias DecompressFn = @convention(c) (
        UnsafeMutableRawPointer?,
        Int,
        UnsafeRawPointer?,
        Int
    ) -> Int
    private typealias IsErrorFn = @convention(c) (Int) -> UInt32

    /// Prefer loader search paths first so packaged binaries do not encode Homebrew paths.
    private static let libraryCandidates = [
        "libzstd.1.dylib",
        "libzstd.dylib",
        "libzstd.so.1",
        "libzstd.so",
        "/opt/homebrew/opt/zstd/lib/libzstd.1.dylib",
        "/opt/homebrew/lib/libzstd.1.dylib",
        "/opt/homebrew/lib/libzstd.dylib",
        "/usr/local/opt/zstd/lib/libzstd.1.dylib",
        "/usr/local/lib/libzstd.1.dylib",
        "/usr/local/lib/libzstd.dylib"
    ]

    private static func currentDLError(fallback: String) -> String {
        guard let rawError = dlerror() else { return fallback }
        return String(cString: rawError)
    }

    private static func loadSymbol<T>(
        _ handle: UnsafeMutableRawPointer,
        _ name: String,
        as _: T.Type
    ) -> (symbol: T?, error: String?) {
        _ = dlerror()
        guard let rawSymbol = dlsym(handle, name) else {
            return (nil, currentDLError(fallback: "\(name) not found"))
        }
        return (unsafeBitCast(rawSymbol, to: T.self), nil)
    }

    private struct API {
        let compressBound: CompressBoundFn
        let compress: CompressFn
        let decompress: DecompressFn
        let isError: IsErrorFn

        static func load() -> LoadResult {
            var failures: [String] = []
            var loggedFirstDlopenFailure = false
            var loggedFirstDlsymFailure = false

            for candidate in libraryCandidates {
                _ = dlerror()
                guard let handle = dlopen(candidate, RTLD_NOW) else {
                    let error = currentDLError(fallback: "dlopen returned nil")
                    failures.append("\(candidate): \(error)")
                    if !loggedFirstDlopenFailure {
                        Logger.shared.debug("Zstd dlopen failed for \(candidate): \(error)")
                        loggedFirstDlopenFailure = true
                    }
                    continue
                }

                let compressBoundResult = loadSymbol(handle, "ZSTD_compressBound", as: CompressBoundFn.self)
                let compressResult = loadSymbol(handle, "ZSTD_compress", as: CompressFn.self)
                let decompressResult = loadSymbol(handle, "ZSTD_decompress", as: DecompressFn.self)
                let isErrorResult = loadSymbol(handle, "ZSTD_isError", as: IsErrorFn.self)
                let symbolErrors = [
                    ("ZSTD_compressBound", compressBoundResult.error),
                    ("ZSTD_compress", compressResult.error),
                    ("ZSTD_decompress", decompressResult.error),
                    ("ZSTD_isError", isErrorResult.error)
                ].compactMap { name, error in
                    error.map { "\(name): \($0)" }
                }

                guard let compressBound = compressBoundResult.symbol,
                      let compress = compressResult.symbol,
                      let decompress = decompressResult.symbol,
                      let isError = isErrorResult.symbol
                else {
                    let error = symbolErrors.joined(separator: "; ")
                    failures.append("\(candidate): \(error)")
                    if !loggedFirstDlsymFailure {
                        Logger.shared.debug("Zstd dlsym failed for \(candidate): \(error)")
                        loggedFirstDlsymFailure = true
                    }
                    // The handle did not provide the full ABI surface this codec needs.
                    dlclose(handle)
                    continue
                }
                Logger.shared.info("Zstd runtime library loaded from \(candidate)")
                return LoadResult(
                    api: API(
                        compressBound: compressBound,
                        compress: compress,
                        decompress: decompress,
                        isError: isError
                    ),
                    loadedPath: candidate,
                    failures: failures
                )
            }
            Logger.shared.error("Zstd runtime library unavailable; \(diagnostics(loadedPath: nil, failures: failures))")
            return LoadResult(api: nil, loadedPath: nil, failures: failures)
        }
    }

    private struct LoadResult {
        let api: API?
        let loadedPath: String?
        let failures: [String]
    }

    private static func diagnostics(loadedPath: String?, failures: [String]) -> String {
        if let loadedPath {
            return "loaded=\(loadedPath)"
        }
        let lastError = failures.last ?? "none"
        return "tried=[\(libraryCandidates.joined(separator: ", "))]; last dlerror=\(lastError)"
    }

    private static let loadResult = API.load()
    private static let api = loadResult.api

    public static var loadDiagnostics: String {
        diagnostics(loadedPath: loadResult.loadedPath, failures: loadResult.failures)
    }

    public static var isAvailable: Bool {
        api != nil
    }

    private static func requireAPI(_ operation: String) -> API {
        guard let api else {
            preconditionFailure(
                "Zstd runtime API unavailable during \(operation); " +
                    "CONFIGURE validation should have rejected this path; \(loadDiagnostics)"
            )
        }
        return api
    }

    public static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        let api = requireAPI("compress")

        let bound = api.compressBound(data.count)
        var out = Data(count: bound)
        var written = 0
        out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { srcPtr in
                if let srcBase = srcPtr.baseAddress, let outBase = outPtr.baseAddress {
                    written = api.compress(
                        outBase,
                        bound,
                        srcBase,
                        data.count,
                        1
                    )
                }
            }
        }
        guard api.isError(written) == 0 else { return nil }
        out.removeSubrange(written ..< out.count)
        return out
    }

    public static func compress(_ src: UnsafeRawPointer, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        let api = requireAPI("compress")
        let bound = api.compressBound(count)
        var out = Data(count: bound)
        var written = 0
        out.withUnsafeMutableBytes { outPtr in
            if let outBase = outPtr.baseAddress {
                written = api.compress(
                    outBase,
                    bound,
                    src,
                    count,
                    1
                )
            }
        }
        guard api.isError(written) == 0 else { return nil }
        out.removeSubrange(written ..< out.count)
        return out
    }

    public static func decompress(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize >= 0 else { return nil }
        guard expectedSize > 0 else { return Data() }
        let api = requireAPI("decompress")

        var out = Data(count: expectedSize)
        var decoded = 0
        out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { srcPtr in
                if let srcBase = srcPtr.baseAddress, let outBase = outPtr.baseAddress {
                    decoded = api.decompress(
                        outBase,
                        expectedSize,
                        srcBase,
                        data.count
                    )
                }
            }
        }
        guard api.isError(decoded) == 0, decoded == expectedSize else { return nil }
        return out
    }

    public static func decompress(_ data: Data, into dst: UnsafeMutableRawPointer, expectedSize: Int) -> Bool {
        guard expectedSize > 0 else { return true }
        let api = requireAPI("decompress")
        var decoded = 0
        data.withUnsafeBytes { srcPtr in
            if let srcBase = srcPtr.baseAddress {
                decoded = api.decompress(
                    dst,
                    expectedSize,
                    srcBase,
                    data.count
                )
            }
        }
        return api.isError(decoded) == 0 && decoded == expectedSize
    }

    /// Zero-copy decompression from raw buffer pointer
    public static func decompressRaw(
        _ src: UnsafeRawBufferPointer,
        into dst: UnsafeMutableRawPointer,
        expectedSize: Int
    ) -> Bool {
        guard expectedSize > 0 else { return true }
        let api = requireAPI("decompressRaw")
        guard let srcBase = src.baseAddress else { return false }
        let decoded = api.decompress(
            dst,
            expectedSize,
            srcBase,
            src.count
        )
        return api.isError(decoded) == 0 && decoded == expectedSize
    }
}
