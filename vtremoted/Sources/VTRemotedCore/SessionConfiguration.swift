import Foundation

public enum VideoCodec: String, Sendable {
    case h264
    case hevc
}

public enum SessionMode: String, Sendable {
    case encode
    case decode
    case transcode
}

public enum TranscodeScaleMode: String, Sendable {
    case stretch
    case aspect
    case aspectFill
}

public struct SessionConfiguration: Sendable {
    public var codec: VideoCodec
    public var outputCodec: VideoCodec
    public var mode: SessionMode
    public var width: Int
    public var height: Int
    public var outputWidth: Int
    public var outputHeight: Int
    public var scaleMode: TranscodeScaleMode
    public var pixelFormat: UInt8
    public var timebase: Timebase
    public var frameRate: (num: Int, den: Int)
    public var options: SessionOptions
    public var configExtradata: Data?
    let maxFrameBytes: Int

    private static func checkedProduct(_ lhs: Int, _ rhs: Int, field: String) throws -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow, value > 0 else {
            throw VTRemotedError.unsupported("\(field) is too large")
        }
        return value
    }

    private static func validateDimensions(width: Int, height: Int, field: String) throws {
        guard width > 0, height > 0,
              width <= Int(Int32.max), height <= Int(Int32.max)
        else {
            throw VTRemotedError.unsupported("\(field) dimensions are invalid")
        }
    }

    private static func validateFrameSize(
        width: Int,
        height: Int,
        pixelFormat: UInt8,
        maxFrameBytes: Int,
        field: String
    ) throws {
        let rowBytes: Int
        let totalRows: Int
        switch pixelFormat {
        case VTRPixelFormat.nv12:
            rowBytes = width
            totalRows = height + ((height + 1) / 2)
        case VTRPixelFormat.p010:
            rowBytes = try checkedProduct(width, 2, field: field)
            totalRows = height + ((height + 1) / 2)
        case VTRPixelFormat.bgra, VTRPixelFormat.ayuv:
            rowBytes = try checkedProduct(width, 4, field: field)
            totalRows = height
        case VTRPixelFormat.p210:
            rowBytes = try checkedProduct(width, 2, field: field)
            totalRows = try checkedProduct(height, 2, field: field)
        default:
            throw VTRemotedError.unsupported("pixel_format=\(pixelFormat)")
        }

        let bytes = try checkedProduct(rowBytes, totalRows, field: field)
        guard bytes <= maxFrameBytes else {
            throw VTRemotedError.unsupported("\(field) exceeds max frame bytes")
        }
    }

    private static func parsePositiveDimensionPair(width: String?, height: String?) throws -> (Int, Int)? {
        guard width != nil || height != nil else { return nil }
        guard let widthValue = Int(width ?? ""), widthValue > 0,
              let heightValue = Int(height ?? ""), heightValue > 0
        else {
            throw VTRemotedError.unsupported("out_width/out_height must be positive")
        }
        return (widthValue, heightValue)
    }

    private static func parseScaleMode(_ rawValue: String?) throws -> TranscodeScaleMode {
        let normalized = (rawValue ?? "stretch").lowercased()
        switch normalized {
        case "stretch", "resize", "scale":
            return .stretch
        case "aspect", "fit", "letterbox":
            return .aspect
        case "aspect_fill", "aspectfill", "fill", "crop":
            return .aspectFill
        default:
            throw VTRemotedError.unsupported("scale_mode=\(normalized)")
        }
    }

    public init(
        codec: VideoCodec,
        request: ConfigureRequest,
        maxFrameBytes: Int = 256 * 1024 * 1024
    ) throws {
        let frameLimit = max(1, maxFrameBytes)
        try Self.validateDimensions(width: request.width, height: request.height, field: "input")
        guard request.timebase.den <= Int(Int32.max) else {
            throw VTRemotedError.unsupported("timebase denominator is too large")
        }
        self.codec = codec
        let modeRaw = request.options["mode"] ?? "encode"
        guard let parsedMode = SessionMode(rawValue: modeRaw) else {
            throw VTRemotedError.unsupported("mode=\(modeRaw)")
        }
        mode = parsedMode
        guard request.frameRate.den > 0,
              mode != .encode || request.frameRate.num > 0
        else {
            throw VTRemotedError.unsupported("frame rate is invalid")
        }
        if let outCodecRaw = request.options["out_codec"] {
            guard let parsed = VideoCodec(rawValue: outCodecRaw) else {
                throw VTRemotedError.unsupported("out_codec=\(outCodecRaw)")
            }
            outputCodec = parsed
        } else {
            outputCodec = codec
        }
        width = request.width
        height = request.height
        let outWidthOpt = request.options["out_width"]
        let outHeightOpt = request.options["out_height"]
        let scaleModeOpt = request.options["scale_mode"]
        if mode == .transcode {
            if let outputSize = try Self.parsePositiveDimensionPair(width: outWidthOpt, height: outHeightOpt) {
                outputWidth = outputSize.0
                outputHeight = outputSize.1
            } else {
                outputWidth = width
                outputHeight = height
            }

            scaleMode = try Self.parseScaleMode(scaleModeOpt)
        } else {
            if outWidthOpt != nil || outHeightOpt != nil || scaleModeOpt != nil {
                throw VTRemotedError.unsupported("scale options require transcode mode")
            }
            outputWidth = width
            outputHeight = height
            scaleMode = .stretch
        }
        pixelFormat = request.pixelFormat
        timebase = request.timebase
        frameRate = request.frameRate
        options = SessionOptions(options: request.options)
        configExtradata = request.extradata
        self.maxFrameBytes = frameLimit

        try Self.validateFrameSize(
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            maxFrameBytes: frameLimit,
            field: "input frame"
        )
        try Self.validateDimensions(width: outputWidth, height: outputHeight, field: "output")
        try Self.validateFrameSize(
            width: outputWidth,
            height: outputHeight,
            pixelFormat: pixelFormat,
            maxFrameBytes: frameLimit,
            field: "output frame"
        )
    }
}

