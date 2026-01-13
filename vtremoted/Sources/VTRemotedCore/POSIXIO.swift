import Foundation

public enum POSIXIO {
    public static func readExact(fd: Int32, byteCount: Int) throws -> Data {
        guard byteCount >= 0 else {
            throw VTRemotedError.protocolViolation("negative read length")
        }
        var buffer = [UInt8](repeating: 0, count: byteCount)
        var got = 0
        while got < byteCount {
            let n = buffer.withUnsafeMutableBytes { ptr in
                guard let base = ptr.baseAddress else { return Int(-1) }
                return read(fd, base.advanced(by: got), byteCount - got)
            }
            if n <= 0 {
                let code = errno
                throw VTRemotedError.ioError(code: code, message: String(cString: strerror(code)))
            }
            got += n
        }
        return Data(buffer)
    }

    public static func writeAll(fd: Int32, data: Data) throws {
        var total = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while total < data.count {
                let n = write(fd, base.advanced(by: total), data.count - total)
                if n <= 0 {
                    let code = errno
                    throw VTRemotedError.ioError(code: code, message: String(cString: strerror(code)))
                }
                total += n
            }
        }
    }

    public static func pollReadable(fd: Int32, timeoutSeconds: Int) throws {
        var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = withUnsafeMutablePointer(to: &pollFd) { ptr in
            poll(ptr, 1, Int32(timeoutSeconds * 1000))
        }
        if result <= 0 {
            throw VTRemotedError.ioError(code: Int32(result), message: "poll timed out")
        }
    }
}
