/*
 * VTRemote decoder common scaffolding
 */

#include "config.h"
#include "config_components.h"

#include <errno.h>
#include <string.h>
#include <inttypes.h>
#include <sys/types.h>
#if defined(HAVE_WINSOCK2_H) && HAVE_WINSOCK2_H
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>
#include <sys/time.h>
#include <poll.h>
#endif
#include "avcodec.h"
#include "codec_internal.h"
#include "decode.h"
#include "internal.h"
#include "libavutil/avstring.h"
#include "libavutil/ffversion.h"
#include "libavutil/hwcontext.h"
#include "libavutil/opt.h"
#include "libavutil/mem.h"
#include "libavutil/common.h"
#include "libavutil/pixfmt.h"
#include "libavutil/pixdesc.h"
#include "libavutil/time.h"
#include "vtremote_dec_common.h"
#include "vtremote_proto.h"
#include <lz4.h>
#include <zstd.h>

#if CONFIG_VIDEOTOOLBOX && defined(__APPLE__)
#include "libavutil/hwcontext_videotoolbox.h"
#define VTREMOTE_HAVE_VIDEOTOOLBOX_OUTPUT 1
#else
#define VTREMOTE_HAVE_VIDEOTOOLBOX_OUTPUT 0
#endif

static inline int vtremote_log_enabled(const VTRemoteDecContext *s, int level);

#if defined(HAVE_WINSOCK2_H) && HAVE_WINSOCK2_H
#define VTR_CLOSE_SOCKET closesocket
#define VTR_SOCKOPT_ARG (const char *)
static int vtremote_net_init(void)
{
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa))
        return AVERROR(WSAGetLastError());
    return 0;
}
static void vtremote_net_close(void)
{
    WSACleanup();
}
static int vtremote_sock_errno(void)
{
    return WSAGetLastError();
}
#else
#define VTR_CLOSE_SOCKET close
#define VTR_SOCKOPT_ARG
static int vtremote_net_init(void)
{
    return 0;
}
static void vtremote_net_close(void)
{
}
static int vtremote_sock_errno(void)
{
    return errno;
}
#endif

static int set_socket_timeout(int fd, int timeout_ms)
{
    struct timeval tv;
    tv.tv_sec  = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, VTR_SOCKOPT_ARG &tv, sizeof(tv)) < 0)
        return AVERROR(vtremote_sock_errno());
    if (setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, VTR_SOCKOPT_ARG &tv, sizeof(tv)) < 0)
        return AVERROR(vtremote_sock_errno());
    return 0;
}

/* Configure socket for high-throughput video streaming */
static void configure_socket_buffers(int fd)
{
    /* 16MB buffers to sustain multi-gigabit links */
    int bufsize = 16 * 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, VTR_SOCKOPT_ARG &bufsize, sizeof(bufsize));
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, VTR_SOCKOPT_ARG &bufsize, sizeof(bufsize));
}

static double vtremote_guess_fps(const AVCodecContext *avctx)
{
    if (avctx->framerate.num > 0 && avctx->framerate.den > 0)
        return (double)avctx->framerate.num / (double)avctx->framerate.den;
    if (avctx->time_base.num > 0 && avctx->time_base.den > 0 &&
        !(avctx->time_base.num == 1 && avctx->time_base.den == 1)) {
        return (double)avctx->time_base.den / (double)avctx->time_base.num;
    }
    return 0.0;
}

static double vtremote_estimate_raw_mbps(const AVCodecContext *avctx)
{
    if (!avctx || avctx->width <= 0 || avctx->height <= 0)
        return 0.0;
    double fps = vtremote_guess_fps(avctx);
    if (fps <= 0.0)
        fps = 30.0;

    double bytes_per_pixel = 1.5;
    if (avctx->pix_fmt == AV_PIX_FMT_P010LE || avctx->pix_fmt == AV_PIX_FMT_P010)
        bytes_per_pixel = 3.0;

    double bytes_per_frame = bytes_per_pixel * (double)avctx->width *
                             (double)avctx->height;
    return bytes_per_frame * fps * 8.0 / 1000000.0;
}

static void vtremote_apply_auto_wire_compression(AVCodecContext *avctx,
                                                 VTRemoteDecContext *s)
{
    if (!s || s->wire_compression != 3)
        return;

    double raw_mbps = vtremote_estimate_raw_mbps(avctx);
    int chosen = 1; /* lz4 */
    if (raw_mbps > 0.0 && raw_mbps < 200.0)
        chosen = 2; /* zstd */

    s->wire_compression = chosen;
    if (vtremote_log_enabled(s, AV_LOG_VERBOSE)) {
        av_log(avctx, AV_LOG_VERBOSE,
               "vtremote auto wire_compression=%.1fMb/s -> %s\n",
               raw_mbps, chosen == 2 ? "zstd" : "lz4");
    }
}

static int write_full(int fd, const uint8_t *buf, int size)
{
    int sent = 0;
    while (sent < size) {
        int r = (int)send(fd, buf + sent, size - sent, 0);
        if (r < 0) {
            int err = vtremote_sock_errno();
#if defined(HAVE_WINSOCK2_H) && HAVE_WINSOCK2_H
            if (err == WSAEINTR)
                continue;
#endif
            if (err == EINTR)
                continue;
            return AVERROR(err);
        }
        if (r == 0)
            return AVERROR_EOF;
        sent += r;
    }
    return 0;
}

