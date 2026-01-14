import Foundation

public final class VTRWireConnection: @unchecked Sendable {
    public let fileDescriptor: Int32
    private let sendLock = NSLock()

    public init(fd fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    public func send(type: VTRMessageType, body: Data = Data()) throws {
        try sendMessage(type: type, bodyParts: [body])
    }

    public func sendMessage(type: VTRMessageType, bodyParts: [Data]) throws {
        sendLock.lock()
        defer { sendLock.unlock() }
        let totalLen = bodyParts.reduce(0) { $0 + $1.count }
        let header = VTRMessageHeader(type: type.rawValue, length: UInt32(totalLen)).encoded()
        
        var chunks = [header]
        chunks.append(contentsOf: bodyParts)
        
        try POSIXIO.writev(fd: fileDescriptor, parts: chunks)
    }

    private var headerBuf = Data(count: VTRProtocol.headerSize)
    private var bodyBuf = Data()

    public func readHeader(timeoutSeconds: Int = 10) throws -> VTRMessageHeader {
        try POSIXIO.pollReadable(fd: fileDescriptor, timeoutSeconds: timeoutSeconds)
        try POSIXIO.readExact(fd: fileDescriptor, into: &headerBuf, count: VTRProtocol.headerSize)
        return try VTRMessageHeader.decode(headerBuf)
    }

    public func readMessage(pool: BufferPool? = nil, timeoutSeconds: Int = 10) throws -> (header: VTRMessageHeader, body: Data) {
        let header = try readHeader(timeoutSeconds: timeoutSeconds)

        if header.length > 0 {
            let len = Int(header.length)
            var buf: Data
            
            if let pool {
                buf = pool.get(capacity: len)
            } else {
                if bodyBuf.count != len {
                    bodyBuf.count = len
                }
                buf = bodyBuf
            }
            
            // Ensure correct size (BufferPool.get sets count=0)
            if buf.count != len {
                buf.count = len
            }
            
            try POSIXIO.readExact(fd: fileDescriptor, into: &buf, count: len)
            
            if pool == nil {
                // Determine if we need to update our internal buffer reference
                // (Though strictly speaking, bodyBuf was a value copy, but we want to keep the capacity)
                bodyBuf = buf
            }
            return (header, buf)
        } else {
            return (header, Data())
        }
    }
}
