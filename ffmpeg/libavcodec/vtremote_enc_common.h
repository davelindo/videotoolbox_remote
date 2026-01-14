/*
 * VTRemote encoder common definitions (M0 scaffolding)
 */

#ifndef AVCODEC_VTREMOTE_ENC_COMMON_H
#define AVCODEC_VTREMOTE_ENC_COMMON_H

#include "avcodec.h"
#include "libavutil/opt.h"
#include "vtremote_proto.h"

typedef struct VTRemoteEncContext {
    const AVClass *class;
    char *host;
    char *token;
    int timeout_ms;
    int inflight;
    int log_level;
    int wire_compression;
    int codec_id;  /* AVCodecID */
    /* VideoToolbox option mirror (see videotoolboxenc.c) */
    int profile;
    int level;
    int entropy;
    int allow_sw;
    int require_sw;
    int realtime;
    int frames_before;
    int frames_after;
    int prio_speed;
    int power_efficient;
    int spatialaq;
    int max_ref_frames;
    int a53_cc;
    int max_slice_bytes;
    int constant_bit_rate;
    double alpha_quality;
    /* runtime state */
    int fd;
    int connected;
    int flushing;
    int done;
    /* inflight frame accounting */
    int inflight_frames;
    /* simple packet ring buffer */
    AVPacket *pkt_queue;
    int pkt_q_size;
    int pkt_q_head;
    int pkt_q_count;
    /* reusable payload buffer */
    VTRemoteWBuf frame_buf;
    /* scratch buffers for compression */
    uint8_t *comp_buf[2];
    int comp_buf_cap[2];
    void *zstd_cctx;
    /* stats */
    int64_t start_time_us;
    int64_t frames_sent;
    int64_t packets_recv;
    int64_t bytes_sent;
    int64_t bytes_recv;
    int max_inflight;
} VTRemoteEncContext;

#define VTREMOTE_BASE_OPTIONS \
    { "vt_remote_host", "VideoToolbox remote server host:port", OFFSET(host), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, ENC|VID }, \
    { "vt_remote_token", "authentication token (optional)", OFFSET(token), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, ENC|VID }, \
    { "vt_remote_timeout_ms", "socket timeout in ms", OFFSET(timeout_ms), AV_OPT_TYPE_INT, { .i64 = 5000 }, 100, 60000, ENC|VID }, \
    { "vt_remote_inflight", "max in-flight frames", OFFSET(inflight), AV_OPT_TYPE_INT, { .i64 = 16 }, 1, 128, ENC|VID }, \
    { "vt_remote_log_level", "remote encoder log level", OFFSET(log_level), AV_OPT_TYPE_INT, { .i64 = AV_LOG_INFO }, AV_LOG_QUIET, AV_LOG_TRACE, ENC|VID }, \
    { "vt_remote_wire_compression", "wire compression", OFFSET(wire_compression), AV_OPT_TYPE_INT, { .i64 = 2 }, 0, 2, ENC|VID, "vt_remote_wire_compression" }, \
        { "none", "no compression", 0, AV_OPT_TYPE_CONST, { .i64 = 0 }, 0, 0, ENC|VID, "vt_remote_wire_compression" }, \
        { "lz4",  "lz4",             0, AV_OPT_TYPE_CONST, { .i64 = 1 }, 0, 0, ENC|VID, "vt_remote_wire_compression" }, \
        { "zstd", "zstd",            0, AV_OPT_TYPE_CONST, { .i64 = 2 }, 0, 0, ENC|VID, "vt_remote_wire_compression" }

#define VTREMOTE_COMMON_VT_OPTIONS \
    { "allow_sw", "Allow software encoding", OFFSET(allow_sw), AV_OPT_TYPE_BOOL, { .i64 = 0 }, 0, 1, VE }, \
    { "require_sw", "Require software encoding", OFFSET(require_sw), AV_OPT_TYPE_BOOL, { .i64 = 0 }, 0, 1, VE }, \
    { "realtime", "Hint that encoding should happen in real-time if not faster (e.g. capturing from camera).", \
        OFFSET(realtime), AV_OPT_TYPE_BOOL, { .i64 = 0 }, -1, 1, VE }, \
    { "frames_before", "Other frames will come before the frames in this session. This helps smooth concatenation issues.", \
        OFFSET(frames_before), AV_OPT_TYPE_BOOL, { .i64 = 0 }, 0, 1, VE }, \
    { "frames_after", "Other frames will come after the frames in this session. This helps smooth concatenation issues.", \
        OFFSET(frames_after), AV_OPT_TYPE_BOOL, { .i64 = 0 }, 0, 1, VE }, \
    { "prio_speed", "prioritize encoding speed", OFFSET(prio_speed), AV_OPT_TYPE_BOOL, { .i64 = -1 }, -1, 1, VE }, \
    { "power_efficient", "Set to 1 to enable more power-efficient encoding if supported.", \
        OFFSET(power_efficient), AV_OPT_TYPE_INT, { .i64 = -1 }, -1, 1, VE }, \
    { "spatial_aq", "Set to 1 to enable spatial AQ if supported.", \
        OFFSET(spatialaq), AV_OPT_TYPE_INT, { .i64 = -1 }, -1, 1, VE }, \
    { "max_ref_frames", \
        "Sets the maximum number of reference frames. This only has an effect when the value is less than the maximum allowed by the profile/level.", \
        OFFSET(max_ref_frames), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, INT_MAX, VE }

int ff_vtremote_common_init(AVCodecContext *avctx);
int ff_vtremote_common_close(AVCodecContext *avctx);
int ff_vtremote_common_send_frame(AVCodecContext *avctx, const AVFrame *frame);
int ff_vtremote_common_receive_packet(AVCodecContext *avctx, AVPacket *pkt);
int ff_vtremote_encode(AVCodecContext *avctx, AVPacket *pkt, const AVFrame *frame, int *got_packet);

#endif /* AVCODEC_VTREMOTE_ENC_COMMON_H */