static int read_full(int fd, uint8_t *buf, int size)
{
    int got = 0;
    while (got < size) {
        int r = (int)recv(fd, buf + got, size - got, 0);
        if (r < 0) {
            int err = vtremote_sock_errno();
#if defined(HAVE_WINSOCK2_H) && HAVE_WINSOCK2_H
            if (err == WSAEINTR)
                continue;
#endif
            if (err == EINTR)
                continue;
            if (err == EAGAIN || err == EWOULDBLOCK
#if defined(HAVE_WINSOCK2_H) && HAVE_WINSOCK2_H
                || err == WSAEWOULDBLOCK
#endif
                )
                return got == 0 ? AVERROR(EAGAIN) : AVERROR(EIO);
            return AVERROR(err);
        }
        if (r == 0)
            return AVERROR_EOF;
        got += r;
    }
    return 0;
}

/* Wait for the socket to become readable (ms timeout). */
static int wait_readable(int fd, int timeout_ms)
{
#if defined(HAVE_WINSOCK2_H) && HAVE_WINSOCK2_H
    fd_set readfds;
    struct timeval tv;
    FD_ZERO(&readfds);
    FD_SET(fd, &readfds);
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    return select(fd + 1, &readfds, NULL, NULL, &tv);
#else
    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = POLLIN;
    pfd.revents = 0;
    return poll(&pfd, 1, timeout_ms);
#endif
}

static int connect_hostport(const char *hostport, int timeout_ms)
{
    if (!hostport)
        return AVERROR(EINVAL);

    char host[256];
    char port[16];
    const char *colon = strrchr(hostport, ':');
    if (!colon || colon == hostport || strlen(colon + 1) >= sizeof(port))
        return AVERROR(EINVAL);
    av_strlcpy(port, colon + 1, sizeof(port));
    size_t hostlen = colon - hostport;
    if (hostlen >= sizeof(host))
        return AVERROR(EINVAL);
    memcpy(host, hostport, hostlen);
    host[hostlen] = '\0';

    struct addrinfo hints = {0}, *res = NULL, *rp;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family   = AF_INET;
    int err = getaddrinfo(host, port, &hints, &res);
    if (err)
        return AVERROR(EIO);

    int fd = -1;
    for (rp = res; rp; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0)
            continue;
        set_socket_timeout(fd, timeout_ms);
        configure_socket_buffers(fd);
        if (connect(fd, rp->ai_addr, rp->ai_addrlen) == 0)
            break;
        VTR_CLOSE_SOCKET(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0)
        return AVERROR(vtremote_sock_errno() ? vtremote_sock_errno() : EIO);
    return fd;
}

static inline int vtremote_log_enabled(const VTRemoteDecContext *s, int level)
{
    return s && s->log_level >= level;
}

static int vtremote_add_opt(VTRemoteKV **opts, int *count, int *cap,
                            const char *key, char *value)
{
    if (!opts || !count || !cap || !key || !value)
        return AVERROR(EINVAL);
    if (*count >= *cap) {
        int new_cap = (*cap == 0) ? 16 : (*cap * 2);
        VTRemoteKV *tmp = av_realloc_array(*opts, new_cap, sizeof(**opts));
        if (!tmp)
            return AVERROR(ENOMEM);
        *opts = tmp;
        *cap = new_cap;
    }
    (*opts)[*count].key = key;
    (*opts)[*count].value = value;
    (*count)++;
    return 0;
}

static const char *codec_name_for_id(int codec_id)
{
    switch (codec_id) {
    case AV_CODEC_ID_H264: return "h264";
    case AV_CODEC_ID_HEVC: return "hevc";
    default: return "unknown";
    }
}

static int vtremote_send_msg(VTRemoteDecContext *s, int msg_type, VTRemoteWBuf *payload)
{
    if (!s)
        return AVERROR(EINVAL);
    const uint8_t *payload_data = payload ? payload->data : NULL;
    const uint32_t payload_size = payload ? (uint32_t)payload->size : 0;
    uint8_t header_buf[VTREMOTE_HEADER_SIZE];
    VTRemoteMsgHeader hdr = {
        .magic   = VTREMOTE_PROTO_MAGIC,
        .version = VTREMOTE_PROTO_VERSION,
        .type    = msg_type,
        .length  = payload_size,
    };
    int ret = vtremote_write_header(header_buf, sizeof(header_buf), &hdr);
    if (ret < 0)
        return ret;
    ret = write_full(s->fd, header_buf, VTREMOTE_HEADER_SIZE);
    if (ret < 0)
        return ret;
    if (payload_size) {
        ret = write_full(s->fd, payload_data, payload_size);
        if (ret < 0)
            return ret;
    }
    s->bytes_sent += VTREMOTE_HEADER_SIZE + payload_size;
    return 0;
}

static int vtremote_read_msg(VTRemoteDecContext *s, VTRemoteMsgHeader *hdr, uint8_t **payload)
{
    uint8_t header_buf[VTREMOTE_HEADER_SIZE];
    if (!s)
        return AVERROR(EINVAL);
    int ret = read_full(s->fd, header_buf, VTREMOTE_HEADER_SIZE);
    if (ret < 0)
        return ret;
    ret = vtremote_read_header(header_buf, VTREMOTE_HEADER_SIZE, hdr);
    if (ret < 0)
        return ret;
    if (hdr->length == 0) {
        *payload = NULL;
        s->rx_buf_len = 0;
        s->bytes_recv += VTREMOTE_HEADER_SIZE;
        return 0;
    }
    if ((int)hdr->length > s->rx_buf_cap) {
        int new_cap = FFMAX((s->rx_buf_cap > 0) ? (s->rx_buf_cap * 2) : 0, (int)hdr->length);
        uint8_t *tmp = av_realloc(s->rx_buf, new_cap);
        if (!tmp)
            return AVERROR(ENOMEM);
        s->rx_buf = tmp;
        s->rx_buf_cap = new_cap;
    }
    ret = read_full(s->fd, s->rx_buf, hdr->length);
    if (ret < 0)
        return ret;
    s->rx_buf_len = hdr->length;
    *payload = s->rx_buf;
    s->bytes_recv += VTREMOTE_HEADER_SIZE + hdr->length;
    return 0;
}

