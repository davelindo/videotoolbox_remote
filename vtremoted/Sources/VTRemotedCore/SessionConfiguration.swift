import Foundation

public enum VideoCodec: String, Sendable {
    case h264
    case hevc
}

public enum SessionMode: String, Sendable {
    case encode
    case decode
}

public struct SessionConfiguration: Sendable {
    public var codec: VideoCodec
    public var mode: SessionMode
    public var width: Int
    public var height: Int
    public var pixelFormat: UInt8
    public var timebase: Timebase
    public var frameRate: (num: Int, den: Int)
    public var options: SessionOptions
    public var configExtradata: Data?

    public init(codec: VideoCodec, request: ConfigureRequest) throws {
        self.codec = codec
        mode = SessionMode(rawValue: request.options["mode"] ?? "encode") ?? .encode
        width = request.width
        height = request.height
        pixelFormat = request.pixelFormat
        timebase = request.timebase
        frameRate = request.frameRate
        options = SessionOptions(options: request.options)
        configExtradata = request.extradata
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

    public init(options: [String: String]) {
        func int(_ key: String, _ def: Int) -> Int { Int(options[key] ?? "") ?? def }
        func int64(_ key: String, _ def: Int64) -> Int64 { Int64(options[key] ?? "") ?? def }
        func bool(_ key: String) -> Bool { (options[key] ?? "0") != "0" }
        func double(_ key: String, _ def: Double) -> Double { Double(options[key] ?? "") ?? def }

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
    }
}
