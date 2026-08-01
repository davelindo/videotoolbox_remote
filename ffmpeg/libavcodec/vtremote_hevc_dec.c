/*
 * HEVC VideoToolbox remote decoder
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

static int vtremote_hevc_extradata_is_main10(const AVCodecContext *avctx)
{
    const uint8_t *data = avctx->extradata;
    const int size = avctx->extradata_size;

    if (!data || size < 2)
        return 0;

    /* HEVCDecoderConfigurationRecord: general_profile_idc is in byte 1. */
    if (data[0] == 1)
        return (data[1] & 0x1f) == AV_PROFILE_HEVC_MAIN_10;

    /* Annex B: profile_idc is the second SPS RBSP byte after the NAL header. */
    for (int i = 0; i + 7 < size; i++) {
        int start_code_size;
        if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1)
            start_code_size = 3;
        else if (data[i] == 0 && data[i + 1] == 0 &&
                 data[i + 2] == 0 && data[i + 3] == 1)
            start_code_size = 4;
        else
            continue;

        const int nal = i + start_code_size;
        if (nal + 3 < size && ((data[nal] >> 1) & 0x3f) == 33)
            return (data[nal + 3] & 0x1f) == AV_PROFILE_HEVC_MAIN_10;
    }

    return 0;
}

static av_cold int vtremote_hevc_dec_init(AVCodecContext *avctx)
{
    VTRemoteDecContext *s = avctx->priv_data;
    const int is_main10 = avctx->bits_per_raw_sample > 8 ||
                          avctx->profile == AV_PROFILE_HEVC_MAIN_10 ||
                          vtremote_hevc_extradata_is_main10(avctx);
    enum AVPixelFormat sw_fmt = is_main10 ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12;
#if CONFIG_VIDEOTOOLBOX && defined(__APPLE__)
    if (s->output_hw_frames) {
        /*
         * CONFIGURE_ACK runs before hw_frames_ctx allocation and corrects
         * sw_pix_fmt once the server reports the stream's actual output depth.
         */
        avctx->pix_fmt = AV_PIX_FMT_VIDEOTOOLBOX;
        avctx->sw_pix_fmt = sw_fmt;
        return ff_vtremote_dec_init(avctx);
    }
    static const enum AVPixelFormat pix_fmts_10_sw[] = {
        AV_PIX_FMT_P010LE,
        AV_PIX_FMT_NV12,
        AV_PIX_FMT_VIDEOTOOLBOX,
        AV_PIX_FMT_NONE,
    };
    static const enum AVPixelFormat pix_fmts_8_sw[] = {
        AV_PIX_FMT_NV12,
        AV_PIX_FMT_P010LE,
        AV_PIX_FMT_VIDEOTOOLBOX,
        AV_PIX_FMT_NONE,
    };
    const enum AVPixelFormat *pix_fmts =
        is_main10 ? pix_fmts_10_sw : pix_fmts_8_sw;
#else
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
    const enum AVPixelFormat *pix_fmts = is_main10 ? pix_fmts_10 : pix_fmts_8;
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
        avctx->sw_pix_fmt = sw_fmt;
    return ff_vtremote_dec_init(avctx);
}

static av_cold int vtremote_hevc_dec_close(AVCodecContext *avctx)
{
    return ff_vtremote_dec_close(avctx);
}

#if CONFIG_VIDEOTOOLBOX && defined(__APPLE__)
static const AVCodecHWConfigInternal *const vtremote_hevc_dec_hw_configs[] = {
    VTREMOTE_HW_CONFIG_DECODER_FRAMES(VIDEOTOOLBOX, VIDEOTOOLBOX),
    NULL
};
#endif

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
#if CONFIG_VIDEOTOOLBOX && defined(__APPLE__)
    .hw_configs     = vtremote_hevc_dec_hw_configs,
    CODEC_PIXFMTS(AV_PIX_FMT_NV12, AV_PIX_FMT_P010LE, AV_PIX_FMT_VIDEOTOOLBOX),
#else
    CODEC_PIXFMTS(AV_PIX_FMT_NV12, AV_PIX_FMT_P010LE),
#endif
};