static int vtremote_handle_hello_ack(AVCodecContext *avctx, const uint8_t *payload, int len)
{
    VTRemoteDecContext *s = avctx->priv_data;
    uint8_t status = 0;
    const uint8_t *server_name = NULL, *server_ver = NULL;
    int server_name_len = 0, server_ver_len = 0;
    uint16_t max_sessions = 0, active = 0;
    uint64_t caps = 0;
    int ret = vtremote_caps_parse_hello_ack(payload, len, &status,
                                            &server_name, &server_name_len,
                                            &server_ver, &server_ver_len,
                                            &caps, &max_sessions, &active);
    if (ret < 0)
        return ret;
    s->server_caps = caps;

    if (status != 0) {
        /* The server reports:
         *  - status=1: busy (max sessions reached)
         *  - status=2: auth failure (token mismatch)
         */
        if (status == 1) {
            av_log(avctx, AV_LOG_ERROR,
                   "vtremote server busy (sessions active=%u max=%u) [%.*s %.*s]\n",
                   active, max_sessions,
                   server_name_len, server_name ? (const char *)server_name : "",
                   server_ver_len, server_ver ? (const char *)server_ver : "");
            return AVERROR(EAGAIN);
        }
        if (status == 2) {
            av_log(avctx, AV_LOG_ERROR,
                   "vtremote server unauthorized (token mismatch) [%.*s %.*s]\n",
                   server_name_len, server_name ? (const char *)server_name : "",
                   server_ver_len, server_ver ? (const char *)server_ver : "");
            return AVERROR(EACCES);
        }
        av_log(avctx, AV_LOG_ERROR,
               "vtremote server refused handshake (status=%u) [%.*s %.*s]\n", status,
               server_name_len, server_name ? (const char *)server_name : "",
               server_ver_len, server_ver ? (const char *)server_ver : "");
        return AVERROR(EACCES);
    }
    if (vtremote_log_enabled(s, AV_LOG_VERBOSE)) {
        av_log(avctx, AV_LOG_VERBOSE,
               "vtremote server [%.*s %.*s] caps=0x%" PRIx64 " active=%u max=%u\n",
               server_name_len, server_name ? (const char *)server_name : "",
               server_ver_len, server_ver ? (const char *)server_ver : "",
               caps, active, max_sessions);
    }
    return 0;
}

static enum AVPixelFormat pix_fmt_from_wire(uint8_t pix)
{
    switch (pix) {
    case VTREMOTE_PIX_FMT_NV12: return AV_PIX_FMT_NV12;
    case VTREMOTE_PIX_FMT_P010: return AV_PIX_FMT_P010LE;
    default: return AV_PIX_FMT_NONE;
    }
}

static enum AVPixelFormat vtremote_decode_sw_pix_fmt(const AVCodecContext *avctx)
{
    if (!avctx)
        return AV_PIX_FMT_NONE;
    if (avctx->pix_fmt == AV_PIX_FMT_VIDEOTOOLBOX)
        return avctx->sw_pix_fmt != AV_PIX_FMT_NONE ? avctx->sw_pix_fmt
                                                    : AV_PIX_FMT_NV12;
    return avctx->pix_fmt;
}

static int wire_pix_fmt_from_av_pix_fmt(enum AVPixelFormat pix_fmt)
{
    switch (pix_fmt) {
    case AV_PIX_FMT_NV12:
        return VTREMOTE_PIX_FMT_NV12;
    case AV_PIX_FMT_P010LE:
        return VTREMOTE_PIX_FMT_P010;
    default:
        return 0;
    }
}

static void vtremote_copy_plane_rows(uint8_t *dst, int dst_stride,
                                     const uint8_t *src, int src_stride,
                                     int row_bytes, int rows)
{
    for (int y = 0; y < rows; y++)
        memcpy(dst + y * dst_stride, src + y * src_stride, row_bytes);
}

static int vtremote_decompress_plane_payload(VTRemoteDecContext *s,
                                             uint8_t *dst, int dst_size,
                                             const VTRemotePlaneView *p)
{
    if (!s || !dst || dst_size <= 0 || !p)
        return AVERROR_INVALIDDATA;

    if (s->wire_compression == 1) {
        int decoded = LZ4_decompress_safe((const char *)p->data,
                                          (char *)dst,
                                          p->data_len,
                                          dst_size);
        return decoded == dst_size ? 0 : AVERROR_INVALIDDATA;
    }
    if (s->wire_compression == 2) {
        size_t zret;

        if (!s->zstd_dctx) {
            s->zstd_dctx = ZSTD_createDCtx();
            if (!s->zstd_dctx)
                return AVERROR(ENOMEM);
        }
        zret = ZSTD_decompressDCtx(s->zstd_dctx, dst, dst_size,
                                   p->data, p->data_len);
        return (!ZSTD_isError(zret) && zret == (size_t)dst_size) ? 0
                                                                 : AVERROR_INVALIDDATA;
    }
    return AVERROR_INVALIDDATA;
}

