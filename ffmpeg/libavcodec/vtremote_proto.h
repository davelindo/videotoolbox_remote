/*
 * VTRemote protocol helpers (v1)
 *
 * This file defines message header constants and small helper routines for
 * packing/unpacking the fixed header used by the VTRemote wire protocol.
 *
 * The intent is to keep this file dependency-light; it can be compiled as
 * part of libavcodec or used in small test harnesses before encoder wiring.
 */

#ifndef AVCODEC_VTREMOTE_PROTO_H
#define AVCODEC_VTREMOTE_PROTO_H

#include <errno.h>
#include <stddef.h>
#include <stdint.h>

#include "libavutil/error.h"
#include "libavutil/intreadwrite.h"

#define VTREMOTE_PROTO_MAGIC   0x56545231u  /* 'VTR1' */
#define VTREMOTE_PROTO_VERSION 1
#define VTREMOTE_HEADER_SIZE   12

#define VTREMOTE_MAX_HELLO_ACK_BYTES         (64U * 1024U)
#define VTREMOTE_MAX_CONFIGURE_ACK_BYTES     (4U * 1024U * 1024U)
#define VTREMOTE_MAX_MEDIA_PAYLOAD_BYTES     (256U * 1024U * 1024U)
#define VTREMOTE_MAX_CONTROL_PAYLOAD_BYTES   (64U * 1024U)

#define VTREMOTE_PIX_FMT_NV12          1
#define VTREMOTE_PIX_FMT_P010          2
#define VTREMOTE_PIX_FMT_BGRA          3
#define VTREMOTE_PIX_FMT_AYUV          4
#define VTREMOTE_PIX_FMT_P210          5
#define VTREMOTE_PIX_FMT_VIDEOTOOLBOX  6

#define VTREMOTE_CAP_H264                      (UINT64_C(1) << 0)
#define VTREMOTE_CAP_HEVC                      (UINT64_C(1) << 1)
#define VTREMOTE_CAP_PIXFMT_NV12               (UINT64_C(1) << 2)
#define VTREMOTE_CAP_PIXFMT_P010               (UINT64_C(1) << 3)
#define VTREMOTE_CAP_PIXFMT_BGRA               (UINT64_C(1) << 4)
#define VTREMOTE_CAP_PIXFMT_AYUV               (UINT64_C(1) << 5)
#define VTREMOTE_CAP_PIXFMT_P210               (UINT64_C(1) << 6)
#define VTREMOTE_CAP_HWFRAMES_VIDEOTOOLBOX_IN  (UINT64_C(1) << 7)
#define VTREMOTE_CAP_HWFRAMES_VIDEOTOOLBOX_OUT (UINT64_C(1) << 8)
#define VTREMOTE_CAP_SIDE_DATA_V2              (UINT64_C(1) << 9)
#define VTREMOTE_CAP_PACKET_ACK_V1             (UINT64_C(1) << 10)

enum VTRemoteMsgType {
    VTREMOTE_MSG_HELLO = 1,
    VTREMOTE_MSG_HELLO_ACK,
    VTREMOTE_MSG_CONFIGURE,
    VTREMOTE_MSG_CONFIGURE_ACK,
    VTREMOTE_MSG_FRAME,
    VTREMOTE_MSG_PACKET,
    VTREMOTE_MSG_FLUSH,
    VTREMOTE_MSG_DONE,
    VTREMOTE_MSG_ERROR,
    VTREMOTE_MSG_PING,
    VTREMOTE_MSG_PONG,
    VTREMOTE_MSG_PACKET_ACK = 12,
};

typedef struct VTRemoteMsgHeader {
    uint32_t magic;
    uint16_t version;
    uint16_t type;
    uint32_t length;
} VTRemoteMsgHeader;

/**
 * Write a VTRemote header into dst.
 *
 * @return bytes written (VTREMOTE_HEADER_SIZE) on success, negative AVERROR on failure.
 */
