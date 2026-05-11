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
    int inflight_auto;
    int inflight_min;
    int inflight_max_limit;
    int inflight_step;
    int inflight_blocked;
    int inflight_idle_intervals;
    int64_t inflight_last_adjust_us;
    int log_level;
    int wire_compression;
    int zstd_level;
    int zstd_workers;
    int zstd_last_level;
    int zstd_last_workers;
    int zstd_last_job_size;
    uint64_t server_caps;
    int warned_frame_side_data_no_cap;
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
    /* send queue for non-blocking writes */
    struct VTRemoteSendBuf *send_queue;
    int send_q_size;
    int send_q_head;
    int send_q_tail;
    int send_q_count;
    int queued_frames;
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
    int64_t send_time_us;
    int64_t send_frames;
    int64_t recv_wait_us;
    int64_t recv_calls;
    int max_inflight;
    int64_t last_dts;
    AVFrame *convert_frame;
} VTRemoteEncContext;

#define VTREMOTE_SEND_MAX_SEGS 8

typedef struct VTRemoteSendBuf {
    const uint8_t *segs[VTREMOTE_SEND_MAX_SEGS];
    int seg_lens[VTREMOTE_SEND_MAX_SEGS];
    int seg_count;
    int seg_index;
    int seg_offset;

    /* fixed storage for common segments */
    uint8_t header[VTREMOTE_HEADER_SIZE];
    uint8_t frame_meta[21];
    uint8_t plane_meta[2][12];

    /* owned storage for compressed planes / side data (freed when sent) */
    uint8_t *owned_plane[2];
    int owned_plane_size[2];
    uint8_t *owned_side_data;
    int owned_side_data_size;

    /* optional ref when segments point into the original frame */
    AVFrame *frame_ref;

    int is_frame;
    int64_t enqueue_us;
} VTRemoteSendBuf;

#define VTREMOTE_BASE_OPTIONS(wire_default, inflight_default) \
    { "vt_remote_host", "VideoToolbox remote server host:port", OFFSET(host), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, ENC|VID }, \
    { "vt_remote_token", "authentication token (optional)", OFFSET(token), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, ENC|VID }, \
    { "vt_remote_timeout_ms", "socket timeout in ms", OFFSET(timeout_ms), AV_OPT_TYPE_INT, { .i64 = 5000 }, 100, 60000, ENC|VID }, \
    { "vt_remote_inflight", "max in-flight frames", OFFSET(inflight), AV_OPT_TYPE_INT, { .i64 = inflight_default }, 0, 128, ENC|VID, "vt_remote_inflight" }, \
        { "auto", "auto", 0, AV_OPT_TYPE_CONST, { .i64 = 0 }, 0, 0, ENC|VID, "vt_remote_inflight" }, \
    { "vt_remote_log_level", "remote encoder log level", OFFSET(log_level), AV_OPT_TYPE_INT, { .i64 = AV_LOG_INFO }, AV_LOG_QUIET, AV_LOG_TRACE, ENC|VID }, \
    { "vt_remote_wire_compression", "wire compression", OFFSET(wire_compression), AV_OPT_TYPE_INT, { .i64 = wire_default }, 0, 3, ENC|VID, "vt_remote_wire_compression" }, \
        { "none", "no compression", 0, AV_OPT_TYPE_CONST, { .i64 = 0 }, 0, 0, ENC|VID, "vt_remote_wire_compression" }, \
        { "lz4",  "lz4",             0, AV_OPT_TYPE_CONST, { .i64 = 1 }, 0, 0, ENC|VID, "vt_remote_wire_compression" }, \
        { "zstd", "zstd",            0, AV_OPT_TYPE_CONST, { .i64 = 2 }, 0, 0, ENC|VID, "vt_remote_wire_compression" }, \
        { "auto", "auto",            0, AV_OPT_TYPE_CONST, { .i64 = 3 }, 0, 0, ENC|VID, "vt_remote_wire_compression" }, \
    { "vt_remote_zstd_level", "zstd compression level (wire compression)", OFFSET(zstd_level), AV_OPT_TYPE_INT, { .i64 = 1 }, -5, 22, ENC|VID }, \
    { "vt_remote_zstd_workers", "zstd worker threads (0=single-threaded)", OFFSET(zstd_workers), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, 64, ENC|VID }

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
