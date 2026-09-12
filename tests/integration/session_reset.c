/* Public-API regression: reuse drained contexts and abandon pending output. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "libavcodec/avcodec.h"
#include "libavcodec/bsf.h"
#include "libavformat/avformat.h"
#include "libavutil/adler32.h"
#include "libavutil/opt.h"
#include "libavutil/pixdesc.h"

static void check(int result) {
    if (result < 0) {
        fprintf(stderr, "API failed: %s\n", av_err2str(result));
        exit(1);
    }
}

typedef struct Output {
    int count;
    int64_t pts[512];
    uint32_t hash[512];
} Output;

static int receive(AVCodecContext *decoder, AVBSFContext *bsf, Output *output) {
    AVFrame *frame = av_frame_alloc();
    AVPacket *packet = av_packet_alloc();
    int result;
    while ((result = decoder ? avcodec_receive_frame(decoder, frame)
                             : av_bsf_receive_packet(bsf, packet)) >= 0) {
        unsigned hash = 1;
        assert(output->count < 512);
        output->pts[output->count] = decoder ? frame->pts : packet->pts;
        if (decoder) {
            const AVPixFmtDescriptor *description = av_pix_fmt_desc_get(frame->format);
            int row_bytes = frame->width * (description->comp[0].depth > 8 ? 2 : 1);
            for (int plane = 0; plane < 2; ++plane)
                for (int row = 0; row < (plane ? (frame->height + 1) / 2 : frame->height); ++row)
                    hash = av_adler32_update(
                        hash, frame->data[plane] + row * frame->linesize[plane], row_bytes);
        }
        output->hash[output->count++] = hash;
        av_frame_unref(frame);
        av_packet_unref(packet);
    }
    av_frame_free(&frame);
    av_packet_free(&packet);
    assert(result == AVERROR(EAGAIN) || result == AVERROR_EOF);
    return result;
}

int main(int argc, char **argv) {
    AVFormatContext *input = NULL;
    AVCodecContext *decoder = NULL;
    AVBSFContext *bsf = NULL;
    AVPacket *packets[512] = {0};
    Output baseline = {0};
    int count = 0, stream;
    assert(argc == 4); /* mode, input file, disposable server */
    check(avformat_open_input(&input, argv[2], NULL, NULL));
    check(avformat_find_stream_info(input, NULL));
    check(stream = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0));
    for (;;) {
        AVPacket *packet = av_packet_alloc();
        int result = av_read_frame(input, packet);
        if (result < 0) {
            av_packet_free(&packet);
            assert(result == AVERROR_EOF);
            break;
        }
        if (packet->stream_index == stream) {
            assert(count < 512);
            packets[count++] = packet;
        } else {
            av_packet_free(&packet);
        }
    }
    assert(count >= 8 && (packets[0]->flags & AV_PKT_FLAG_KEY));
    if (!strcmp(argv[1], "decode")) {
        const char *name = input->streams[stream]->codecpar->codec_id == AV_CODEC_ID_HEVC
                               ? "hevc_videotoolbox_remote"
                               : "h264_videotoolbox_remote";
        const AVCodec *codec = avcodec_find_decoder_by_name(name);
        assert(codec);
        decoder = avcodec_alloc_context3(codec);
        check(avcodec_parameters_to_context(decoder, input->streams[stream]->codecpar));
        decoder->pkt_timebase = input->streams[stream]->time_base;
        check(av_opt_set(decoder->priv_data, "vt_remote_host", argv[3], 0));
        check(avcodec_open2(decoder, codec, NULL));
    } else {
        check(av_bsf_alloc(av_bsf_get_by_name("vtremote_transcode"), &bsf));
        check(avcodec_parameters_copy(bsf->par_in, input->streams[stream]->codecpar));
        bsf->time_base_in = input->streams[stream]->time_base;
        check(av_opt_set(bsf->priv_data, "vt_remote_host", argv[3], 0));
        check(av_opt_set(bsf->priv_data, "vt_remote_out_codec", "h264", 0));
        check(av_bsf_init(bsf));
    }
    for (int pass = 0; pass < 4; ++pass) {
        Output output = {0};
        if (pass) {
            if (decoder)
                avcodec_flush_buffers(decoder);
            else
                av_bsf_flush(bsf);
        }
        int limit = pass == 2 ? 4 : count;
        for (int i = 0; i < limit; ++i) {
            AVPacket *packet = av_packet_clone(packets[i]);
            int result;
            while ((result = decoder ? avcodec_send_packet(decoder, packet)
                                     : av_bsf_send_packet(bsf, packet)) == AVERROR(EAGAIN))
                receive(decoder, bsf, &output);
            check(result);
            av_packet_free(&packet);
            if (pass != 2)
                receive(decoder, bsf, &output);
        }
        if (pass == 2)
            continue; /* seek while the old session still has output */
        check(decoder ? avcodec_send_packet(decoder, NULL) : av_bsf_send_packet(bsf, NULL));
        assert(receive(decoder, bsf, &output) == AVERROR_EOF);
        assert(output.count == count);
        if (!pass)
            baseline = output;
        else {
            assert(!memcmp(baseline.pts, output.pts, count * sizeof(int64_t)));
            assert(!memcmp(baseline.hash, output.hash, count * sizeof(uint32_t)));
        }
        printf("PASS %s pass=%d count=%d; timestamps%s match\n", argv[1], pass, count,
               !strcmp(argv[1], "decode") ? " and pixels" : "");
    }
    for (int i = 0; i < count; ++i)
        av_packet_free(&packets[i]);
    avcodec_free_context(&decoder);
    av_bsf_free(&bsf);
    avformat_close_input(&input);
    return 0;
}
