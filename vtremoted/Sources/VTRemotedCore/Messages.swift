import Foundation

public struct HelloRequest: Equatable, Sendable {
    public var token: String
    public var codec: String
    public var clientName: String
    public var build: String

    public static func decode(_ payload: Data) throws -> HelloRequest {
        var r = ByteReader(payload)
        return HelloRequest(
            token: try r.readLengthPrefixedUTF8(),
            codec: try r.readLengthPrefixedUTF8(),
            clientName: try r.readLengthPrefixedUTF8(),
            build: try r.readLengthPrefixedUTF8()
        )
    }
}

public struct HelloAckResponse: Equatable, Sendable {
    public var status: UInt8
    public var supportedCodecs: [String]
    public var warnings: UInt8

    public func encode() -> Data {
        var w = ByteWriter()
        w.write(status)
        // reserved for future fields (kept for wire compatibility)
        w.writeBE(UInt16(0))
        w.writeBE(UInt16(0))
        w.write(UInt8(UInt8(clamping: supportedCodecs.count)))
        for codec in supportedCodecs {
            w.writeLengthPrefixedUTF8(codec)
        }
        // Keep parity with legacy vtremoted: nal length size + something reserved.
        w.writeBE(UInt16(4))
        w.writeBE(UInt16(1))
        return w.data
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
        var r = ByteReader(payload)
        let width = Int(try r.readBEUInt32())
        let height = Int(try r.readBEUInt32())
        let pix = try r.readUInt8()
        let tbNum = Int(try r.readBEUInt32())
        let tbDen = Int(try r.readBEUInt32())
        let frNum = Int(try r.readBEUInt32())
        let frDen = Int(try r.readBEUInt32())

        var options: [String: String] = [:]
        if r.remaining >= 2 {
            let count = Int(try r.readBEUInt16())
            for _ in 0..<count {
                let kLen = Int(try r.readBEUInt16())
                let k = try r.readBytes(count: kLen)
                let vLen = Int(try r.readBEUInt16())
                let v = try r.readBytes(count: vLen)
                if let key = String(data: k, encoding: .utf8),
                   let val = String(data: v, encoding: .utf8) {
                    options[key] = val
                }
            }
        }

        var extradata: Data?
        if r.remaining >= 4 {
            let extraLen = Int(try r.readBEUInt32())
            if extraLen > 0 {
                extradata = try r.readBytes(count: extraLen)
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
        var w = ByteWriter()
        w.write(status)
        w.writeBE(UInt16(clamping: extradata.count))
        w.write(extradata)
        w.write(pixelFormat)
        w.write(warnings)
        return w.data
    }
}

public struct ErrorResponse: Equatable, Sendable {
    public var code: UInt32
    public var message: String

    public func encode() -> Data {
        var w = ByteWriter()
        w.writeBE(code)
        w.writeLengthPrefixedUTF8(message)
        return w.data
    }
}
