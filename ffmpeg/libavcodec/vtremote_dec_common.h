/*
 * VTRemote decoder common definitions
 */

#ifndef AVCODEC_VTREMOTE_DEC_COMMON_H
#define AVCODEC_VTREMOTE_DEC_COMMON_H

#include "avcodec.h"
#include "libavutil/opt.h"
#include "vtremote_proto.h"

#define VTREMOTE_HW_CONFIG_DECODER_FRAMES(format, device_type_) \
    &(const AVCodecHWConfigInternal) { \
        .public          = { \
            .pix_fmt     = AV_PIX_FMT_ ## format, \
            .methods     = AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX | \
                           AV_CODEC_HW_CONFIG_METHOD_HW_FRAMES_CTX, \
            .device_type = AV_HWDEVICE_TYPE_ ## device_type_, \
        }, \
        .hwaccel         = NULL, \
    }

typedef struct VTRemoteDecContext {
    const AVClass *class;
    char *host;
    char *token;
    int timeout_ms;
    int log_level;
    int wire_compression;
    int decode_async;
    int decode_reorder_depth;
    int output_hw_frames;
    int owns_hw_frames_ctx;
    uint64_t server_caps;
    int codec_id;
    int fd;
    int connected;
    int flushing;
    int done;
    VTRemoteWBuf pkt_buf;
    uint8_t *rx_buf;
    int rx_buf_cap;
    int rx_buf_len;
    int64_t last_frame_pts;
    uint8_t *comp_buf[2];
    int comp_buf_cap[2];
    void *zstd_dctx;
    int64_t start_time_us;
    int64_t packets_sent;
    int64_t frames_recv;
    int64_t bytes_sent;
    int64_t bytes_recv;
} VTRemoteDecContext;

#define VTREMOTE_BASE_OPTIONS \
    { "vt_remote_host", "VideoToolbox remote server host:port", OFFSET(host), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, DEC|VID }, \
    { "vt_remote_token", "authentication token (optional)", OFFSET(token), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, DEC|VID }, \
    { "vt_remote_timeout_ms", "socket timeout in ms", OFFSET(timeout_ms), AV_OPT_TYPE_INT, { .i64 = 5000 }, 100, 60000, DEC|VID }, \
    { "vt_remote_log_level", "remote decoder log level", OFFSET(log_level), AV_OPT_TYPE_INT, { .i64 = AV_LOG_INFO }, AV_LOG_QUIET, AV_LOG_TRACE, DEC|VID }, \
    { "vt_remote_wire_compression", "wire compression", OFFSET(wire_compression), AV_OPT_TYPE_INT, { .i64 = 1 }, 0, 3, DEC|VID, "vt_remote_wire_compression" }, \
        { "none", "no compression", 0, AV_OPT_TYPE_CONST, { .i64 = 0 }, 0, 0, DEC|VID, "vt_remote_wire_compression" }, \
        { "lz4",  "lz4",             0, AV_OPT_TYPE_CONST, { .i64 = 1 }, 0, 0, DEC|VID, "vt_remote_wire_compression" }, \
        { "zstd", "zstd",            0, AV_OPT_TYPE_CONST, { .i64 = 2 }, 0, 0, DEC|VID, "vt_remote_wire_compression" }, \
        { "auto", "auto",            0, AV_OPT_TYPE_CONST, { .i64 = 3 }, 0, 0, DEC|VID, "vt_remote_wire_compression" }, \
    { "vt_remote_output_hw_frames", "return VideoToolbox hardware frames", OFFSET(output_hw_frames), AV_OPT_TYPE_BOOL, { .i64 = 0 }, 0, 1, DEC|VID }, \
    { "vt_remote_decode_async", "allow async decode on server (may reorder frames)", OFFSET(decode_async), AV_OPT_TYPE_BOOL, { .i64 = 1 }, 0, 1, DEC|VID }, \
    { "vt_remote_decode_reorder_depth", "frames to buffer for PTS reordering when async decode enabled (-1=server default)", OFFSET(decode_reorder_depth), AV_OPT_TYPE_INT, { .i64 = 2 }, -1, 64, DEC|VID }

int ff_vtremote_dec_init(AVCodecContext *avctx);
int ff_vtremote_dec_close(AVCodecContext *avctx);
int ff_vtremote_decode(AVCodecContext *avctx, AVFrame *frame, int *got_frame, AVPacket *pkt);

#endif /* AVCODEC_VTREMOTE_DEC_COMMON_H */
