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
    public var supportedCodecs: [String]
    public var warnings: UInt8

    public func encode() -> Data {
        var writer = ByteWriter()
        writer.write(status)
        // reserved for future fields (kept for wire compatibility)
        writer.writeBE(UInt16(0))
        writer.writeBE(UInt16(0))
        writer.write(UInt8(UInt8(clamping: supportedCodecs.count)))
        for codec in supportedCodecs {
            writer.writeLengthPrefixedUTF8(codec)
        }
        // Keep parity with legacy vtremoted: nal length size + something reserved.
        writer.writeBE(UInt16(4))
        writer.writeBE(UInt16(1))
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