static int vtremote_handle_configure_ack(AVCodecContext *avctx, const uint8_t *payload, int len)
{
    VTRemoteRBuf r;
    vtremote_rbuf_init(&r, payload, len);
    uint8_t status;
    int ret = vtremote_rbuf_read_u8(&r, &status);
    if (ret < 0)
        return ret;
    if (status != 0)
        return AVERROR_INVALIDDATA;

    uint16_t extralen = 0;
    vtremote_rbuf_read_u16(&r, &extralen);
    if (extralen) {
        if (extralen > len - r.pos)
            return AVERROR_INVALIDDATA;
        r.pos += extralen;
    }
    uint8_t reported_pix = 0;
    vtremote_rbuf_read_u8(&r, &reported_pix);
    enum AVPixelFormat pf = pix_fmt_from_wire(reported_pix);
    if (pf != AV_PIX_FMT_NONE && avctx->pix_fmt == AV_PIX_FMT_VIDEOTOOLBOX) {
        avctx->sw_pix_fmt = pf;
    } else if (pf != AV_PIX_FMT_NONE) {
        avctx->pix_fmt = pf;
    }
    uint8_t warn_count = 0;
    vtremote_rbuf_read_u8(&r, &warn_count);
    const uint8_t *s_ptr; int s_len;
    for (int i = 0; i < warn_count; i++) {
        if (vtremote_rbuf_read_str(&r, &s_ptr, &s_len) < 0)
            break;
        av_log(avctx, AV_LOG_WARNING, "vtremote warning: %.*s\n", s_len, s_ptr);
    }
    return 0;
}

static void vtremote_log_error_msg(AVCodecContext *avctx, const uint8_t *payload, int len)
{
    uint32_t code = 0;
    VTRemoteRBuf r;
    vtremote_rbuf_init(&r, payload, len);
    vtremote_rbuf_read_u32(&r, &code);
    const uint8_t *msg = NULL;
    int mlen = 0;
    if (vtremote_rbuf_read_str(&r, &msg, &mlen) == 0)
        av_log(avctx, AV_LOG_ERROR, "vtremote server error %u: %.*s\n", code, mlen, msg);
    else
        av_log(avctx, AV_LOG_ERROR, "vtremote server error %u\n", code);
}

static int vtremote_handshake(AVCodecContext *avctx)
{
    VTRemoteDecContext *s = avctx->priv_data;
    int fd = connect_hostport(s->host, s->timeout_ms);
    if (fd < 0) {
        av_log(avctx, AV_LOG_ERROR, "Failed to connect to %s\n", s->host);
        return fd;
    }
    s->fd = fd;

    VTRemoteWBuf payload;
    vtremote_wbuf_init(&payload);
    vtremote_payload_hello(&payload, s->token, codec_name_for_id(s->codec_id),
                          "ffmpeg-vtremote", FFMPEG_VERSION);
    int ret = vtremote_send_msg(s, VTREMOTE_MSG_HELLO, &payload);
    vtremote_wbuf_free(&payload);
    if (ret < 0) {
        VTR_CLOSE_SOCKET(fd);
        s->fd = -1;
        return ret;
    }

    VTRemoteMsgHeader hdr;
    uint8_t *pl = NULL;
    ret = vtremote_read_msg(s, &hdr, &pl);
    if (ret < 0) {
        VTR_CLOSE_SOCKET(fd);
        s->fd = -1;
        return ret;
    }
    if (hdr.type == VTREMOTE_MSG_ERROR) {
        vtremote_log_error_msg(avctx, pl, hdr.length);
        VTR_CLOSE_SOCKET(fd);
        s->fd = -1;
        return AVERROR(EIO);
    }
    if (hdr.type != VTREMOTE_MSG_HELLO_ACK) {
        VTR_CLOSE_SOCKET(fd);
        s->fd = -1;
        return AVERROR_INVALIDDATA;
    }
    ret = vtremote_handle_hello_ack(avctx, pl, hdr.length);
    if (ret < 0) {
        VTR_CLOSE_SOCKET(fd);
        s->fd = -1;
        return ret;
    }

    VTRemoteKV *opts = NULL;
    int opt_count = 0;
    int opt_cap = 0;
    char *tmp = NULL;

    tmp = av_strdup("decode");
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "mode", tmp);
    if (ret < 0)
        goto cfg_fail;

    if (s->wire_compression > 0) {
        tmp = av_asprintf("%d", s->wire_compression);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "wire_compression", tmp);
        if (ret < 0) goto cfg_fail;
    }

    if (avctx->color_range != AVCOL_RANGE_UNSPECIFIED) {
        tmp = av_asprintf("%d", avctx->color_range);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "color_range", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (avctx->colorspace != AVCOL_SPC_UNSPECIFIED) {
        tmp = av_asprintf("%d", avctx->colorspace);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "colorspace", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (avctx->color_primaries != AVCOL_PRI_UNSPECIFIED) {
        tmp = av_asprintf("%d", avctx->color_primaries);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "color_primaries", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (avctx->color_trc != AVCOL_TRC_UNSPECIFIED) {
        tmp = av_asprintf("%d", avctx->color_trc);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "color_trc", tmp);
        if (ret < 0) goto cfg_fail;
    }
    tmp = av_asprintf("%d", s->decode_async);
    if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "decode_async", tmp);
    if (ret < 0) goto cfg_fail;
    if (s->decode_async && s->decode_reorder_depth >= 0) {
        tmp = av_asprintf("%d", s->decode_reorder_depth);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "decode_reorder_depth", tmp);
        if (ret < 0) goto cfg_fail;
    }

    int wire_pix_fmt = wire_pix_fmt_from_av_pix_fmt(vtremote_decode_sw_pix_fmt(avctx));
    if (!wire_pix_fmt) {
        av_log(avctx, AV_LOG_ERROR, "Unsupported pix_fmt for vtremote decode: %s\n",
               av_get_pix_fmt_name(vtremote_decode_sw_pix_fmt(avctx)));
        ret = AVERROR(EINVAL);
        goto cfg_fail;
    }

    AVRational tb = avctx->time_base;
    if (tb.num <= 0 || tb.den <= 0 || (tb.num == 1 && tb.den == 1)) {
        if (avctx->pkt_timebase.num > 0 && avctx->pkt_timebase.den > 0) {
            tb = avctx->pkt_timebase;
        } else if (avctx->framerate.num > 0 && avctx->framerate.den > 0) {
            tb = av_inv_q(avctx->framerate);
        } else {
            tb = (AVRational){1, 1};
        }
    }

    VTRemoteWBuf cfg;
    vtremote_wbuf_init(&cfg);
    vtremote_payload_configure(&cfg,
                              avctx->width, avctx->height,
                              wire_pix_fmt,
                              tb.num, tb.den,
                              avctx->framerate.num, avctx->framerate.den,
                              opt_count ? opts : NULL, opt_count,
                              avctx->extradata, avctx->extradata_size);
    ret = vtremote_send_msg(s, VTREMOTE_MSG_CONFIGURE, &cfg);