static inline int vtremote_write_header(uint8_t *dst, size_t dst_size,
                                       const VTRemoteMsgHeader *hdr)
{
    if (!dst || !hdr || dst_size < VTREMOTE_HEADER_SIZE)
        return AVERROR(EINVAL);

    AV_WB32(dst,     hdr->magic);
    AV_WB16(dst + 4, hdr->version);
    AV_WB16(dst + 6, hdr->type);
    AV_WB32(dst + 8, hdr->length);
    return (int)VTREMOTE_HEADER_SIZE;
}

/**
 * Parse a VTRemote header from src.
 *
 * Performs basic sanity checks on magic and version.
 *
 * @return 0 on success, negative AVERROR on failure.
 */
static inline int vtremote_read_header(const uint8_t *src, size_t src_size,
                                      VTRemoteMsgHeader *out)
{
    if (!src || !out || src_size < VTREMOTE_HEADER_SIZE)
        return AVERROR(EINVAL);

    out->magic   = AV_RB32(src);
    out->version = AV_RB16(src + 4);
    out->type    = AV_RB16(src + 6);
    out->length  = AV_RB32(src + 8);

    if (out->magic != VTREMOTE_PROTO_MAGIC)
        return AVERROR_INVALIDDATA;
    if (out->version != VTREMOTE_PROTO_VERSION)
        return AVERROR_INVALIDDATA;

    return 0;
}

/* Return a short string for logging; returns "UNKNOWN" if out of range. */
const char *vtremote_msg_type_name(int type);
const char *vtremote_pix_fmt_name(uint8_t pix_fmt);
uint64_t vtremote_cap_flag_for_pix_fmt(uint8_t pix_fmt);
int vtremote_validate_payload_length(uint16_t type, uint32_t length);
int vtremote_cap_flag_from_name(const uint8_t *name, int name_len, uint64_t *flag);
int vtremote_caps_parse_hello_ack(const uint8_t *payload, int len,
                                  uint8_t *status,
                                  const uint8_t **server_name, int *server_name_len,
                                  const uint8_t **server_version, int *server_version_len,
                                  uint64_t *caps,
                                  uint16_t *max_sessions, uint16_t *active_sessions);

/* Simple growable payload buffer for outgoing messages. */
typedef struct VTRemoteWBuf {
    uint8_t *data;
    size_t   size;
    unsigned int capacity;
} VTRemoteWBuf;

void vtremote_wbuf_init(VTRemoteWBuf *b);
void vtremote_wbuf_reset(VTRemoteWBuf *b);
void vtremote_wbuf_free(VTRemoteWBuf *b);
int  vtremote_wbuf_put_u8(VTRemoteWBuf *b, uint8_t v);
int  vtremote_wbuf_put_u16(VTRemoteWBuf *b, uint16_t v);
int  vtremote_wbuf_put_u32(VTRemoteWBuf *b, uint32_t v);
int  vtremote_wbuf_put_u64(VTRemoteWBuf *b, uint64_t v);
int  vtremote_wbuf_put_bytes(VTRemoteWBuf *b, const uint8_t *src, int len);
int  vtremote_wbuf_put_str(VTRemoteWBuf *b, const char *s); /* u16 len + bytes */

/**
 * Build a full framed message (header + payload copy).
 *
 * @param msg_type  Message type enum value
 * @param payload   Payload buffer (may be NULL for zero-length)
 * @param out_buf   Allocated buffer (av_malloc); caller frees with av_free
 * @param out_size  Size of out_buf
 */
int vtremote_build_message(int msg_type, const VTRemoteWBuf *payload,
                          uint8_t **out_buf, int *out_size);

/* Read helpers with bounds checks. */
typedef struct VTRemoteRBuf {
    const uint8_t *data;
    int            size;
    int            pos;
} VTRemoteRBuf;

static inline void vtremote_rbuf_init(VTRemoteRBuf *r, const uint8_t *data, int size)
{
    r->data = data;
    r->size = size;
    r->pos  = 0;
}

