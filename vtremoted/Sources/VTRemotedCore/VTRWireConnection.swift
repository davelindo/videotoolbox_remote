import Foundation

public final class VTRWireConnection: @unchecked Sendable {
    public let fileDescriptor: Int32
    private let sendLock = NSLock()

    public init(fd fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    private func encodeHeader(type: VTRMessageType, bodyLength: Int) -> Data {
        VTRMessageHeader(
            type: type.rawValue,
            length: UInt32(bodyLength)
        ).encoded()
    }

    public func send(type: VTRMessageType, body: Data = Data()) throws {
        try sendMessage(type: type, bodyParts: [body])
    }

    public func sendMessage(type: VTRMessageType, bodyParts: [Data]) throws {
        sendLock.lock()
        defer { sendLock.unlock() }
        let totalLen = bodyParts.reduce(0) { $0 + $1.count }
        let header = encodeHeader(type: type, bodyLength: totalLen)

        var chunks = [header]
        chunks.append(contentsOf: bodyParts)

        try POSIXIO.writev(fd: fileDescriptor, parts: chunks)
    }

    private var headerBuf = Data(count: VTRProtocol.headerSize)
    private var bodyBuf = Data()
    private var skipBuf = Data(count: 16 * 1024)

    public func readHeader(timeoutSeconds: Int = 10) throws -> VTRMessageHeader {
        try POSIXIO.pollReadable(fd: fileDescriptor, timeoutSeconds: timeoutSeconds)
        try POSIXIO.readExact(fd: fileDescriptor, into: &headerBuf, count: VTRProtocol.headerSize)
        return try VTRMessageHeader.decode(headerBuf)
    }

    public func readBody(length: Int, pool: BufferPool? = nil) throws -> Data {
        if length <= 0 { return Data() }
        let len = length

        if let pool {
            var buf = pool.get(capacity: len)
            // BufferPool.get() returns a zero-length Data; size it for the read.
            if buf.count != len { buf.count = len }
            try POSIXIO.readExact(fd: fileDescriptor, into: &buf, count: len)
            return buf
        }

        // Avoid triggering Data's copy-on-write by mutating `bodyBuf` directly.
        if bodyBuf.count != len { bodyBuf.count = len }
        try POSIXIO.readExact(fd: fileDescriptor, into: &bodyBuf, count: len)
        return bodyBuf
    }

    public func readExact(into buffer: inout Data, count: Int) throws {
        try POSIXIO.readExact(fd: fileDescriptor, into: &buffer, count: count)
    }

    public func readExact(into buffer: UnsafeMutableRawPointer, count: Int) throws {
        try POSIXIO.readExact(fd: fileDescriptor, into: buffer, count: count)
    }

    public func skip(length: Int) throws {
        var remaining = length
        while remaining > 0 {
            let chunk = min(remaining, skipBuf.count)
            try POSIXIO.readExact(fd: fileDescriptor, into: &skipBuf, count: chunk)
            remaining -= chunk
        }
    }

    public func readMessage(
        pool: BufferPool? = nil,
        timeoutSeconds: Int = 10
    ) throws -> (header: VTRMessageHeader, body: Data) {
        let header = try readHeader(timeoutSeconds: timeoutSeconds)
        let body = try readBody(length: Int(header.length), pool: pool)
        return (header, body)
    }
}

extension VTRWireConnection: VTRStreamIO {}
