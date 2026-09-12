/* Public decoder API: simultaneous large input/output and terminal I/O errors. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "libavcodec/avcodec.h"
#include "libavutil/opt.h"

static int frames;
static int drain(AVCodecContext *decoder) {
    AVFrame *frame = av_frame_alloc();
    int ret;
    while ((ret = avcodec_receive_frame(decoder, frame)) >= 0) {
        assert(frame->pts == frames && frame->width == 64 && frame->height == 64);
        for (int plane = 0; plane < 2; ++plane) {
            int height = plane == 0 ? 64 : 32;
            int expected = plane == 0 ? frames + 16 : 128;
            for (int y = 0; y < height; ++y)
                for (int x = 0; x < 64; ++x)
                    assert(frame->data[plane][y * frame->linesize[plane] + x] == expected);
        }
        ++frames;
        av_frame_unref(frame);
    }
    av_frame_free(&frame);
    return ret;
}

int main(int argc, char **argv) {
    assert(argc == 5); /* endpoint, avcC fixture, expected failure, timeout ms */
    const AVCodec *codec = avcodec_find_decoder_by_name("h264_videotoolbox_remote");
    assert(codec);
    AVCodecContext *decoder = avcodec_alloc_context3(codec);
    decoder->width = decoder->height = 64;
    decoder->pix_fmt = AV_PIX_FMT_NV12;
    decoder->pkt_timebase = (AVRational){1, 30};
    decoder->extradata = av_mallocz(4096 + AV_INPUT_BUFFER_PADDING_SIZE);
    FILE *fixture = fopen(argv[2], "r");
    assert(fixture);
    unsigned byte;
    while (fscanf(fixture, "%2x", &byte) == 1) {
        assert(decoder->extradata_size < 4096);
        decoder->extradata[decoder->extradata_size++] = byte;
    }
    fclose(fixture);
    assert(av_opt_set(decoder->priv_data, "vt_remote_host", argv[1], 0) == 0);
    assert(av_opt_set_int(decoder->priv_data, "vt_remote_wire_compression", 0, 0) == 0);
    int timeout_ms = atoi(argv[4]);
    assert(timeout_ms > 0);
    assert(av_opt_set_int(decoder->priv_data, "vt_remote_timeout_ms", timeout_ms, 0) == 0);
    int ret = avcodec_open2(decoder, codec, NULL);
    assert(ret == 0);
    for (int index = 0; index < 3; ++index) {
        AVPacket *packet = av_packet_alloc();
        assert(av_new_packet(packet, 8 * 1024 * 1024) == 0);
        memset(packet->data, 1, packet->size);
        unsigned length = packet->size - 4;
        for (int n = 0; n < 4; ++n)
            packet->data[n] = length >> (24 - 8 * n);
        packet->data[4] = 0x65;
        packet->pts = packet->dts = index;
        packet->duration = 1;
        packet->flags = AV_PKT_FLAG_KEY;
        while ((ret = avcodec_send_packet(decoder, packet)) == AVERROR(EAGAIN)) {
            ret = drain(decoder);
            if (ret != AVERROR(EAGAIN))
                break;
        }
        av_packet_free(&packet);
        if (ret < 0)
            break;
        ret = drain(decoder);
        if (ret != AVERROR(EAGAIN))
            break;
    }
    if (ret == AVERROR(EAGAIN) || ret >= 0) {
        ret = avcodec_send_packet(decoder, NULL);
        if (ret >= 0)
            ret = drain(decoder);
    }
    int expected_failure = atoi(argv[3]);
    assert(expected_failure ? ret < 0 && ret != AVERROR_EOF && ret != AVERROR(EAGAIN)
                            : ret == AVERROR_EOF && frames == 3);
    avcodec_free_context(&decoder);
    puts(expected_failure ? "PASS explicit decoder transport failure"
                          : "PASS duplex decoder: all pixels, timestamps and frames");
    return 0;
}