cfg_fail:
    for (int i = 0; i < opt_count; i++)
        av_freep(&opts[i].value);
    av_freep(&opts);
    vtremote_wbuf_free(&cfg);
    if (ret < 0) {
        VTR_CLOSE_SOCKET(fd);
        s->fd = -1;
        return ret;
    }

    ret = vtremote_read_msg(s, &hdr, &pl);
    if (ret < 0) {
        VTR_CLOSE_SOCKET(fd);
        s->fd = -1;
        return ret;
    }
    if (hdr.type == VTREMOTE_MSG_ERROR) {
        vtremote_log_error_msg(avctx, pl, hdr.length);
        VTR_CLOSE_SOCKET(fd);
        s->fd = -1;
        return AVERROR(EIO);
    }
    if (hdr.type != VTREMOTE_MSG_CONFIGURE_ACK) {
        VTR_CLOSE_SOCKET(fd);
        s->fd = -1;
        return AVERROR_INVALIDDATA;
    }
    ret = vtremote_handle_configure_ack(avctx, pl, hdr.length);
    if (ret < 0) {
        VTR_CLOSE_SOCKET(fd);
        s->fd = -1;
        return ret;
    }

    s->connected = 1;
    return 0;
}

static int vtremote_setup_hw_frames(AVCodecContext *avctx)
{
#if VTREMOTE_HAVE_VIDEOTOOLBOX_OUTPUT
    VTRemoteDecContext *s = avctx->priv_data;
    AVBufferRef *device_ref = NULL;
    AVBufferRef *frames_ref = NULL;
    AVHWFramesContext *frames_ctx;
    enum AVPixelFormat sw_fmt = vtremote_decode_sw_pix_fmt(avctx);
    int ret;

    if (avctx->pix_fmt != AV_PIX_FMT_VIDEOTOOLBOX)
        return 0;
    if (sw_fmt != AV_PIX_FMT_NV12 && sw_fmt != AV_PIX_FMT_P010LE) {
        av_log(avctx, AV_LOG_ERROR,
               "VideoToolbox remote decode output supports NV12/P010 backing "
               "buffers only; got %s.\n",
               av_get_pix_fmt_name(sw_fmt));
        return AVERROR(EINVAL);
    }

    s->output_hw_frames = 1;
    if (avctx->hw_frames_ctx) {
        AVHWFramesContext *provided =
            (AVHWFramesContext *)avctx->hw_frames_ctx->data;
        if (!provided || provided->format != AV_PIX_FMT_VIDEOTOOLBOX ||
            provided->sw_format != sw_fmt ||
            provided->width != avctx->width ||
            provided->height != avctx->height) {
            av_log(avctx, AV_LOG_ERROR,
                   "Provided VideoToolbox hw_frames_ctx does not match "
                   "format=%s sw_format=%s size=%dx%d.\n",
                   av_get_pix_fmt_name(AV_PIX_FMT_VIDEOTOOLBOX),
                   av_get_pix_fmt_name(sw_fmt), avctx->width, avctx->height);
            return AVERROR(EINVAL);
        }
        return 0;
    }

    if (avctx->hw_device_ctx) {
        device_ref = av_buffer_ref(avctx->hw_device_ctx);
        if (!device_ref)
            return AVERROR(ENOMEM);
    } else {
        ret = av_hwdevice_ctx_create(&device_ref, AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                                     NULL, NULL, 0);
        if (ret < 0)
            return ret;
    }

    frames_ref = av_hwframe_ctx_alloc(device_ref);
    av_buffer_unref(&device_ref);
    if (!frames_ref)
        return AVERROR(ENOMEM);

    frames_ctx = (AVHWFramesContext *)frames_ref->data;
    frames_ctx->format = AV_PIX_FMT_VIDEOTOOLBOX;
    frames_ctx->sw_format = sw_fmt;
    frames_ctx->width = avctx->width;
    frames_ctx->height = avctx->height;

    ret = av_hwframe_ctx_init(frames_ref);
    if (ret < 0) {
        av_buffer_unref(&frames_ref);
        return ret;
    }

    avctx->hw_frames_ctx = frames_ref;
    s->owns_hw_frames_ctx = 1;
    return 0;
#else
    if (avctx->pix_fmt != AV_PIX_FMT_VIDEOTOOLBOX)
        return 0;
    av_log(avctx, AV_LOG_ERROR,
           "VideoToolbox hardware-frame decode output requires a macOS build "
           "with VideoToolbox enabled.\n");
    return AVERROR(ENOSYS);
#endif
}

