/*
 * H.264 VideoToolbox remote encoder (scaffolding)
 */

#include "config_components.h"

#include "avcodec.h"
#include "codec_internal.h"
#include "encode.h"
#include "libavutil/opt.h"
#include "vtremote_enc_common.h"

#define H264_PROFILE_CONSTRAINED_HIGH (AV_PROFILE_H264_HIGH | AV_PROFILE_H264_CONSTRAINED)

#define OFFSET(x) offsetof(VTRemoteEncContext, x)
#define ENC AV_OPT_FLAG_ENCODING_PARAM
#define VID AV_OPT_FLAG_VIDEO_PARAM
#define VE  AV_OPT_FLAG_VIDEO_PARAM | AV_OPT_FLAG_ENCODING_PARAM

static const AVOption vtremote_h264_options[] = {
    VTREMOTE_BASE_OPTIONS,
    { "profile", "Profile", OFFSET(profile), AV_OPT_TYPE_INT, { .i64 = AV_PROFILE_UNKNOWN }, AV_PROFILE_UNKNOWN, INT_MAX, VE, .unit = "profile" },
    { "baseline",             "Baseline Profile",             0, AV_OPT_TYPE_CONST, { .i64 = AV_PROFILE_H264_BASELINE             }, INT_MIN, INT_MAX, VE, .unit = "profile" },
    { "constrained_baseline", "Constrained Baseline Profile", 0, AV_OPT_TYPE_CONST, { .i64 = AV_PROFILE_H264_CONSTRAINED_BASELINE }, INT_MIN, INT_MAX, VE, .unit = "profile" },
    { "main",                 "Main Profile",                 0, AV_OPT_TYPE_CONST, { .i64 = AV_PROFILE_H264_MAIN                 }, INT_MIN, INT_MAX, VE, .unit = "profile" },
    { "high",                 "High Profile",                 0, AV_OPT_TYPE_CONST, { .i64 = AV_PROFILE_H264_HIGH                 }, INT_MIN, INT_MAX, VE, .unit = "profile" },
    { "constrained_high",     "Constrained High Profile",     0, AV_OPT_TYPE_CONST, { .i64 = H264_PROFILE_CONSTRAINED_HIGH        }, INT_MIN, INT_MAX, VE, .unit = "profile" },
    { "extended",             "Extend Profile",               0, AV_OPT_TYPE_CONST, { .i64 = AV_PROFILE_H264_EXTENDED             }, INT_MIN, INT_MAX, VE, .unit = "profile" },

    { "level", "Level", OFFSET(level), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, 52, VE, .unit = "level" },
    { "1.3", "Level 1.3, only available with Baseline Profile", 0, AV_OPT_TYPE_CONST, { .i64 = 13 }, INT_MIN, INT_MAX, VE, .unit = "level" },
    { "3.0", "Level 3.0", 0, AV_OPT_TYPE_CONST, { .i64 = 30 }, INT_MIN, INT_MAX, VE, .unit = "level" },
    { "3.1", "Level 3.1", 0, AV_OPT_TYPE_CONST, { .i64 = 31 }, INT_MIN, INT_MAX, VE, .unit = "level" },
    { "3.2", "Level 3.2", 0, AV_OPT_TYPE_CONST, { .i64 = 32 }, INT_MIN, INT_MAX, VE, .unit = "level" },
    { "4.0", "Level 4.0", 0, AV_OPT_TYPE_CONST, { .i64 = 40 }, INT_MIN, INT_MAX, VE, .unit = "level" },
    { "4.1", "Level 4.1", 0, AV_OPT_TYPE_CONST, { .i64 = 41 }, INT_MIN, INT_MAX, VE, .unit = "level" },
    { "4.2", "Level 4.2", 0, AV_OPT_TYPE_CONST, { .i64 = 42 }, INT_MIN, INT_MAX, VE, .unit = "level" },
    { "5.0", "Level 5.0", 0, AV_OPT_TYPE_CONST, { .i64 = 50 }, INT_MIN, INT_MAX, VE, .unit = "level" },
    { "5.1", "Level 5.1", 0, AV_OPT_TYPE_CONST, { .i64 = 51 }, INT_MIN, INT_MAX, VE, .unit = "level" },
    { "5.2", "Level 5.2", 0, AV_OPT_TYPE_CONST, { .i64 = 52 }, INT_MIN, INT_MAX, VE, .unit = "level" },

    { "coder", "Entropy coding", OFFSET(entropy), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, 2, VE, .unit = "coder" },
    { "cavlc", "CAVLC entropy coding", 0, AV_OPT_TYPE_CONST, { .i64 = 1 }, INT_MIN, INT_MAX, VE, .unit = "coder" },
    { "vlc",   "CAVLC entropy coding", 0, AV_OPT_TYPE_CONST, { .i64 = 1 }, INT_MIN, INT_MAX, VE, .unit = "coder" },
    { "cabac", "CABAC entropy coding", 0, AV_OPT_TYPE_CONST, { .i64 = 2 }, INT_MIN, INT_MAX, VE, .unit = "coder" },
    { "ac",    "CABAC entropy coding", 0, AV_OPT_TYPE_CONST, { .i64 = 2 }, INT_MIN, INT_MAX, VE, .unit = "coder" },

    { "a53cc", "Use A53 Closed Captions (if available)", OFFSET(a53_cc), AV_OPT_TYPE_BOOL, {.i64 = 1}, 0, 1, VE },

    { "constant_bit_rate", "Require constant bit rate (macOS 13 or newer)", OFFSET(constant_bit_rate), AV_OPT_TYPE_BOOL, { .i64 = 0 }, 0, 1, VE },
    { "max_slice_bytes", "Set the maximum number of bytes in an H.264 slice.", OFFSET(max_slice_bytes), AV_OPT_TYPE_INT, { .i64 = -1 }, -1, INT_MAX, VE },
    VTREMOTE_COMMON_VT_OPTIONS,
    { NULL },
};

static const AVClass vtremote_h264_class = {
    .class_name = "h264_videotoolbox_remote",
    .item_name  = av_default_item_name,
    .option     = vtremote_h264_options,
    .version    = LIBAVUTIL_VERSION_INT,
};

static const FFCodecDefault vtremote_defaults[] = {
    { "b",    "0" },
    { "qmin", "-1" },
    { "qmax", "-1" },
    { NULL },
};

static av_cold int vtremote_h264_init(AVCodecContext *avctx)
{
    return ff_vtremote_common_init(avctx);
}

static av_cold int vtremote_h264_close(AVCodecContext *avctx)
{
    return ff_vtremote_common_close(avctx);
}

const FFCodec ff_h264_videotoolbox_remote_encoder = {
    .p.name         = "h264_videotoolbox_remote",
    CODEC_LONG_NAME("H.264 (Remote VideoToolbox)"),
    .p.type         = AVMEDIA_TYPE_VIDEO,
    .p.id           = AV_CODEC_ID_H264,
    .p.capabilities = AV_CODEC_CAP_DELAY | AV_CODEC_CAP_DR1,
    .caps_internal  = FF_CODEC_CAP_INIT_CLEANUP,
    .defaults       = vtremote_defaults,
    .priv_data_size = sizeof(VTRemoteEncContext),
    .p.priv_class   = &vtremote_h264_class,
    .init           = vtremote_h264_init,
    .close          = vtremote_h264_close,
    FF_CODEC_ENCODE_CB(ff_vtremote_encode),
    CODEC_PIXFMTS(AV_PIX_FMT_NV12),
};
