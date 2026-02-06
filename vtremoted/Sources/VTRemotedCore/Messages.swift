import Foundation

public struct HelloRequest: Equatable, Sendable {
    public var token: String
    public var codec: String
    public var clientName: String
    public var build: String

    public static func decode(_ payload: Data) throws -> HelloRequest {
        var reader = ByteReader(payload)
        return try HelloRequest(
            token: reader.readLengthPrefixedUTF8(),
            codec: reader.readLengthPrefixedUTF8(),
            clientName: reader.readLengthPrefixedUTF8(),
            build: reader.readLengthPrefixedUTF8()
        )
    }
}

public struct HelloAckResponse: Equatable, Sendable {
    public var status: UInt8
    public var serverName: String
    public var serverVersion: String
    public var capabilities: [String]
    public var maxSessions: UInt16
    public var activeSessions: UInt16

    public func encode() -> Data {
        var writer = ByteWriter()
        writer.write(status)
        writer.writeLengthPrefixedUTF8(serverName)
        writer.writeLengthPrefixedUTF8(serverVersion)
        writer.write(UInt8(UInt8(clamping: capabilities.count)))
        for cap in capabilities {
            writer.writeLengthPrefixedUTF8(cap)
        }
        writer.writeBE(maxSessions)
        writer.writeBE(activeSessions)
        return writer.data
    }
}

public struct ConfigureRequest: Sendable {
    public var width: Int
    public var height: Int
    public var pixelFormat: UInt8
    public var timebase: Timebase
    public var frameRate: (num: Int, den: Int)
    public var options: [String: String]
    public var extradata: Data?

    public static func decode(_ payload: Data) throws -> ConfigureRequest {
        var reader = ByteReader(payload)
        let width = try Int(reader.readBEUInt32())
        let height = try Int(reader.readBEUInt32())
        let pix = try reader.readUInt8()
        let tbNum = try Int(reader.readBEUInt32())
        let tbDen = try Int(reader.readBEUInt32())
        let frNum = try Int(reader.readBEUInt32())
        let frDen = try Int(reader.readBEUInt32())

        var options: [String: String] = [:]
        if reader.remaining >= 2 {
            let count = try Int(reader.readBEUInt16())
            for _ in 0 ..< count {
                let keyLen = try Int(reader.readBEUInt16())
                let keyData = try reader.readBytes(count: keyLen)
                let valLen = try Int(reader.readBEUInt16())
                let valData = try reader.readBytes(count: valLen)
                if let key = String(data: keyData, encoding: .utf8),
                   let val = String(data: valData, encoding: .utf8) {
                    options[key] = val
                }
            }
        }

        var extradata: Data?
        if reader.remaining >= 4 {
            let extraLen = try Int(reader.readBEUInt32())
            if extraLen > 0 {
                extradata = try reader.readBytes(count: extraLen)
            }
        }

        return ConfigureRequest(
            width: width,
            height: height,
            pixelFormat: pix,
            timebase: Timebase(num: tbNum, den: tbDen),
            frameRate: (num: frNum, den: frDen),
            options: options,
            extradata: extradata
        )
    }
}

public struct ConfigureAckResponse: Equatable, Sendable {
    public var status: UInt8
    public var extradata: Data
    public var pixelFormat: UInt8
    public var warnings: UInt8

    public func encode() -> Data {
        var writer = ByteWriter()
        writer.write(status)
        writer.writeBE(UInt16(clamping: extradata.count))
        writer.write(extradata)
        writer.write(pixelFormat)
        writer.write(warnings)
        return writer.data
    }
}

public struct ErrorResponse: Equatable, Sendable {
    public var code: UInt32
    public var message: String

    public func encode() -> Data {
        var writer = ByteWriter()
        writer.writeBE(code)
        writer.writeLengthPrefixedUTF8(message)
        return writer.data
    }
}
