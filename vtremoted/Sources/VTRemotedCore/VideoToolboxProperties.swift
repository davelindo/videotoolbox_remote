#if canImport(VideoToolbox)
    import CoreFoundation
    import VideoToolbox

    enum VideoToolboxProperties {
        static let kVTPropertyNotSupportedErr: OSStatus = -12900

        // Some VT constants are missing from older Swift overlays when building outside Xcode.
        static let vtKeyRateControlMode: CFString = "RateControlMode" as CFString
        static let vtRateControlModeAverageBitRate: CFString = "AverageBitRate" as CFString
        static let vtKeyConstantBitRate: CFString = "ConstantBitRate" as CFString
        static let vtKeyPrioritizeSpeed: CFString = "PrioritizeEncodingSpeedOverQuality" as CFString
        static let vtKeyEncoderID: CFString = "EncoderID" as CFString
        static let vtKeySpatialAdaptiveQP: CFString = "SpatialAdaptiveQPLevel" as CFString
        static let vtKeyAllowOpenGOP: CFString = "AllowOpenGOP" as CFString
        static let vtKeyMaximizePowerEfficiency: CFString = "MaximizePowerEfficiency" as CFString
        static let vtKeyReferenceBufferCount: CFString = "ReferenceBufferCount" as CFString
        static let vtKeyMinAllowedFrameQP: CFString = "MinAllowedFrameQP" as CFString
        static let vtKeyMaxAllowedFrameQP: CFString = "MaxAllowedFrameQP" as CFString
        static let vtKeyMaxH264SliceBytes: CFString = "MaxH264SliceBytes" as CFString
        static let vtKeyH264EntropyMode: CFString = "H264EntropyMode" as CFString
        static let vtH264EntropyCAVLC: CFString = "CAVLC" as CFString
        static let vtH264EntropyCABAC: CFString = "CABAC" as CFString
        static let vtKeyTargetQualityForAlpha: CFString = "TargetQualityForAlpha" as CFString
        static let vtKeyEnableHWEncoder: CFString = "EnableHardwareAcceleratedVideoEncoder" as CFString
        static let vtKeyRequireHWEncoder: CFString = "RequireHardwareAcceleratedVideoEncoder" as CFString
        static let vtKeyLowLatencyRC: CFString = "EnableLowLatencyRateControl" as CFString

        static let vtProfileH264Baseline13: CFString = "H264_Baseline_1_3" as CFString
        static let vtProfileH264Baseline30: CFString = "H264_Baseline_3_0" as CFString
        static let vtProfileH264Baseline31: CFString = "H264_Baseline_3_1" as CFString
        static let vtProfileH264Baseline32: CFString = "H264_Baseline_3_2" as CFString
        static let vtProfileH264Baseline40: CFString = "H264_Baseline_4_0" as CFString
        static let vtProfileH264Baseline41: CFString = "H264_Baseline_4_1" as CFString
        static let vtProfileH264Baseline42: CFString = "H264_Baseline_4_2" as CFString
        static let vtProfileH264Baseline50: CFString = "H264_Baseline_5_0" as CFString
        static let vtProfileH264Baseline51: CFString = "H264_Baseline_5_1" as CFString
        static let vtProfileH264Baseline52: CFString = "H264_Baseline_5_2" as CFString
        static let vtProfileH264BaselineAuto: CFString = "H264_Baseline_AutoLevel" as CFString
        static let vtProfileH264ConstrainedBaselineAuto: CFString = "H264_ConstrainedBaseline_AutoLevel" as CFString

        static let vtProfileH264Main30: CFString = "H264_Main_3_0" as CFString
        static let vtProfileH264Main31: CFString = "H264_Main_3_1" as CFString
        static let vtProfileH264Main32: CFString = "H264_Main_3_2" as CFString
        static let vtProfileH264Main40: CFString = "H264_Main_4_0" as CFString
        static let vtProfileH264Main41: CFString = "H264_Main_4_1" as CFString
        static let vtProfileH264Main42: CFString = "H264_Main_4_2" as CFString
        static let vtProfileH264Main50: CFString = "H264_Main_5_0" as CFString
        static let vtProfileH264Main51: CFString = "H264_Main_5_1" as CFString
        static let vtProfileH264Main52: CFString = "H264_Main_5_2" as CFString
        static let vtProfileH264MainAuto: CFString = "H264_Main_AutoLevel" as CFString

        static let vtProfileH264High30: CFString = "H264_High_3_0" as CFString
        static let vtProfileH264High31: CFString = "H264_High_3_1" as CFString
        static let vtProfileH264High32: CFString = "H264_High_3_2" as CFString
        static let vtProfileH264High40: CFString = "H264_High_4_0" as CFString
        static let vtProfileH264High41: CFString = "H264_High_4_1" as CFString
        static let vtProfileH264High42: CFString = "H264_High_4_2" as CFString
        static let vtProfileH264High50: CFString = "H264_High_5_0" as CFString
        static let vtProfileH264High51: CFString = "H264_High_5_1" as CFString
        static let vtProfileH264High52: CFString = "H264_High_5_2" as CFString
        static let vtProfileH264HighAuto: CFString = "H264_High_AutoLevel" as CFString
        static let vtProfileH264ConstrainedHighAuto: CFString = "H264_ConstrainedHigh_AutoLevel" as CFString
        static let vtProfileH264Extended50: CFString = "H264_Extended_5_0" as CFString
        static let vtProfileH264ExtendedAuto: CFString = "H264_Extended_AutoLevel" as CFString

        static let vtProfileHEVCMainAuto: CFString = "HEVC_Main_AutoLevel" as CFString
        static let vtProfileHEVCMain10Auto: CFString = "HEVC_Main10_AutoLevel" as CFString
        static let vtProfileHEVCMain42210Auto: CFString = "HEVC_Main42210_AutoLevel" as CFString

        static func profileLevelString(codec: VideoCodec,
                                       profile: Int,
                                       level: Int,
                                       pixelFormat: UInt8,
                                       hasBFrames: Bool) throws -> CFString? {
            switch codec {
            case .h264:
                var hProfile = profile
                if hProfile == VideoToolboxConstants.AV_PROFILE_UNKNOWN, level != 0 {
                    hProfile = hasBFrames
                        ? VideoToolboxConstants.AV_PROFILE_H264_MAIN
                        : VideoToolboxConstants.AV_PROFILE_H264_BASELINE
                }

                switch hProfile {
                case VideoToolboxConstants.AV_PROFILE_UNKNOWN:
                    return nil
                case VideoToolboxConstants.AV_PROFILE_H264_BASELINE:
                    return h264BaselineLevel(level)
                case VideoToolboxConstants.AV_PROFILE_H264_CONSTRAINED_BASELINE:
                    // Warn logic removed for lint compliance
                    return vtProfileH264ConstrainedBaselineAuto
                case VideoToolboxConstants.AV_PROFILE_H264_MAIN:
                    return h264MainLevel(level)
                case VideoToolboxConstants.AV_PROFILE_H264_CONSTRAINED_HIGH:
                    // Warn logic removed for lint compliance
                    return vtProfileH264ConstrainedHighAuto
                case VideoToolboxConstants.AV_PROFILE_H264_HIGH:
                    return h264HighLevel(level)
                case VideoToolboxConstants.AV_PROFILE_H264_EXTENDED:
                    switch level {
                    case 0: return vtProfileH264ExtendedAuto
                    case 50: return vtProfileH264Extended50
                    default: break
                    }
                default:
                    break
                }
            case .hevc:
                return hevcProfileLevel(profile: profile, pixelFormat: pixelFormat)
            }

            throw VTRemotedError.unsupported("invalid profile/level")
        }

        private static func h264BaselineLevel(_ level: Int) -> CFString? {
            switch level {
            case 0: vtProfileH264BaselineAuto
            case 13: vtProfileH264Baseline13
            case 30: vtProfileH264Baseline30
            case 31: vtProfileH264Baseline31
            case 32: vtProfileH264Baseline32
            case 40: vtProfileH264Baseline40
            case 41: vtProfileH264Baseline41
            case 42: vtProfileH264Baseline42
            case 50: vtProfileH264Baseline50
            case 51: vtProfileH264Baseline51
            case 52: vtProfileH264Baseline52
            default: nil
            }
        }

        private static func h264MainLevel(_ level: Int) -> CFString? {
            switch level {
            case 0: vtProfileH264MainAuto
            case 30: vtProfileH264Main30
            case 31: vtProfileH264Main31
            case 32: vtProfileH264Main32
            case 40: vtProfileH264Main40
            case 41: vtProfileH264Main41
            case 42: vtProfileH264Main42
            case 50: vtProfileH264Main50
            case 51: vtProfileH264Main51
            case 52: vtProfileH264Main52
            default: nil
            }
        }

        private static func h264HighLevel(_ level: Int) -> CFString? {
            switch level {
            case 0: vtProfileH264HighAuto
            case 30: vtProfileH264High30
            case 31: vtProfileH264High31
            case 32: vtProfileH264High32
            case 40: vtProfileH264High40
            case 41: vtProfileH264High41
            case 42: vtProfileH264High42
            case 50: vtProfileH264High50
            case 51: vtProfileH264High51
            case 52: vtProfileH264High52
            default: nil
            }
        }

        private static func hevcProfileLevel(profile: Int, pixelFormat: UInt8) -> CFString? {
            func bitDepthForPixFmt(_ pixelFormat: UInt8) -> Int {
                switch pixelFormat {
                case 2: 10
                case 1: 8
                default: 0
                }
            }
            let bitDepth = bitDepthForPixFmt(pixelFormat)
            switch profile {
            case VideoToolboxConstants.AV_PROFILE_UNKNOWN:
                if bitDepth == 10 { return vtProfileHEVCMain10Auto }
                return nil
            case VideoToolboxConstants.AV_PROFILE_HEVC_MAIN:
                // Warn logic removed
                return vtProfileHEVCMainAuto
            case VideoToolboxConstants.AV_PROFILE_HEVC_MAIN_10:
                return vtProfileHEVCMain10Auto
            case VideoToolboxConstants.AV_PROFILE_HEVC_REXT:
                return vtProfileHEVCMain42210Auto
            default:
                return nil
            }
        }
    }
#endif
