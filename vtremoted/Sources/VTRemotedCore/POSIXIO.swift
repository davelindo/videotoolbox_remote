import Foundation

/// One monotonic deadline for an entire message, including partial transfers.
public struct SocketDeadline: Sendable {
    let nanoseconds: UInt64

    public init(seconds: TimeInterval) {
        let duration = min(max(0, seconds), Double(Int32.max) / 1000)
        nanoseconds = DispatchTime.now().uptimeNanoseconds + UInt64(duration * 1_000_000_000)
    }

    func check() throws {
        if DispatchTime.now().uptimeNanoseconds >= nanoseconds {
            throw VTRemotedError.ioError(code: ETIMEDOUT, message: "socket deadline exceeded")
        }
    }
}

public enum POSIXIO {
    private static func wait(fd: Int32, events: Int16, deadline: SocketDeadline) throws {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        while true {
            try deadline.check()
            let now = DispatchTime.now().uptimeNanoseconds
            let remaining = deadline.nanoseconds > now ? deadline.nanoseconds - now : 0
            let milliseconds = Int32(min(UInt64(Int32.max), (remaining + 999_999) / 1_000_000))
            let result = poll(&descriptor, 1, milliseconds)
            if result > 0 {
                if descriptor.revents & Int16(POLLNVAL) != 0 {
                    throw VTRemotedError.ioError(code: EBADF, message: "invalid socket")
                }
                return // recv/send reports EOF or the specific socket error.
            }
            if result == 0 { continue }
            if errno == EINTR { continue }
            throw VTRemotedError.ioError(code: errno, message: String(cString: strerror(errno)))
        }
    }

    public static func readExact(fd: Int32, into buffer: inout Data, count: Int,
                                 deadline: SocketDeadline) throws {
        guard count >= 0 else { throw VTRemotedError.protocolViolation("negative read length") }
        buffer.count = count
        if count == 0 { return }
        try buffer.withUnsafeMutableBytes { bytes in
            try readExact(fd: fd, into: bytes.baseAddress!, count: count, deadline: deadline)
        }
    }

    public static func readExact(fd: Int32, into buffer: UnsafeMutableRawPointer, count: Int,
                                 deadline: SocketDeadline) throws {
        guard count >= 0 else { throw VTRemotedError.protocolViolation("negative read length") }
        var offset = 0
        while offset < count {
            try deadline.check()
            let result = recv(fd, buffer.advanced(by: offset), count - offset, Int32(MSG_DONTWAIT))
            if result > 0 { offset += result; continue }
            if result == 0 { throw VTRemotedError.ioError(code: 0, message: "unexpected EOF") }
            let code = errno
            if code == EINTR { continue }
            if code == EAGAIN || code == EWOULDBLOCK {
                try wait(fd: fd, events: Int16(POLLIN), deadline: deadline)
                continue
            }
            throw VTRemotedError.ioError(code: code, message: String(cString: strerror(code)))
        }
    }

    public static func writev(fd: Int32, parts: [Data], deadline: SocketDeadline) throws {
        var pointers: [UnsafeRawBufferPointer] = []
        func withPointers(_ index: Int, _ body: () throws -> Void) rethrows {
            if index == parts.count { return try body() }
            try parts[index].withUnsafeBytes { bytes in
                pointers.append(bytes)
                defer { pointers.removeLast() }
                try withPointers(index + 1, body)
            }
        }
        try withPointers(0) {
            var vectors = pointers.filter { !$0.isEmpty }.map {
                iovec(iov_base: UnsafeMutableRawPointer(mutating: $0.baseAddress), iov_len: $0.count)
            }
            var index = 0
            var batch: [iovec] = []
            batch.reserveCapacity(min(vectors.count, Int(IOV_MAX)))
            while index < vectors.count {
                try deadline.check()
                // Darwin can reject a whole uncompressed 4K frame with ENOBUFS
                // even on a writable TCP socket. Bound each kernel allocation.
                var budget = 1024 * 1024
                batch.removeAll(keepingCapacity: true)
                for vector in vectors[index...] {
                    let length = min(vector.iov_len, budget)
                    batch.append(iovec(iov_base: vector.iov_base, iov_len: length))
                    budget -= length
                    if budget == 0 || batch.count == Int(IOV_MAX) { break }
                }
                let result = batch.withUnsafeMutableBufferPointer { buffer -> Int in
                    var message = msghdr()
                    message.msg_iov = buffer.baseAddress!
                    message.msg_iovlen = Int32(buffer.count)
                    return sendmsg(fd, &message, Int32(MSG_DONTWAIT | MSG_NOSIGNAL))
                }
                if result < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    if code == EAGAIN || code == EWOULDBLOCK || code == ENOBUFS {
                        try wait(fd: fd, events: Int16(POLLOUT), deadline: deadline)
                        continue
                    }
                    throw VTRemotedError.ioError(code: code, message: String(cString: strerror(code)))
                }
                if result == 0 { throw VTRemotedError.ioError(code: EPIPE, message: "send returned 0") }
                var remaining = result
                while remaining > 0 {
                    if remaining >= vectors[index].iov_len {
                        remaining -= vectors[index].iov_len
                        index += 1
                    } else {
                        vectors[index].iov_base = vectors[index].iov_base.advanced(by: remaining)
                        vectors[index].iov_len -= remaining
                        remaining = 0
                    }
                }
            }
        }
    }
}