int ff_vtremote_dec_init(AVCodecContext *avctx)
{
    VTRemoteDecContext *s = avctx->priv_data;
    int ret;
    s->codec_id = avctx->codec_id;
    s->fd = -1;
    s->start_time_us = av_gettime_relative();
    s->packets_sent = 0;
    s->frames_recv = 0;
    s->bytes_sent = 0;
    s->bytes_recv = 0;
    vtremote_wbuf_init(&s->pkt_buf);
    s->comp_buf[0] = s->comp_buf[1] = NULL;
    s->comp_buf_cap[0] = s->comp_buf_cap[1] = 0;
    s->zstd_dctx = NULL;
    s->rx_buf = NULL;
    s->rx_buf_cap = 0;
    s->rx_buf_len = 0;
    s->last_frame_pts = AV_NOPTS_VALUE;
    s->output_hw_frames = avctx->pix_fmt == AV_PIX_FMT_VIDEOTOOLBOX;
    s->owns_hw_frames_ctx = 0;

    if (!s->host) {
        av_log(avctx, AV_LOG_ERROR, "vt_remote_host is required\n");
        return AVERROR(EINVAL);
    }

    vtremote_apply_auto_wire_compression(avctx, s);

    if (vtremote_log_enabled(s, AV_LOG_VERBOSE)) {
        av_log(avctx, AV_LOG_VERBOSE, "VT remote decode init codec=%d host=%s timeout_ms=%d\n",
               s->codec_id, s->host, s->timeout_ms);
    }

    ret = vtremote_net_init();
    if (ret < 0)
        return ret;

    ret = vtremote_handshake(avctx);
    if (ret >= 0)
        ret = vtremote_setup_hw_frames(avctx);
    if (ret < 0)
        vtremote_net_close();
    return ret;
}

int ff_vtremote_dec_close(AVCodecContext *avctx)
{
    VTRemoteDecContext *s = avctx->priv_data;
    if (vtremote_log_enabled(s, AV_LOG_VERBOSE))
        av_log(avctx, AV_LOG_VERBOSE, "VT remote decode close\n");
    if (s->fd >= 0)
        VTR_CLOSE_SOCKET(s->fd);
    if (s->owns_hw_frames_ctx)
        av_buffer_unref(&avctx->hw_frames_ctx);
    vtremote_net_close();
    vtremote_wbuf_free(&s->pkt_buf);
    av_freep(&s->comp_buf[0]);
    av_freep(&s->comp_buf[1]);
    av_freep(&s->rx_buf);
    if (s->zstd_dctx) {
        ZSTD_freeDCtx(s->zstd_dctx);
        s->zstd_dctx = NULL;
    }
    if (vtremote_log_enabled(s, AV_LOG_INFO) && s->start_time_us > 0) {
        int64_t elapsed_us = av_gettime_relative() - s->start_time_us;
        double elapsed = elapsed_us > 0 ? (double)elapsed_us / 1000000.0 : 0.0;
        double mbps_in = elapsed > 0 ? (double)s->bytes_sent * 8.0 / (elapsed * 1000000.0) : 0.0;
        double mbps_out = elapsed > 0 ? (double)s->bytes_recv * 8.0 / (elapsed * 1000000.0) : 0.0;
        av_log(avctx, AV_LOG_INFO,
               "VT remote decode summary: packets=%"PRId64" frames=%"PRId64" bytes_in=%"PRId64" bytes_out=%"PRId64
               " elapsed=%.3fs in=%.2fMb/s out=%.2fMb/s\n",
               s->packets_sent, s->frames_recv, s->bytes_sent, s->bytes_recv,
               elapsed, mbps_in, mbps_out);
    }
    av_opt_free(s);
    return 0;
}

static void add_side_data_to_frame(AVFrame *frame, const VTRemoteFrameView *view)
{
    if (!frame || !view || view->side_data_count == 0)
        return;

    for (int i = 0; i < view->side_data_count; i++) {
        enum AVFrameSideDataType type = (enum AVFrameSideDataType)view->side_data[i].type;
        AVFrameSideData *sd = av_frame_new_side_data(frame, type, view->side_data[i].size);
        if (!sd) {
            av_log(NULL, AV_LOG_WARNING, "vtremote: failed to allocate side data type=%d size=%d\n",
                   view->side_data[i].type, view->side_data[i].size);
            continue;
        }
        memcpy(sd->data, view->side_data[i].data, view->side_data[i].size);
    }
}

static int vtremote_copy_or_decompress_plane(VTRemoteDecContext *s,
                                             uint8_t *dst, int dst_stride,
                                             const VTRemotePlaneView *p,
                                             int plane)
{
    int rows;
    int expected;
    int ret;

    if (!dst || dst_stride <= 0 || !p || p->stride <= 0 || p->height <= 0)
        return AVERROR_INVALIDDATA;

    rows = p->height;
    if (p->stride > INT_MAX / rows)
        return AVERROR_INVALIDDATA;
    expected = (int)p->stride * rows;
    if (expected <= 0)
        return AVERROR_INVALIDDATA;

    if (!s || s->wire_compression == 0) {
        int row_bytes = FFMIN((int)p->stride, dst_stride);
        vtremote_copy_plane_rows(dst, dst_stride, p->data, p->stride,
                                 row_bytes, rows);
        return 0;
    }

    if (plane < 0 || plane >= 2)
        return AVERROR_INVALIDDATA;

    if (dst_stride == (int)p->stride) {
        return vtremote_decompress_plane_payload(s, dst, expected, p);
    }

    if (expected > s->comp_buf_cap[plane]) {
        uint8_t *tmp = av_realloc(s->comp_buf[plane], expected);
        if (!tmp)
            return AVERROR(ENOMEM);
        s->comp_buf[plane] = tmp;
        s->comp_buf_cap[plane] = expected;
    }
    ret = vtremote_decompress_plane_payload(s, s->comp_buf[plane], expected, p);
    if (ret < 0)
        return ret;

    vtremote_copy_plane_rows(dst, dst_stride, s->comp_buf[plane],
                             p->stride, FFMIN((int)p->stride, dst_stride),
                             rows);
    return 0;
}

