/*
 * HEVC VideoToolbox remote encoder (scaffolding)
 */

#include "config_components.h"

#include "avcodec.h"
#include "codec_internal.h"
#include "encode.h"
#include "libavutil/opt.h"
#include "vtremote_enc_common.h"

#define OFFSET(x) offsetof(VTRemoteEncContext, x)
#define ENC AV_OPT_FLAG_ENCODING_PARAM
#define VID AV_OPT_FLAG_VIDEO_PARAM
#define VE  AV_OPT_FLAG_VIDEO_PARAM | AV_OPT_FLAG_ENCODING_PARAM

static const AVOption vtremote_hevc_options[] = {
    VTREMOTE_BASE_OPTIONS,
    { "profile", "Profile", OFFSET(profile), AV_OPT_TYPE_INT, { .i64 = AV_PROFILE_UNKNOWN }, AV_PROFILE_UNKNOWN, INT_MAX, VE, .unit = "profile" },
    { "main",     "Main Profile",     0, AV_OPT_TYPE_CONST, { .i64 = AV_PROFILE_HEVC_MAIN    }, INT_MIN, INT_MAX, VE, .unit = "profile" },
    { "main10",   "Main10 Profile",   0, AV_OPT_TYPE_CONST, { .i64 = AV_PROFILE_HEVC_MAIN_10 }, INT_MIN, INT_MAX, VE, .unit = "profile" },
    { "main42210","Main 4:2:2 10 Profile",0, AV_OPT_TYPE_CONST, { .i64 = AV_PROFILE_HEVC_REXT }, INT_MIN, INT_MAX, VE, .unit = "profile" },
    { "rext",     "Main 4:2:2 10 Profile",0, AV_OPT_TYPE_CONST, { .i64 = AV_PROFILE_HEVC_REXT }, INT_MIN, INT_MAX, VE, .unit = "profile" },

    { "alpha_quality", "Compression quality for the alpha channel", OFFSET(alpha_quality), AV_OPT_TYPE_DOUBLE, { .dbl = 0.0 }, 0.0, 1.0, VE },

    { "constant_bit_rate", "Require constant bit rate (macOS 13 or newer)", OFFSET(constant_bit_rate), AV_OPT_TYPE_BOOL, { .i64 = 0 }, 0, 1, VE },

    VTREMOTE_COMMON_VT_OPTIONS,
    { NULL },
};

static const AVClass vtremote_hevc_class = {
    .class_name = "hevc_videotoolbox_remote",
    .item_name  = av_default_item_name,
    .option     = vtremote_hevc_options,
    .version    = LIBAVUTIL_VERSION_INT,
};

static const FFCodecDefault vtremote_defaults[] = {
    { "b",    "0" },
    { "qmin", "-1" },
    { "qmax", "-1" },
    { NULL },
};

static av_cold int vtremote_hevc_init(AVCodecContext *avctx)
{
    return ff_vtremote_common_init(avctx);
}

static av_cold int vtremote_hevc_close(AVCodecContext *avctx)
{
    return ff_vtremote_common_close(avctx);
}

const FFCodec ff_hevc_videotoolbox_remote_encoder = {
    .p.name         = "hevc_videotoolbox_remote",
    CODEC_LONG_NAME("HEVC (Remote VideoToolbox)"),
    .p.type         = AVMEDIA_TYPE_VIDEO,
    .p.id           = AV_CODEC_ID_HEVC,
    .p.capabilities = AV_CODEC_CAP_DELAY | AV_CODEC_CAP_DR1,
    .caps_internal  = FF_CODEC_CAP_INIT_CLEANUP,
    .defaults       = vtremote_defaults,
    .priv_data_size = sizeof(VTRemoteEncContext),
    .p.priv_class   = &vtremote_hevc_class,
    .init           = vtremote_hevc_init,
    .close          = vtremote_hevc_close,
    FF_CODEC_ENCODE_CB(ff_vtremote_encode),
    CODEC_PIXFMTS(AV_PIX_FMT_NV12, AV_PIX_FMT_P010LE),
};
