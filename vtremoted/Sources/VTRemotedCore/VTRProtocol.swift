import Foundation

public enum VTRProtocol {
    /// 'VTR1'
    public static let magic: UInt32 = 0x5654_5231
    public static let version: UInt16 = 1
    public static let headerSize: Int = 12
}

public enum VTRMessageType: UInt16, Sendable {
    case hello = 1
    case helloAck
    case configure
    case configureAck
    case frame
    case packet
    case flush
    case done
    case error
    case ping
    case pong
}

public struct VTRMessageHeader: Equatable, Sendable {
    public var magic: UInt32
    public var version: UInt16
    public var type: UInt16
    public var length: UInt32

    public init(magic: UInt32 = VTRProtocol.magic, version: UInt16 = VTRProtocol.version, type: UInt16, length: UInt32) {
        self.magic = magic
        self.version = version
        self.type = type
        self.length = length
    }

    public func encoded() -> Data {
        var w = ByteWriter(reserveCapacity: VTRProtocol.headerSize)
        w.writeBE(magic)
        w.writeBE(version)
        w.writeBE(type)
        w.writeBE(length)
        return w.data
    }

    public static func decode(_ data: Data) throws -> VTRMessageHeader {
        guard data.count == VTRProtocol.headerSize else {
            throw VTRemotedError.protocolViolation("header size mismatch")
        }
        var r = ByteReader(data)
        let magic = try r.readBEUInt32()
        let version = try r.readBEUInt16()
        let type = try r.readBEUInt16()
        let length = try r.readBEUInt32()
        guard magic == VTRProtocol.magic else {
            throw VTRemotedError.protocolViolation("bad magic")
        }
        guard version == VTRProtocol.version else {
            throw VTRemotedError.protocolViolation("unsupported version \(version)")
        }
        return VTRMessageHeader(type: type, length: length)
    }
}