static int fill_hw_frame_from_view(AVCodecContext *avctx,
                                   VTRemoteDecContext *s,
                                   AVFrame *frame,
                                   const VTRemoteFrameView *view)
{
#if VTREMOTE_HAVE_VIDEOTOOLBOX_OUTPUT
    CVPixelBufferRef pixbuf;
    CVReturn cvret;
    int ret;
    int cv_planes;
    enum AVPixelFormat sw_fmt = vtremote_decode_sw_pix_fmt(avctx);

    if (!view || view->plane_count < 1 || view->plane_count > 2)
        return AVERROR_INVALIDDATA;
    if (!avctx->hw_frames_ctx)
        return AVERROR(EINVAL);

    frame->format = AV_PIX_FMT_VIDEOTOOLBOX;
    frame->width = avctx->width;
    frame->height = avctx->height;
    ret = av_hwframe_get_buffer(avctx->hw_frames_ctx, frame, 0);
    if (ret < 0)
        return ret;

    pixbuf = (CVPixelBufferRef)frame->data[3];
    if (!pixbuf)
        return AVERROR_INVALIDDATA;
    if (av_map_videotoolbox_format_to_pixfmt(
            CVPixelBufferGetPixelFormatType(pixbuf)) != sw_fmt) {
        av_log(avctx, AV_LOG_ERROR,
               "Allocated VideoToolbox decode output has format %s, expected %s.\n",
               av_fourcc2str(CVPixelBufferGetPixelFormatType(pixbuf)),
               av_get_pix_fmt_name(sw_fmt));
        return AVERROR_INVALIDDATA;
    }

    cv_planes = CVPixelBufferIsPlanar(pixbuf)
                    ? (int)CVPixelBufferGetPlaneCount(pixbuf)
                    : 1;
    if (cv_planes < view->plane_count)
        return AVERROR_INVALIDDATA;

    cvret = CVPixelBufferLockBaseAddress(pixbuf, 0);
    if (cvret != kCVReturnSuccess)
        return AVERROR_EXTERNAL;

    for (int i = 0; i < view->plane_count; i++) {
        uint8_t *dst;
        size_t dst_stride_size;
        int dst_stride;

        if (CVPixelBufferIsPlanar(pixbuf)) {
            dst = CVPixelBufferGetBaseAddressOfPlane(pixbuf, i);
            dst_stride_size = CVPixelBufferGetBytesPerRowOfPlane(pixbuf, i);
        } else {
            dst = CVPixelBufferGetBaseAddress(pixbuf);
            dst_stride_size = CVPixelBufferGetBytesPerRow(pixbuf);
        }
        if (!dst || dst_stride_size > INT_MAX) {
            ret = AVERROR_INVALIDDATA;
            goto unlock;
        }
        dst_stride = (int)dst_stride_size;
        ret = vtremote_copy_or_decompress_plane(s, dst, dst_stride,
                                                &view->planes[i], i);
        if (ret < 0)
            goto unlock;
    }

    frame->pts = view->pts;
    frame->duration = view->duration;
    frame->pkt_dts = frame->pts;
    add_side_data_to_frame(frame, view);
    ret = 0;

unlock:
    CVPixelBufferUnlockBaseAddress(pixbuf, 0);
    return ret;
#else
    (void)s;
    (void)frame;
    (void)view;
    av_log(avctx, AV_LOG_ERROR,
           "VideoToolbox hardware-frame decode output requires a macOS build "
           "with VideoToolbox enabled.\n");
    return AVERROR(ENOSYS);
#endif
}

static int fill_frame_from_view(AVCodecContext *avctx, AVFrame *frame, const VTRemoteFrameView *view)
{
    if (avctx->pix_fmt == AV_PIX_FMT_VIDEOTOOLBOX)
        return fill_hw_frame_from_view(avctx, NULL, frame, view);
    if (!view || view->plane_count < 1 || view->plane_count > 4)
        return AVERROR_INVALIDDATA;
    frame->format = avctx->pix_fmt;
    frame->width = avctx->width;
    frame->height = avctx->height;
    int ret = ff_get_buffer(avctx, frame, 0);
    if (ret < 0)
        return ret;
    // ff_get_buffer overwrites timestamps based on last packet; restore from view.
    frame->pts = view->pts;
    frame->duration = view->duration;
    frame->pkt_dts = frame->pts;
    for (int i = 0; i < view->plane_count && i < AV_NUM_DATA_POINTERS; i++) {
        const uint8_t *src = view->planes[i].data;
        int src_stride = view->planes[i].stride;
        int rows = view->planes[i].height;
        uint8_t *dst = frame->data[i];
        int dst_stride = frame->linesize[i];
        if (!dst)
            break;
        vtremote_copy_plane_rows(dst, dst_stride, src, src_stride,
                                 FFMIN(src_stride, dst_stride), rows);
    }

    add_side_data_to_frame(frame, view);
    return 0;
}

static void enforce_monotonic_pts(VTRemoteDecContext *s, AVFrame *frame)
{
    if (!s || !frame)
        return;
    int64_t pts = frame->pts;
    if (pts == AV_NOPTS_VALUE)
        pts = frame->pkt_dts;
    if (pts == AV_NOPTS_VALUE) {
        pts = (s->last_frame_pts == AV_NOPTS_VALUE) ? 0 : s->last_frame_pts + 1;
    }
    if (s->last_frame_pts != AV_NOPTS_VALUE && pts <= s->last_frame_pts)
        pts = s->last_frame_pts + 1;
    frame->pts = pts;
    frame->pkt_dts = pts;
    s->last_frame_pts = pts;
}

