import Foundation

public enum POSIXIO {
    public static func readExact(fd fileDescriptor: Int32, into buffer: inout Data, count: Int) throws {
        guard count >= 0 else {
            throw VTRemotedError.protocolViolation("negative read length")
        }
        if buffer.count != count {
            buffer.count = count
        }

        var got = 0
        while got < count {
            let bytesRead = buffer.withUnsafeMutableBytes { ptr in
                guard let base = ptr.baseAddress else { return Int(-1) }
                return read(fileDescriptor, base.advanced(by: got), count - got)
            }
            if bytesRead <= 0 {
                let code = errno
                throw VTRemotedError.ioError(code: code, message: String(cString: strerror(code)))
            }
            got += bytesRead
        }
    }

    public static func readExact(fd fileDescriptor: Int32, byteCount: Int) throws -> Data {
        var data = Data(count: byteCount)
        try readExact(fd: fileDescriptor, into: &data, count: byteCount)
        return data
    }

    public static func writev(fd fileDescriptor: Int32, header: Data, body: Data) throws {
        try header.withUnsafeBytes { hPtr in
            try body.withUnsafeBytes { bPtr in
                var iovecs = [
                    iovec(iov_base: UnsafeMutableRawPointer(mutating: hPtr.baseAddress), iov_len: hPtr.count),
                    iovec(iov_base: UnsafeMutableRawPointer(mutating: bPtr.baseAddress), iov_len: bPtr.count)
                ]

                var totalWritten = 0
                let totalExpected = hPtr.count + bPtr.count

                while totalWritten < totalExpected {
                    let written = iovecs.withUnsafeMutableBufferPointer { ptr in
                        Darwin.writev(fileDescriptor, ptr.baseAddress, Int32(ptr.count))
                    }
                    if written < 0 {
                        let code = errno
                        if code == EINTR { continue }
                        throw VTRemotedError.ioError(code: code, message: String(cString: strerror(code)))
                    }
                    if written == 0 { throw VTRemotedError.ioError(code: 0, message: "writev returned 0") }

                    totalWritten += written
                    if totalWritten == totalExpected { return }

                    // Adjust iovecs for partial write
                    var remaining = written
                    var idx = 0
                    while remaining > 0, idx < iovecs.count {
                        if iovecs[idx].iov_len <= remaining {
                            remaining -= iovecs[idx].iov_len
                            iovecs[idx].iov_len = 0
                            idx += 1
                        } else {
                            iovecs[idx].iov_base = iovecs[idx].iov_base.advanced(by: remaining)
                            iovecs[idx].iov_len -= remaining
                            remaining = 0
                        }
                    }
                    // Remove fully written iovecs
                    if idx > 0 {
                        iovecs.removeFirst(idx)
                    }
                }
            }
        }
    }

    public static func writeAll(fd fileDescriptor: Int32, data: Data) throws {
        var total = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while total < data.count {
                let bytesWritten = write(fileDescriptor, base.advanced(by: total), data.count - total)
                if bytesWritten <= 0 {
                    let code = errno
                    throw VTRemotedError.ioError(code: code, message: String(cString: strerror(code)))
                }
                total += bytesWritten
            }
        }
    }

    public static func pollReadable(fd fileDescriptor: Int32, timeoutSeconds: Int) throws {
        var pollFd = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
        let result = withUnsafeMutablePointer(to: &pollFd) { ptr in
            poll(ptr, 1, Int32(timeoutSeconds * 1000))
        }
        if result <= 0 {
            throw VTRemotedError.ioError(code: Int32(result), message: "poll timed out")
        }
    }
}
