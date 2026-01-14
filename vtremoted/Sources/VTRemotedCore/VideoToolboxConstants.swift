#if canImport(VideoToolbox)
    import Foundation

    // swiftlint:disable identifier_name
    // FFmpeg constants mirrored for parity with videotoolboxenc.c.
    enum VideoToolboxConstants {
        static let AV_PROFILE_UNKNOWN = -99
        static let AV_PROFILE_H264_CONSTRAINED: Int = 1 << 9
        static let AV_PROFILE_H264_BASELINE = 66
        static let AV_PROFILE_H264_CONSTRAINED_BASELINE = AV_PROFILE_H264_BASELINE | AV_PROFILE_H264_CONSTRAINED
        static let AV_PROFILE_H264_MAIN = 77
        static let AV_PROFILE_H264_EXTENDED = 88
        static let AV_PROFILE_H264_HIGH = 100
        static let AV_PROFILE_H264_CONSTRAINED_HIGH = AV_PROFILE_H264_HIGH | AV_PROFILE_H264_CONSTRAINED

        static let AV_PROFILE_HEVC_MAIN = 1
        static let AV_PROFILE_HEVC_MAIN_10 = 2
        static let AV_PROFILE_HEVC_REXT = 4

        static let AV_CODEC_FLAG_QSCALE: Int64 = 1 << 1
        static let AV_CODEC_FLAG_LOW_DELAY: Int64 = 1 << 19
        static let AV_CODEC_FLAG_CLOSED_GOP: Int64 = 1 << 31

        static let AVCOL_RANGE_UNSPECIFIED = 0
        static let AVCOL_RANGE_MPEG = 1
        static let AVCOL_RANGE_JPEG = 2

        static let AVCOL_SPC_BT709 = 1
        static let AVCOL_SPC_UNSPECIFIED = 2
        static let AVCOL_SPC_BT470BG = 5
        static let AVCOL_SPC_SMPTE170M = 6
        static let AVCOL_SPC_SMPTE240M = 7
        static let AVCOL_SPC_BT2020_NCL = 9
        static let AVCOL_SPC_BT2020_CL = 10

        static let AVCOL_PRI_BT709 = 1
        static let AVCOL_PRI_UNSPECIFIED = 2
        static let AVCOL_PRI_BT470BG = 5
        static let AVCOL_PRI_SMPTE170M = 6
        static let AVCOL_PRI_BT2020 = 9

        static let AVCOL_TRC_BT709 = 1
        static let AVCOL_TRC_UNSPECIFIED = 2
        static let AVCOL_TRC_GAMMA22 = 4
        static let AVCOL_TRC_GAMMA28 = 5
        static let AVCOL_TRC_SMPTE240M = 7
        static let AVCOL_TRC_BT2020_10 = 14
        static let AVCOL_TRC_BT2020_12 = 15
        static let AVCOL_TRC_SMPTE2084 = 16
        static let AVCOL_TRC_SMPTE428 = 17
        static let AVCOL_TRC_ARIB_STD_B67 = 18

        static let FF_QP2LAMBDA: Float = 118.0
        static let kVTQPModulationLevel_Default: Int32 = -1
        static let kVTQPModulationLevel_Disable: Int32 = 0
    }
    // swiftlint:enable identifier_name
#endif
