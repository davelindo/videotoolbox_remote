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

    public static func writev(fd fileDescriptor: Int32, parts: [Data]) throws {
        // Recursive helper to bind pointers for all chunks
        func withPointers(_ chunks: [Data], 
                          _ index: Int, 
                          _ pointers: [UnsafeRawBufferPointer], 
                          _ block: ([UnsafeRawBufferPointer]) throws -> Void) rethrows {
            if index == chunks.count {
                try block(pointers)
                return
            }
            try chunks[index].withUnsafeBytes { ptr in
                var newPointers = pointers
                newPointers.append(ptr)
                try withPointers(chunks, index + 1, newPointers, block)
            }
        }

        try withPointers(parts, 0, []) { buffers in
            var iovecs = buffers.map { buffer in
                iovec(iov_base: UnsafeMutableRawPointer(mutating: buffer.baseAddress), iov_len: buffer.count)
            }
            
            var totalWritten = 0
            let totalExpected = iovecs.reduce(0) { $0 + $1.iov_len }
            
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
                while remaining > 0 && !iovecs.isEmpty {
                    if iovecs[0].iov_len <= remaining {
                        remaining -= iovecs[0].iov_len
                        iovecs.removeFirst()
                    } else {
                        iovecs[0].iov_base = iovecs[0].iov_base.advanced(by: remaining)
                        iovecs[0].iov_len -= remaining
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
