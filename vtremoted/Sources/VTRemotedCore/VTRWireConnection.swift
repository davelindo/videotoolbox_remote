import Foundation

public final class VTRWireConnection: @unchecked Sendable {
    public let fileDescriptor: Int32
    private let sendLock = NSLock()
    private let readLock = NSLock()
    private var sendHeaderBuf = Data(count: VTRProtocol.headerSize)
    private var sendPartsBuf: [Data] = []
    private let writeTimeoutSeconds: TimeInterval
    private var writeError: Error?
    private var readDeadline = SocketDeadline(seconds: 10)

    public init(fd fileDescriptor: Int32, writeTimeoutSeconds: TimeInterval = 10) throws {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw VTRemotedError.ioError(code: errno, message: "could not make socket nonblocking")
        }
        self.fileDescriptor = fileDescriptor
        self.writeTimeoutSeconds = writeTimeoutSeconds
    }

    /// Wake the input loop after a fatal callback; allow its ERROR response to finish.
    public func cancelRead() {
        _ = shutdown(fileDescriptor, SHUT_RD)
    }

    private func write(_ parts: [Data]) throws {
        if let writeError { throw writeError }
        do {
            try POSIXIO.writev(fd: fileDescriptor, parts: parts, deadline: SocketDeadline(seconds: writeTimeoutSeconds))
        } catch {
            // A partial message cannot be followed by another header.
            writeError = error
            throw error
        }
    }

    private func encodeHeader(type: VTRMessageType, bodyLength: Int) throws {
        guard bodyLength >= 0, bodyLength <= Int(UInt32.max) else {
            throw VTRemotedError.protocolViolation("outbound message too large")
        }
        let magic = VTRProtocol.magic
        let version = VTRProtocol.version
        let messageType = type.rawValue
        let length = UInt32(bodyLength)

        sendHeaderBuf.withUnsafeMutableBytes { raw in
            guard raw.count >= VTRProtocol.headerSize else { return }
            raw[0] = UInt8((magic >> 24) & 0xFF)
            raw[1] = UInt8((magic >> 16) & 0xFF)
            raw[2] = UInt8((magic >> 8) & 0xFF)
            raw[3] = UInt8(magic & 0xFF)

            raw[4] = UInt8((version >> 8) & 0xFF)
            raw[5] = UInt8(version & 0xFF)

            raw[6] = UInt8((messageType >> 8) & 0xFF)
            raw[7] = UInt8(messageType & 0xFF)

            raw[8] = UInt8((length >> 24) & 0xFF)
            raw[9] = UInt8((length >> 16) & 0xFF)
            raw[10] = UInt8((length >> 8) & 0xFF)
            raw[11] = UInt8(length & 0xFF)
        }
    }

    public func send(type: VTRMessageType, body: Data = Data()) throws {
        sendLock.lock()
        defer {
            sendPartsBuf.removeAll(keepingCapacity: true)
            sendLock.unlock()
        }
        try encodeHeader(type: type, bodyLength: body.count)
        if body.isEmpty {
            try write([sendHeaderBuf])
            return
        }
        sendPartsBuf.removeAll(keepingCapacity: true)
        sendPartsBuf.reserveCapacity(2)
        sendPartsBuf.append(sendHeaderBuf)
        sendPartsBuf.append(body)
        try write(sendPartsBuf)
    }

    public func sendMessage(type: VTRMessageType, bodyParts: [Data]) throws {
        sendLock.lock()
        defer {
            sendPartsBuf.removeAll(keepingCapacity: true)
            sendLock.unlock()
        }

        let partCount = bodyParts.count
        var totalLen = 0
        for part in bodyParts {
            let (next, overflow) = totalLen.addingReportingOverflow(part.count)
            guard !overflow else {
                throw VTRemotedError.protocolViolation("outbound message too large")
            }
            totalLen = next
        }

        try encodeHeader(type: type, bodyLength: totalLen)
        if totalLen == 0 {
            try write([sendHeaderBuf])
            return
        }

        sendPartsBuf.removeAll(keepingCapacity: true)
        sendPartsBuf.reserveCapacity(partCount + 1)
        sendPartsBuf.append(sendHeaderBuf)
        switch partCount {
        case 1:
            sendPartsBuf.append(bodyParts[0])
        case 2:
            sendPartsBuf.append(bodyParts[0])
            sendPartsBuf.append(bodyParts[1])
        default:
            sendPartsBuf.append(contentsOf: bodyParts)
        }

        try write(sendPartsBuf)
    }

    private var headerBuf = Data(count: VTRProtocol.headerSize)
    private var bodyBuf = Data()
    private var skipBuf = Data(count: 16 * 1024)

    public func readHeader(timeoutSeconds: Int = 10) throws -> VTRMessageHeader {
        readLock.lock()
        defer { readLock.unlock() }
        return try readHeaderLocked(timeoutSeconds: timeoutSeconds)
    }

    private func readHeaderLocked(timeoutSeconds: Int) throws -> VTRMessageHeader {
        readDeadline = SocketDeadline(seconds: TimeInterval(timeoutSeconds))
        try POSIXIO.readExact(fd: fileDescriptor, into: &headerBuf, count: VTRProtocol.headerSize, deadline: readDeadline)
        return try VTRMessageHeader.decode(headerBuf)
    }

    public func readBody(length: Int, pool: BufferPool? = nil) throws -> Data {
        readLock.lock()
        defer { readLock.unlock() }
        return try readBodyLocked(length: length, pool: pool)
    }

    private func readBodyLocked(length: Int, pool: BufferPool? = nil) throws -> Data {
        if length <= 0 { return Data() }
        let len = length

        if let pool {
            var buf = pool.get(capacity: len)
            // BufferPool.get() returns a zero-length Data; size it for the read.
            if buf.count != len { buf.count = len }
            try POSIXIO.readExact(fd: fileDescriptor, into: &buf, count: len, deadline: readDeadline)
            return buf
        }

        // Avoid triggering Data's copy-on-write by mutating `bodyBuf` directly.
        if bodyBuf.count != len { bodyBuf.count = len }
        try POSIXIO.readExact(fd: fileDescriptor, into: &bodyBuf, count: len, deadline: readDeadline)
        // Data is a value type; returning it here keeps the shared scratch buffer private
        // to the next locked read unless the caller mutates its returned copy.
        return bodyBuf
    }

    public func readMessageAtomically(
        pool: BufferPool? = nil,
        timeoutSeconds: Int = 10,
        validateHeader: (VTRMessageHeader) throws -> Void
    ) throws -> (header: VTRMessageHeader, body: Data) {
        readLock.lock()
        defer { readLock.unlock() }

        let header = try readHeaderLocked(timeoutSeconds: timeoutSeconds)
        try validateHeader(header)
        let body = try readBodyLocked(length: Int(header.length), pool: pool)
        return (header, body)
    }

    public func readExact(into buffer: inout Data, count: Int) throws {
        readLock.lock()
        defer { readLock.unlock() }
        try POSIXIO.readExact(fd: fileDescriptor, into: &buffer, count: count, deadline: readDeadline)
    }

    public func readExact(into buffer: UnsafeMutableRawPointer, count: Int) throws {
        readLock.lock()
        defer { readLock.unlock() }
        try POSIXIO.readExact(fd: fileDescriptor, into: buffer, count: count, deadline: readDeadline)
    }

    public func skip(length: Int) throws {
        readLock.lock()
        defer { readLock.unlock() }
        try skipLocked(length: length)
    }

    private func skipLocked(length: Int) throws {
        var remaining = length
        while remaining > 0 {
            let chunk = min(remaining, skipBuf.count)
            try POSIXIO.readExact(fd: fileDescriptor, into: &skipBuf, count: chunk, deadline: readDeadline)
            remaining -= chunk
        }
    }

    public func readMessage(
        pool: BufferPool? = nil,
        timeoutSeconds: Int = 10
    ) throws -> (header: VTRMessageHeader, body: Data) {
        try readMessageAtomically(
            pool: pool,
            timeoutSeconds: timeoutSeconds,
            validateHeader: { _ in }
        )
    }
}

extension VTRWireConnection: VTRStreamIO {}
