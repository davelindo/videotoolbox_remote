import Foundation

public enum VTRProtocol {
    /// 'VTR1'
    public static let magic: UInt32 = 0x5654_5231
    public static let version: UInt16 = 1
    public static let headerSize: Int = 12
}

public enum VTRPixelFormat {
    public static let nv12: UInt8 = 1
    public static let p010: UInt8 = 2
    public static let bgra: UInt8 = 3
    public static let ayuv: UInt8 = 4
    public static let p210: UInt8 = 5
    public static let videoToolbox: UInt8 = 6

    public static func name(_ value: UInt8) -> String {
        switch value {
        case nv12: "nv12"
        case p010: "p010"
        case bgra: "bgra"
        case ayuv: "ayuv"
        case p210: "p210"
        case videoToolbox: "videotoolbox"
        default: "unknown"
        }
    }
}

public enum VTRCapability {
    public static let h264 = "h264"
    public static let hevc = "hevc"
    public static let pixfmtNV12 = "pixfmt.nv12"
    public static let pixfmtP010 = "pixfmt.p010"
    public static let pixfmtBGRA = "pixfmt.bgra"
    public static let pixfmtAYUV = "pixfmt.ayuv"
    public static let pixfmtP210 = "pixfmt.p210"
    public static let hwFramesVideoToolboxInput = "hwframes.videotoolbox.input"
    public static let hwFramesVideoToolboxOutput = "hwframes.videotoolbox.output"
    public static let sideDataV2 = "side_data.v2"

    public static let baseline: [String] = [
        h264,
        hevc,
        pixfmtNV12,
        pixfmtP010
    ]

    public static let defaultServer: [String] = baseline + [
        pixfmtBGRA,
        pixfmtAYUV,
        pixfmtP210,
        hwFramesVideoToolboxInput,
        hwFramesVideoToolboxOutput,
        sideDataV2
    ]
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

    public init(
        magic: UInt32 = VTRProtocol.magic,
        version: UInt16 = VTRProtocol.version,
        type: UInt16,
        length: UInt32
    ) {
        self.magic = magic
        self.version = version
        self.type = type
        self.length = length
    }

    public func encoded() -> Data {
        var writer = ByteWriter(reserveCapacity: VTRProtocol.headerSize)
        writer.writeBE(magic)
        writer.writeBE(version)
        writer.writeBE(type)
        writer.writeBE(length)
        return writer.data
    }

    public static func decode(_ data: Data) throws -> VTRMessageHeader {
        guard data.count == VTRProtocol.headerSize else {
            throw VTRemotedError.protocolViolation("header size mismatch")
        }
        var reader = ByteReader(data)
        let magic = try reader.readBEUInt32()
        let version = try reader.readBEUInt16()
        let type = try reader.readBEUInt16()
        let length = try reader.readBEUInt32()
        guard magic == VTRProtocol.magic else {
            throw VTRemotedError.protocolViolation("bad magic")
        }
        guard version == VTRProtocol.version else {
            throw VTRemotedError.protocolViolation("unsupported version \(version)")
        }
        return VTRMessageHeader(type: type, length: length)
    }
}
