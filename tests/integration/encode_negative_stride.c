/* Public encoder API: signed source strides and padded image planes. */
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavutil/imgutils.h"
#include "libavutil/intreadwrite.h"
#include "libavutil/opt.h"
#include "libavutil/pixdesc.h"

#define WIDTH 34
#define HEIGHT 18
#define FRAME_COUNT 4

static int output_count;

static void check(int result)
{
    if (result < 0) {
        fprintf(stderr, "API failed: %s\n", av_err2str(result));
        exit(1);
    }
}

static AVFrame *make_frame(enum AVPixelFormat format, int index)
{
    const AVPixFmtDescriptor *description = av_pix_fmt_desc_get(format);
    int planar10 = format == AV_PIX_FMT_YUV420P10LE ||
                   format == AV_PIX_FMT_YUV420P10BE;
    AVFrame *frame = av_frame_alloc();
    assert(frame && description);
    frame->format = format;
    frame->width = WIDTH;
    frame->height = HEIGHT;
    frame->pts = index;
    frame->duration = 1;

    for (int plane = 0; plane < av_pix_fmt_count_planes(format); plane++) {
        int rows = plane ? AV_CEIL_RSHIFT(HEIGHT, description->log2_chroma_h) : HEIGHT;
        int row_bytes = av_image_get_linesize(format, WIDTH, plane);
        int stride = FFALIGN(row_bytes, 64);
        int plane_size = stride * rows;
        int inverted = index == 1 || (index == 2 && plane > 0) ||
                       (index == 3 && plane == 0);

        /* Keep a sentinel region before the image so an erroneous backwards
         * copy produces a deterministic pixel mismatch without an invalid read. */
        frame->buf[plane] = av_buffer_alloc(2 * plane_size + AV_INPUT_BUFFER_PADDING_SIZE);
        assert(frame->buf[plane]);
        memset(frame->buf[plane]->data, 0xa5, frame->buf[plane]->size);
        frame->data[plane] = frame->buf[plane]->data + plane_size;
        frame->linesize[plane] = stride;
        for (int row = 0; row < rows; row++) {
            uint8_t *data = frame->data[plane] + row * stride;
            for (int x = 0; x < row_bytes / (planar10 ? 2 : 1); x++) {
                unsigned value = index * 17 + plane * 43 + row * 7 + x * 3 + 11;
                if (format == AV_PIX_FMT_YUV420P10BE)
                    AV_WB16(data + 2 * x, value & 1023);
                else if (planar10)
                    AV_WL16(data + 2 * x, value & 1023);
                else
                    data[x] = value;
            }
        }
        if (inverted) {
            frame->data[plane] += (rows - 1) * stride;
            frame->linesize[plane] = -stride;
        }
    }
    return frame;
}

static int receive_packets(AVCodecContext *encoder)
{
    AVPacket *packet = av_packet_alloc();
    int result;
    assert(packet);
    while ((result = avcodec_receive_packet(encoder, packet)) >= 0) {
        assert(packet->pts == output_count && packet->duration == 1);
        output_count++;
        av_packet_unref(packet);
    }
    av_packet_free(&packet);
    return result;
}

int main(int argc, char **argv)
{
    assert(argc == 4); /* disposable endpoint, pixel format, wire compression */
    enum AVPixelFormat format = av_get_pix_fmt(argv[2]);
    const char *name = format == AV_PIX_FMT_NV12 || format == AV_PIX_FMT_YUV420P
                           ? "h264_videotoolbox_remote" : "hevc_videotoolbox_remote";
    const AVCodec *codec = avcodec_find_encoder_by_name(name);
    assert(format != AV_PIX_FMT_NONE && codec);
    AVCodecContext *encoder = avcodec_alloc_context3(codec);
    assert(encoder);
    encoder->width = WIDTH;
    encoder->height = HEIGHT;
    encoder->pix_fmt = format;
    encoder->time_base = (AVRational){1, 30};
    encoder->framerate = (AVRational){30, 1};
    /* The public API otherwise clears AVFrame.duration before encoding. */
    encoder->flags |= AV_CODEC_FLAG_FRAME_DURATION;
    encoder->bit_rate = 500000;
    encoder->max_b_frames = 0;
    check(av_opt_set(encoder->priv_data, "vt_remote_host", argv[1], 0));
    check(av_opt_set(encoder->priv_data, "vt_remote_wire_compression", argv[3], 0));
    check(av_opt_set_int(encoder->priv_data, "vt_remote_inflight", 2, 0));
    check(av_opt_set_int(encoder->priv_data, "vt_remote_timeout_ms", 1000, 0));
    check(avcodec_open2(encoder, codec, NULL));

    for (int index = 0; index < FRAME_COUNT; index++) {
        AVFrame *frame = make_frame(format, index);
        int result;
        while ((result = avcodec_send_frame(encoder, frame)) == AVERROR(EAGAIN))
            assert(receive_packets(encoder) == AVERROR(EAGAIN));
        check(result);
        av_frame_free(&frame);
        assert(receive_packets(encoder) == AVERROR(EAGAIN));
    }
    check(avcodec_send_frame(encoder, NULL));
    assert(receive_packets(encoder) == AVERROR_EOF);
    assert(output_count == FRAME_COUNT);
    avcodec_free_context(&encoder);
    return 0;
}
