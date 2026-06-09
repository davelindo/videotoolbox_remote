import Foundation

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

public enum LZ4Codec {
    private typealias CompressBoundFn = @convention(c) (Int32) -> Int32
    private typealias CompressDefaultFn = @convention(c) (
        UnsafePointer<Int8>,
        UnsafeMutablePointer<Int8>,
        Int32,
        Int32
    ) -> Int32
    private typealias DecompressSafeFn = @convention(c) (
        UnsafePointer<Int8>,
        UnsafeMutablePointer<Int8>,
        Int32,
        Int32
    ) -> Int32

    /// Prefer loader search paths first so packaged binaries do not encode Homebrew paths.
    private static let libraryCandidates = [
        "liblz4.1.dylib",
        "liblz4.dylib",
        "liblz4.so.1",
        "liblz4.so",
        "/opt/homebrew/opt/lz4/lib/liblz4.1.dylib",
        "/opt/homebrew/lib/liblz4.1.dylib",
        "/opt/homebrew/lib/liblz4.dylib",
        "/usr/local/opt/lz4/lib/liblz4.1.dylib",
        "/usr/local/lib/liblz4.1.dylib",
        "/usr/local/lib/liblz4.dylib"
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
        let compressDefault: CompressDefaultFn
        let decompressSafe: DecompressSafeFn

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
                        Logger.shared.debug("LZ4 dlopen failed for \(candidate): \(error)")
                        loggedFirstDlopenFailure = true
                    }
                    continue
                }

                let compressBoundResult = loadSymbol(handle, "LZ4_compressBound", as: CompressBoundFn.self)
                let compressDefaultResult = loadSymbol(handle, "LZ4_compress_default", as: CompressDefaultFn.self)
                let decompressSafeResult = loadSymbol(handle, "LZ4_decompress_safe", as: DecompressSafeFn.self)
                let symbolErrors = [
                    ("LZ4_compressBound", compressBoundResult.error),
                    ("LZ4_compress_default", compressDefaultResult.error),
                    ("LZ4_decompress_safe", decompressSafeResult.error)
                ].compactMap { name, error in
                    error.map { "\(name): \($0)" }
                }

                guard let compressBound = compressBoundResult.symbol,
                      let compressDefault = compressDefaultResult.symbol,
                      let decompressSafe = decompressSafeResult.symbol
                else {
                    let error = symbolErrors.joined(separator: "; ")
                    failures.append("\(candidate): \(error)")
                    if !loggedFirstDlsymFailure {
                        Logger.shared.debug("LZ4 dlsym failed for \(candidate): \(error)")
                        loggedFirstDlsymFailure = true
                    }
                    // The handle did not provide the full ABI surface this codec needs.
                    dlclose(handle)
                    continue
                }
                Logger.shared.info("LZ4 runtime library loaded from \(candidate)")
                return LoadResult(
                    api: API(
                        compressBound: compressBound,
                        compressDefault: compressDefault,
                        decompressSafe: decompressSafe
                    ),
                    loadedPath: candidate,
                    failures: failures
                )
            }
            Logger.shared.error("LZ4 runtime library unavailable; \(diagnostics(loadedPath: nil, failures: failures))")
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
                "LZ4 runtime API unavailable during \(operation); " +
                    "CONFIGURE validation should have rejected this path; \(loadDiagnostics)"
            )
        }
        return api
    }

    public static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        let api = requireAPI("compress")

        let bound = Int(api.compressBound(Int32(data.count)))
        var out = Data(count: bound)
        var written: Int32 = 0
        out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { srcPtr in
                if let srcBase = srcPtr.baseAddress, let outBase = outPtr.baseAddress {
                    written = api.compressDefault(
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
        let api = requireAPI("compress")
        let bound = Int(api.compressBound(Int32(count)))
        var out = Data(count: bound)
        var written: Int32 = 0
        out.withUnsafeMutableBytes { outPtr in
            if let outBase = outPtr.baseAddress {
                written = api.compressDefault(
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
        let api = requireAPI("decompress")

        var out = Data(count: expectedSize)
        var decoded: Int32 = 0
        out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { srcPtr in
                if let srcBase = srcPtr.baseAddress, let outBase = outPtr.baseAddress {
                    decoded = api.decompressSafe(
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
        let api = requireAPI("decompress")
        var decoded: Int32 = 0
        data.withUnsafeBytes { srcPtr in
            if let srcBase = srcPtr.baseAddress {
                decoded = api.decompressSafe(
                    srcBase.assumingMemoryBound(to: Int8.self),
                    dst.assumingMemoryBound(to: Int8.self),
                    Int32(data.count),
                    Int32(expectedSize)
                )
            }
        }
        return decoded == Int32(expectedSize)
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
        let decoded = api.decompressSafe(
            srcBase.assumingMemoryBound(to: Int8.self),
            dst.assumingMemoryBound(to: Int8.self),
            Int32(src.count),
            Int32(expectedSize)
        )
        return decoded == Int32(expectedSize)
    }
}
