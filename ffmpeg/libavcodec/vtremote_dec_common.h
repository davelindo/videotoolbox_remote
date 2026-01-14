/*
 * VTRemote decoder common definitions
 */

#ifndef AVCODEC_VTREMOTE_DEC_COMMON_H
#define AVCODEC_VTREMOTE_DEC_COMMON_H

#include "avcodec.h"
#include "libavutil/opt.h"
#include "vtremote_proto.h"

typedef struct VTRemoteDecContext {
    const AVClass *class;
    char *host;
    char *token;
    int timeout_ms;
    int log_level;
    int wire_compression;
    int codec_id;
    int fd;
    int connected;
    int flushing;
    int done;
    VTRemoteWBuf pkt_buf;
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
    { "vt_remote_wire_compression", "wire compression", OFFSET(wire_compression), AV_OPT_TYPE_INT, { .i64 = 2 }, 0, 2, DEC|VID, "vt_remote_wire_compression" }, \
        { "none", "no compression", 0, AV_OPT_TYPE_CONST, { .i64 = 0 }, 0, 0, DEC|VID, "vt_remote_wire_compression" }, \
        { "lz4",  "lz4",             0, AV_OPT_TYPE_CONST, { .i64 = 1 }, 0, 0, DEC|VID, "vt_remote_wire_compression" }, \
        { "zstd", "zstd",            0, AV_OPT_TYPE_CONST, { .i64 = 2 }, 0, 0, DEC|VID, "vt_remote_wire_compression" }

int ff_vtremote_dec_init(AVCodecContext *avctx);
int ff_vtremote_dec_close(AVCodecContext *avctx);
int ff_vtremote_decode(AVCodecContext *avctx, AVFrame *frame, int *got_frame, AVPacket *pkt);

#endif /* AVCODEC_VTREMOTE_DEC_COMMON_H */
