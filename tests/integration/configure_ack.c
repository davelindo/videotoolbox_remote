/* Public codec/BSF APIs: malformed server avcC must fail configuration. */
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavcodec/bsf.h"
#include "libavutil/opt.h"

int main(int argc, char **argv)
{
    assert(argc == 4); /* encoder|transcode, endpoint, valid|invalid|truncated */
    int result;
    if (!strcmp(argv[1], "encoder")) {
        const AVCodec *codec = avcodec_find_encoder_by_name("h264_videotoolbox_remote");
        assert(codec);
        AVCodecContext *encoder = avcodec_alloc_context3(codec);
        assert(encoder);
        encoder->width = encoder->height = 64;
        encoder->pix_fmt = AV_PIX_FMT_NV12;
        encoder->time_base = (AVRational){1, 30};
        encoder->framerate = (AVRational){30, 1};
        assert(av_opt_set(encoder->priv_data, "vt_remote_host", argv[2], 0) == 0);
        result = avcodec_open2(encoder, codec, NULL);
        avcodec_free_context(&encoder);
    } else {
        AVBSFContext *bsf = NULL;
        const AVBitStreamFilter *filter = av_bsf_get_by_name("vtremote_transcode");
        assert(filter && av_bsf_alloc(filter, &bsf) == 0);
        bsf->par_in->codec_type = AVMEDIA_TYPE_VIDEO;
        bsf->par_in->codec_id = AV_CODEC_ID_H264;
        bsf->par_in->width = bsf->par_in->height = 64;
        bsf->time_base_in = (AVRational){1, 30};
        assert(av_opt_set(bsf->priv_data, "vt_remote_host", argv[2], 0) == 0);
        result = av_bsf_init(bsf);
        av_bsf_free(&bsf);
    }
    if (!strcmp(argv[3], "valid"))
        assert(result >= 0);
    else {
        int expected = !strcmp(argv[3], "truncated") ? AVERROR(EINVAL) : AVERROR_INVALIDDATA;
        if (result != expected) {
            fprintf(stderr, "Expected configuration error %s, got %s\n",
                    av_err2str(expected), av_err2str(result));
            return 1;
        }
    }
    return 0;
}
