import Foundation

public enum POSIXIO {
    private static func readExactLoop(count: Int, reader: (Int) -> Int) throws {
        var got = 0
        while got < count {
            let bytesRead = reader(got)
            if bytesRead < 0 {
                let code = errno
                if code == EINTR { continue }
                throw VTRemotedError.ioError(code: code, message: String(cString: strerror(code)))
            }
            if bytesRead == 0 {
                throw VTRemotedError.ioError(code: 0, message: "unexpected EOF")
            }
            got += bytesRead
        }
    }

    private static func writeExactLoop(count: Int, writer: (Int) -> Int) throws {
        var writtenTotal = 0
        while writtenTotal < count {
            let bytesWritten = writer(writtenTotal)
            if bytesWritten < 0 {
                let code = errno
                if code == EINTR { continue }
                throw VTRemotedError.ioError(code: code, message: String(cString: strerror(code)))
            }
            if bytesWritten == 0 {
                throw VTRemotedError.ioError(code: 0, message: "write returned 0")
            }
            writtenTotal += bytesWritten
        }
    }

    public static func readExact(fd fileDescriptor: Int32, into buffer: inout Data, count: Int) throws {
        guard count >= 0 else {
            throw VTRemotedError.protocolViolation("negative read length")
        }
        if buffer.count != count {
            buffer.count = count
        }

        try buffer.withUnsafeMutableBytes { ptr in
            if let base = ptr.baseAddress {
                try readExactLoop(count: count) { got in
                    read(fileDescriptor, base.advanced(by: got), count - got)
                }
            } else {
                try readExactLoop(count: count) { _ in
                    Int(-1)
                }
            }
        }
    }

    public static func readExact(fd fileDescriptor: Int32, into buffer: UnsafeMutableRawPointer, count: Int) throws {
        guard count >= 0 else {
            throw VTRemotedError.protocolViolation("negative read length")
        }
        if count == 0 { return }

        try readExactLoop(count: count) { got in
            read(fileDescriptor, buffer.advanced(by: got), count - got)
        }
    }

    public static func readExact(fd fileDescriptor: Int32, byteCount: Int) throws -> Data {
        var data = Data(count: byteCount)
        try readExact(fd: fileDescriptor, into: &data, count: byteCount)
        return data
    }

    public static func writev(fd fileDescriptor: Int32, parts: [Data]) throws {
        guard !parts.isEmpty else { return }

        // Bind all `Data` buffers to stable pointers for the duration of the write loop.
        var pointers: [UnsafeRawBufferPointer] = []
        pointers.reserveCapacity(parts.count)

        func withPointers<T>(_ idx: Int, _ body: ([UnsafeRawBufferPointer]) throws -> T) rethrows -> T {
            if idx == parts.count {
                return try body(pointers)
            }
            return try parts[idx].withUnsafeBytes { ptr in
                pointers.append(ptr)
                defer { pointers.removeLast() }
                return try withPointers(idx + 1, body)
            }
        }

        try withPointers(0) { buffers in
            var iovecs: [iovec] = buffers.map { buffer in
                iovec(
                    iov_base: UnsafeMutableRawPointer(mutating: buffer.baseAddress),
                    iov_len: buffer.count
                )
            }

            let totalExpected = iovecs.reduce(0) { $0 + $1.iov_len }
            if totalExpected == 0 { return }

            var totalWritten = 0
            var iovIndex = 0
            while totalWritten < totalExpected {
                let written = iovecs.withUnsafeMutableBufferPointer { ptr -> Int in
                    guard let base = ptr.baseAddress else { return -1 }
                    return Darwin.writev(fileDescriptor, base.advanced(by: iovIndex), Int32(ptr.count - iovIndex))
                }

                if written < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw VTRemotedError.ioError(code: code, message: String(cString: strerror(code)))
                }
                if written == 0 {
                    throw VTRemotedError.ioError(code: 0, message: "writev returned 0")
                }

                totalWritten += written
                if totalWritten == totalExpected { return }

                // Adjust iovecs for partial write without O(n) removeFirst().
                var remaining = written
                while remaining > 0, iovIndex < iovecs.count {
                    if iovecs[iovIndex].iov_len <= remaining {
                        remaining -= iovecs[iovIndex].iov_len
                        iovIndex += 1
                    } else {
                        iovecs[iovIndex].iov_base = iovecs[iovIndex].iov_base.advanced(by: remaining)
                        iovecs[iovIndex].iov_len -= remaining
                        remaining = 0
                    }
                }
            }
        }
    }

    // Legacy helper for header+body calling the new vectorized version
    public static func writev(fd fileDescriptor: Int32, header: Data, body: Data) throws {
        try writev(fd: fileDescriptor, parts: [header, body])
    }

    public static func writeAll(fd fileDescriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            try writeExactLoop(count: data.count) { offset in
                write(fileDescriptor, base.advanced(by: offset), data.count - offset)
            }
        }
    }

    public static func pollReadable(fd fileDescriptor: Int32, timeoutSeconds: Int) throws {
        var pollFd = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
        while true {
            let result = withUnsafeMutablePointer(to: &pollFd) { ptr in
                poll(ptr, 1, Int32(timeoutSeconds * 1000))
            }
            if result > 0 {
                return
            }
            if result == 0 {
                throw VTRemotedError.ioError(code: 0, message: "poll timed out")
            }

            let code = errno
            if code == EINTR { continue }
            throw VTRemotedError.ioError(code: code, message: String(cString: strerror(code)))
        }
    }
}
