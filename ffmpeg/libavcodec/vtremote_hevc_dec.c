/*
 * HEVC VideoToolbox remote decoder
 */

#include "config_components.h"

#include "avcodec.h"
#include "codec_internal.h"
#include "decode.h"
#include "libavutil/opt.h"
#include "vtremote_dec_common.h"

#define OFFSET(x) offsetof(VTRemoteDecContext, x)
#define DEC AV_OPT_FLAG_DECODING_PARAM
#define VID AV_OPT_FLAG_VIDEO_PARAM
#define VD  AV_OPT_FLAG_VIDEO_PARAM | AV_OPT_FLAG_DECODING_PARAM

static const AVOption vtremote_hevc_dec_options[] = {
    VTREMOTE_BASE_OPTIONS,
    { NULL },
};

static const AVClass vtremote_hevc_dec_class = {
    .class_name = "hevc_videotoolbox_remote",
    .item_name  = av_default_item_name,
    .option     = vtremote_hevc_dec_options,
    .version    = LIBAVUTIL_VERSION_INT,
};

static av_cold int vtremote_hevc_dec_init(AVCodecContext *avctx)
{
    static const enum AVPixelFormat pix_fmts_10[] = {
        AV_PIX_FMT_P010LE,
        AV_PIX_FMT_NV12,
        AV_PIX_FMT_NONE,
    };
    static const enum AVPixelFormat pix_fmts_8[] = {
        AV_PIX_FMT_NV12,
        AV_PIX_FMT_P010LE,
        AV_PIX_FMT_NONE,
    };
    const enum AVPixelFormat *pix_fmts = (avctx->bits_per_raw_sample > 8) ? pix_fmts_10 : pix_fmts_8;
    int ret = ff_get_format(avctx, pix_fmts);
    if (ret < 0)
        return ret;
    avctx->pix_fmt = ret;
    return ff_vtremote_dec_init(avctx);
}

static av_cold int vtremote_hevc_dec_close(AVCodecContext *avctx)
{
    return ff_vtremote_dec_close(avctx);
}

const FFCodec ff_hevc_videotoolbox_remote_decoder = {
    .p.name         = "hevc_videotoolbox_remote",
    CODEC_LONG_NAME("HEVC (Remote VideoToolbox)"),
    .p.type         = AVMEDIA_TYPE_VIDEO,
    .p.id           = AV_CODEC_ID_HEVC,
    .p.capabilities = AV_CODEC_CAP_DELAY,
    .caps_internal  = FF_CODEC_CAP_INIT_CLEANUP,
    .bsfs           = "hevc_mp4toannexb",
    .priv_data_size = sizeof(VTRemoteDecContext),
    .p.priv_class   = &vtremote_hevc_dec_class,
    .init           = vtremote_hevc_dec_init,
    .close          = vtremote_hevc_dec_close,
    FF_CODEC_DECODE_CB(ff_vtremote_decode),
    CODEC_PIXFMTS(AV_PIX_FMT_NV12, AV_PIX_FMT_P010LE),
};
