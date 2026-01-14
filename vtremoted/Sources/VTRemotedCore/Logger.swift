import Foundation

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

public enum LogLevel: Int, Sendable {
    case error = 0
    case info = 1
    case debug = 2
}

public final class Logger: @unchecked Sendable {
    public static let shared = Logger()

    public var level: LogLevel = .info
    private let lock = NSLock()

    private init() {}

    public func error(_ message: @autoclosure () -> String) {
        log(.error, message())
    }

    public func info(_ message: @autoclosure () -> String) {
        log(.info, message())
    }

    public func debug(_ message: @autoclosure () -> String) {
        log(.debug, message())
    }

    private func log(_ msgLevel: LogLevel, _ message: String) {
        guard level.rawValue >= msgLevel.rawValue else { return }
        lock.lock()
        defer { lock.unlock() }

        // Avoid `stderr` global for Swift 6 strict concurrency.
        let line = "[vtremoted] \(message)\n"
        _ = line.utf8.withContiguousStorageIfAvailable { buf in
            buf.withUnsafeBytes { raw in
                _ = write(2, raw.baseAddress, raw.count)
            }
        } ?? {
            let bytes = Array(line.utf8)
            bytes.withUnsafeBytes { raw in
                _ = write(2, raw.baseAddress, raw.count)
            }
        }()
    }
}