static int fill_frame_from_compressed_view(AVCodecContext *avctx, VTRemoteDecContext *s,
                                           AVFrame *frame, const VTRemoteFrameView *view)
{
    if (!avctx || !s || !frame || !view)
        return AVERROR(EINVAL);
    if (avctx->pix_fmt == AV_PIX_FMT_VIDEOTOOLBOX)
        return fill_hw_frame_from_view(avctx, s, frame, view);
    if (view->plane_count < 2)
        return AVERROR_INVALIDDATA;

    frame->format = avctx->pix_fmt;
    frame->width = avctx->width;
    frame->height = avctx->height;
    int ret = ff_get_buffer(avctx, frame, 0);
    if (ret < 0)
        return ret;
    // ff_get_buffer overwrites timestamps based on last packet; restore from view.
    frame->pts = view->pts;
    frame->duration = view->duration;
    frame->pkt_dts = frame->pts;

    for (int i = 0; i < 2; i++) {
        uint8_t *dst = frame->data[i];
        int dst_stride = frame->linesize[i];
        ret = vtremote_copy_or_decompress_plane(s, dst, dst_stride,
                                                &view->planes[i], i);
        if (ret < 0)
            return ret;
    }

    add_side_data_to_frame(frame, view);
    return 0;
}

int ff_vtremote_decode(AVCodecContext *avctx, AVFrame *frame, int *got_frame, AVPacket *pkt)
{
    VTRemoteDecContext *s = avctx->priv_data;
    if (s->done)
        return AVERROR_EOF;

    if (pkt && pkt->size > 0) {
        VTRemoteWBuf *payload = &s->pkt_buf;
        vtremote_wbuf_reset(payload);
        /* Preserve timestamp semantics, including AV_NOPTS_VALUE. */
        int64_t pts = pkt->pts;
        int64_t dts = pkt->dts;
        int64_t dur = pkt->duration > 0 ? pkt->duration : 0;
        int ret = vtremote_payload_packet(payload,
                                          pts, dts, dur,
                                          (pkt->flags & AV_PKT_FLAG_KEY) ? 1 : 0,
                                          pkt->data, pkt->size);
        if (ret < 0)
            return ret;
        ret = vtremote_send_msg(s, VTREMOTE_MSG_PACKET, payload);
        if (ret < 0)
            return ret;
        s->packets_sent++;
    } else if (!s->flushing) {
        s->flushing = 1;
        VTRemoteWBuf empty = {0};
        int ret = vtremote_send_msg(s, VTREMOTE_MSG_FLUSH, &empty);
        if (ret < 0)
            return ret;
    }

    if (s->decode_async) {
        for (;;) {
            VTRemoteMsgHeader hdr;
            uint8_t *payload = NULL;
            int ret;
            if (s->flushing) {
                /* During flush, block until we receive a frame or DONE. */
                ret = vtremote_read_msg(s, &hdr, &payload);
            } else {
                int64_t backlog = s->packets_sent - s->frames_recv;
                int depth = s->decode_reorder_depth >= 0 ? s->decode_reorder_depth : 8;
                int limit = FFMAX(2, depth + 2);
                int timeout_ms = backlog > limit ? 2 : 0;
                int ready = wait_readable(s->fd, timeout_ms);
                if (ready <= 0) {
                    if (got_frame)
                        *got_frame = 0;
                    return 0;
                }
                ret = vtremote_read_msg(s, &hdr, &payload);
            }
            if (ret == AVERROR(EAGAIN)) {
                if (got_frame)
                    *got_frame = 0;
                return 0;
            }
            if (ret < 0)
                return ret;

            switch (hdr.type) {
            case VTREMOTE_MSG_FRAME:
            {
                VTRemoteFrameView view;
                ret = vtremote_parse_frame(payload, hdr.length, &view);
                if (ret < 0) {
                    return ret;
                }
                if (s->wire_compression == 1 || s->wire_compression == 2) {
                    ret = fill_frame_from_compressed_view(avctx, s, frame, &view);
                } else {
                    ret = fill_frame_from_view(avctx, frame, &view);
                }
            if (ret < 0)
                return ret;
            if (s->decode_async)
                enforce_monotonic_pts(s, frame);
            s->frames_recv++;
            if (got_frame)
                *got_frame = 1;
            return 0;
            }
            case VTREMOTE_MSG_DONE:
                s->done = 1;
                return AVERROR_EOF;
            case VTREMOTE_MSG_PING:
            {
                VTRemoteWBuf empty = {0};
                vtremote_send_msg(s, VTREMOTE_MSG_PONG, &empty);
                break;
            }
            case VTREMOTE_MSG_ERROR:
            {
                vtremote_log_error_msg(avctx, payload, hdr.length);
                return AVERROR(EIO);
            }
            default:
                break;
            }
        }
    }

    for (;;) {
        VTRemoteMsgHeader hdr;
        uint8_t *payload = NULL;
        int ret = vtremote_read_msg(s, &hdr, &payload);
        if (ret == AVERROR(EAGAIN)) {
            if (got_frame)
                *got_frame = 0;
            return 0;
        }
        if (ret < 0)
            return ret;

        switch (hdr.type) {
        case VTREMOTE_MSG_FRAME:
        {
            VTRemoteFrameView view;
            ret = vtremote_parse_frame(payload, hdr.length, &view);
            if (ret < 0) {
                return ret;
            }
            if (s->wire_compression == 1 || s->wire_compression == 2) {
                ret = fill_frame_from_compressed_view(avctx, s, frame, &view);
            } else {
                ret = fill_frame_from_view(avctx, frame, &view);
            }
            if (ret < 0)
                return ret;
            if (s->decode_async)
                enforce_monotonic_pts(s, frame);
            s->frames_recv++;
            if (got_frame)
                *got_frame = 1;
            return 0;
        }
        case VTREMOTE_MSG_DONE:
            s->done = 1;
            return AVERROR_EOF;
        case VTREMOTE_MSG_PING:
        {
            VTRemoteWBuf empty = {0};
            vtremote_send_msg(s, VTREMOTE_MSG_PONG, &empty);
            break;
        }
        case VTREMOTE_MSG_ERROR:
        {
            vtremote_log_error_msg(avctx, payload, hdr.length);
            return AVERROR(EIO);
        }
        default:
            break;
        }
    }
}
