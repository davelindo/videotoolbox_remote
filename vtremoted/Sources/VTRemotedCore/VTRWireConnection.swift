import Foundation

public final class VTRWireConnection: @unchecked Sendable {
    public let fd: Int32
    private let sendLock = NSLock()

    public init(fd: Int32) {
        self.fd = fd
    }

    public func send(type: VTRMessageType, body: Data = Data()) throws {
        sendLock.lock()
        defer { sendLock.unlock() }
        let header = VTRMessageHeader(type: type.rawValue, length: UInt32(body.count)).encoded()
        var msg = Data()
        msg.reserveCapacity(header.count + body.count)
        msg.append(header)
        msg.append(body)
        try POSIXIO.writeAll(fd: fd, data: msg)
    }

    public func readHeader(timeoutSeconds: Int = 10) throws -> VTRMessageHeader {
        try POSIXIO.pollReadable(fd: fd, timeoutSeconds: timeoutSeconds)
        let raw = try POSIXIO.readExact(fd: fd, byteCount: VTRProtocol.headerSize)
        return try VTRMessageHeader.decode(raw)
    }

    public func readMessage(timeoutSeconds: Int = 10) throws -> (header: VTRMessageHeader, body: Data) {
        let header = try readHeader(timeoutSeconds: timeoutSeconds)
        let body = header.length > 0 ? try POSIXIO.readExact(fd: fd, byteCount: Int(header.length)) : Data()
        return (header, body)
    }
}