public struct SessionOptions: Equatable, Sendable {
    public var bitrate: Int
    public var maxRate: Int
    public var gop: Int
    public var maxBFrames: Int
    public var flags: Int64
    public var globalQuality: Int
    public var qmin: Int
    public var qmax: Int
    public var profile: Int
    public var level: Int
    public var entropy: Int
    public var allowSoftware: Bool
    public var requireSoftware: Bool
    public var realtime: Int
    public var framesBefore: Bool
    public var framesAfter: Bool
    public var prioritizeSpeed: Int
    public var powerEfficient: Int
    public var spatialAQ: Int
    public var maxReferenceFrames: Int
    public var maxSliceBytes: Int
    public var constantBitRate: Bool
    public var alphaQuality: Double
    public var colorRange: Int
    public var colorSpace: Int
    public var colorPrimaries: Int
    public var colorTRC: Int
    public var sarNum: Int
    public var sarDen: Int
    public var a53CC: Int
    public var wireCompression: Int
    public var decodeAsync: Int
    public var decodeReorderDepth: Int
    public var packetAckV1: Bool

    public init(options: [String: String]) {
        func int(_ key: String, _ def: Int) -> Int {
            Int(options[key] ?? "") ?? def
        }
        func int64(_ key: String, _ def: Int64) -> Int64 {
            Int64(options[key] ?? "") ?? def
        }
        func bool(_ key: String) -> Bool {
            (options[key] ?? "0") != "0"
        }
        func double(_ key: String, _ def: Double) -> Double {
            Double(options[key] ?? "") ?? def
        }

        bitrate = int("bitrate", 0)
        maxRate = int("maxrate", 0)
        gop = int("gop", 0)
        maxBFrames = int("max_b_frames", 0)
        flags = int64("flags", 0)
        globalQuality = int("global_quality", 0)
        qmin = int("qmin", -1)
        qmax = int("qmax", -1)
        profile = int("profile", -99)
        level = int("level", 0)
        entropy = int("entropy", 0)
        allowSoftware = bool("allow_sw")
        requireSoftware = bool("require_sw")
        realtime = int("realtime", -1)
        framesBefore = bool("frames_before")
        framesAfter = bool("frames_after")
        prioritizeSpeed = int("prio_speed", -1)
        powerEfficient = int("power_efficient", -1)
        spatialAQ = int("spatial_aq", -1)
        maxReferenceFrames = int("max_ref_frames", 0)
        maxSliceBytes = int("max_slice_bytes", -1)
        constantBitRate = bool("constant_bit_rate")
        alphaQuality = double("alpha_quality", 0.0)
        colorRange = int("color_range", 0)
        colorSpace = int("colorspace", 2)
        colorPrimaries = int("color_primaries", 2)
        colorTRC = int("color_trc", 2)
        sarNum = int("sar_num", 0)
        sarDen = int("sar_den", 0)
        a53CC = int("a53_cc", -1)
        wireCompression = int("wire_compression", 0)
        decodeAsync = int("decode_async", 1)
        decodeReorderDepth = int("decode_reorder_depth", 2)
        packetAckV1 = bool("packet_ack.v1")
    }
}