int vtremote_rbuf_read_u8(VTRemoteRBuf *r, uint8_t *out);
int vtremote_rbuf_read_u16(VTRemoteRBuf *r, uint16_t *out);
int vtremote_rbuf_read_u32(VTRemoteRBuf *r, uint32_t *out);
int vtremote_rbuf_read_u64(VTRemoteRBuf *r, uint64_t *out);

/**
 * Read a length-prefixed string (u16 len + bytes). Returns a pointer into the
 * underlying buffer; the bytes are not NUL-terminated.
 */
int vtremote_rbuf_read_str(VTRemoteRBuf *r, const uint8_t **str, int *len);

/* Key/value pair for options maps. */
typedef struct VTRemoteKV {
    const char *key;
    const char *value;
} VTRemoteKV;

typedef struct VTRemoteSideData {
    uint32_t type;
    uint32_t size;
    const uint8_t *data;
} VTRemoteSideData;

/* High-level payload writers (helpers for encoders). */
/* Caller must initialize VTRemoteWBuf via vtremote_wbuf_init before first use. */
int vtremote_payload_hello(VTRemoteWBuf *b,
                          const char *token,
                          const char *requested_codec,
                          const char *client_name,
                          const char *client_build_id);

int vtremote_payload_configure(VTRemoteWBuf *b,
                              uint32_t width, uint32_t height,
                              uint8_t pix_fmt,
                              uint32_t time_base_num, uint32_t time_base_den,
                              uint32_t fr_num, uint32_t fr_den,
                              const VTRemoteKV *options, int options_count,
                              const uint8_t *extradata, uint32_t extradata_len);

int vtremote_payload_frame(VTRemoteWBuf *b,
                          int64_t pts, int64_t duration, uint32_t flags,
                          uint8_t plane_count,
                          const uint8_t *const *planes,
                          const uint32_t *strides,
                          const uint32_t *heights,
                          const uint32_t *sizes,
                          const VTRemoteSideData *side_data,
                          uint8_t side_data_count);

int vtremote_payload_packet(VTRemoteWBuf *b,
                           int64_t pts, int64_t dts, int64_t duration, uint32_t flags,
                           const uint8_t *data, uint32_t data_len);
int vtremote_payload_packet_ex(VTRemoteWBuf *b,
                              int64_t pts, int64_t dts, int64_t duration, uint32_t flags,
                              const uint8_t *data, uint32_t data_len,
                              const VTRemoteSideData *side_data,
                              uint8_t side_data_count);

/* Packet view after parsing (points into buffer). */
typedef struct VTRemotePacketView {
    int64_t pts;
    int64_t dts;
    int64_t duration;
    uint32_t flags;
    const uint8_t *data;
    uint32_t data_len;
    uint8_t side_data_count;
    VTRemoteSideData side_data[16];
} VTRemotePacketView;

int vtremote_parse_packet(const uint8_t *payload, int payload_size, VTRemotePacketView *out);

typedef struct VTRemotePlaneView {
    uint32_t stride;
    uint32_t height;
    uint32_t data_len;
    const uint8_t *data;
} VTRemotePlaneView;

int vtremote_validate_plane_geometry(const VTRemotePlaneView *plane,
                                     uint32_t minimum_stride,
                                     uint32_t expected_height,
                                     int compressed,
                                     uint32_t max_decoded_bytes,
                                     int *decoded_size);

typedef struct VTRemoteFrameView {
    int64_t pts;
    int64_t duration;
    uint32_t flags;
    uint8_t plane_count;
    VTRemotePlaneView planes[4];
    uint8_t side_data_count;
    VTRemoteSideData side_data[16];
} VTRemoteFrameView;

int vtremote_parse_frame(const uint8_t *payload, int payload_size, VTRemoteFrameView *out);


#endif /* AVCODEC_VTREMOTE_PROTO_H */
