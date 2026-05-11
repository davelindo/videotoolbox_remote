/*
 * H.264 VideoToolbox remote decoder
 */

#include "config_components.h"

#include "avcodec.h"
#include "codec_internal.h"
#include "decode.h"
#include "hwconfig.h"
#include "libavutil/opt.h"
#include "vtremote_dec_common.h"

#define OFFSET(x) offsetof(VTRemoteDecContext, x)
#define DEC AV_OPT_FLAG_DECODING_PARAM
#define VID AV_OPT_FLAG_VIDEO_PARAM
#define VD  AV_OPT_FLAG_VIDEO_PARAM | AV_OPT_FLAG_DECODING_PARAM

static const AVOption vtremote_h264_dec_options[] = {
    VTREMOTE_BASE_OPTIONS,
    { NULL },
};

static const AVClass vtremote_h264_dec_class = {
    .class_name = "h264_videotoolbox_remote",
    .item_name  = av_default_item_name,
    .option     = vtremote_h264_dec_options,
    .version    = LIBAVUTIL_VERSION_INT,
};

static av_cold int vtremote_h264_dec_init(AVCodecContext *avctx)
{
    VTRemoteDecContext *s = avctx->priv_data;
#if CONFIG_VIDEOTOOLBOX && defined(__APPLE__)
    if (s->output_hw_frames) {
        avctx->pix_fmt = AV_PIX_FMT_VIDEOTOOLBOX;
        avctx->sw_pix_fmt = AV_PIX_FMT_NV12;
        return ff_vtremote_dec_init(avctx);
    }
    static const enum AVPixelFormat pix_fmts_sw[] = {
        AV_PIX_FMT_NV12,
        AV_PIX_FMT_VIDEOTOOLBOX,
        AV_PIX_FMT_NONE,
    };
    const enum AVPixelFormat *pix_fmts = pix_fmts_sw;
#else
    static const enum AVPixelFormat pix_fmts[] = {
        AV_PIX_FMT_NV12,
        AV_PIX_FMT_NONE,
    };
    if (s->output_hw_frames) {
        av_log(avctx, AV_LOG_ERROR,
               "VideoToolbox hardware-frame decode output requires macOS "
               "VideoToolbox support.\n");
        return AVERROR(ENOSYS);
    }
#endif
    int ret = ff_get_format(avctx, pix_fmts);
    if (ret < 0)
        return ret;
    avctx->pix_fmt = ret;
    if (avctx->pix_fmt == AV_PIX_FMT_VIDEOTOOLBOX)
        avctx->sw_pix_fmt = AV_PIX_FMT_NV12;
    return ff_vtremote_dec_init(avctx);
}

static av_cold int vtremote_h264_dec_close(AVCodecContext *avctx)
{
    return ff_vtremote_dec_close(avctx);
}

#if CONFIG_VIDEOTOOLBOX && defined(__APPLE__)
static const AVCodecHWConfigInternal *const vtremote_h264_dec_hw_configs[] = {
    VTREMOTE_HW_CONFIG_DECODER_FRAMES(VIDEOTOOLBOX, VIDEOTOOLBOX),
    NULL
};
#endif

const FFCodec ff_h264_videotoolbox_remote_decoder = {
    .p.name         = "h264_videotoolbox_remote",
    CODEC_LONG_NAME("H.264 (Remote VideoToolbox)"),
    .p.type         = AVMEDIA_TYPE_VIDEO,
    .p.id           = AV_CODEC_ID_H264,
    .p.capabilities = AV_CODEC_CAP_DELAY,
    .caps_internal  = FF_CODEC_CAP_INIT_CLEANUP,
    .bsfs           = "h264_mp4toannexb",
    .priv_data_size = sizeof(VTRemoteDecContext),
    .p.priv_class   = &vtremote_h264_dec_class,
    .init           = vtremote_h264_dec_init,
    .close          = vtremote_h264_dec_close,
    FF_CODEC_DECODE_CB(ff_vtremote_decode),
#if CONFIG_VIDEOTOOLBOX && defined(__APPLE__)
    .hw_configs     = vtremote_h264_dec_hw_configs,
    CODEC_PIXFMTS(AV_PIX_FMT_NV12, AV_PIX_FMT_VIDEOTOOLBOX),
#else
    CODEC_PIXFMTS(AV_PIX_FMT_NV12),
#endif
};
