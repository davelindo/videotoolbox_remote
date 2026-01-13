/*
 * VTRemote decoder common scaffolding
 */

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
#endif

#include "config.h"
#include "config_components.h"
#include "avcodec.h"
#include "codec_internal.h"
#include "decode.h"
#include "internal.h"
#include "libavutil/avstring.h"
#include "libavutil/ffversion.h"
#include "libavutil/opt.h"
#include "libavutil/mem.h"
#include "libavutil/common.h"
#include "libavutil/pixfmt.h"
#include "libavutil/pixdesc.h"
#include "libavutil/time.h"
#include "vtremote_dec_common.h"
#include "vtremote_proto.h"
#include <lz4.h>

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
        s->bytes_recv += VTREMOTE_HEADER_SIZE;
        return 0;
    }
    uint8_t *buf = av_malloc(hdr->length);
    if (!buf)
        return AVERROR(ENOMEM);
    ret = read_full(s->fd, buf, hdr->length);
    if (ret < 0) {
        av_free(buf);
        return ret;
    }
    *payload = buf;
    s->bytes_recv += VTREMOTE_HEADER_SIZE + hdr->length;
    return 0;
}

static int vtremote_handle_hello_ack(AVCodecContext *avctx, const uint8_t *payload, int len)
{
    VTRemoteRBuf r;
    vtremote_rbuf_init(&r, payload, len);
    uint8_t status;
    int ret = vtremote_rbuf_read_u8(&r, &status);
    if (ret < 0)
        return ret;
    if (status != 0)
        return AVERROR(EACCES);

    const uint8_t *s; int slen;
    vtremote_rbuf_read_str(&r, &s, &slen);
    vtremote_rbuf_read_str(&r, &s, &slen);
    uint8_t caps = 0;
    vtremote_rbuf_read_u8(&r, &caps);
    for (int i = 0; i < caps; i++)
        vtremote_rbuf_read_str(&r, &s, &slen);
    uint16_t max_sessions, active;
    vtremote_rbuf_read_u16(&r, &max_sessions);
    vtremote_rbuf_read_u16(&r, &active);
    return 0;
}

static enum AVPixelFormat pix_fmt_from_wire(uint8_t pix)
{
    switch (pix) {
    case 1: return AV_PIX_FMT_NV12;
    case 2: return AV_PIX_FMT_P010LE;
    default: return AV_PIX_FMT_NONE;
    }
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
    if (pf != AV_PIX_FMT_NONE)
        avctx->pix_fmt = pf;
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
    if (hdr.type != VTREMOTE_MSG_HELLO_ACK) {
        av_free(pl);
        VTR_CLOSE_SOCKET(fd);
        s->fd = -1;
        return AVERROR_INVALIDDATA;
    }
    ret = vtremote_handle_hello_ack(avctx, pl, hdr.length);
    av_free(pl);
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

    int wire_pix_fmt = 0;
    switch (avctx->pix_fmt) {
    case AV_PIX_FMT_NV12:
        wire_pix_fmt = 1;
        break;
    case AV_PIX_FMT_P010LE:
        wire_pix_fmt = 2;
        break;
    default:
        av_log(avctx, AV_LOG_ERROR, "Unsupported pix_fmt for vtremote decode: %s\n",
               av_get_pix_fmt_name(avctx->pix_fmt));
        ret = AVERROR(EINVAL);
        goto cfg_fail;
    }

    VTRemoteWBuf cfg;
    vtremote_payload_configure(&cfg,
                              avctx->width, avctx->height,
                              wire_pix_fmt,
                              avctx->time_base.num, avctx->time_base.den,
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
    if (hdr.type != VTREMOTE_MSG_CONFIGURE_ACK) {
        av_free(pl);
        VTR_CLOSE_SOCKET(fd);
        s->fd = -1;
        return AVERROR_INVALIDDATA;
    }
    ret = vtremote_handle_configure_ack(avctx, pl, hdr.length);
    av_free(pl);
    if (ret < 0) {
        VTR_CLOSE_SOCKET(fd);
        s->fd = -1;
        return ret;
    }

    s->connected = 1;
    return 0;
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
    s->lz4_buf[0] = s->lz4_buf[1] = NULL;
    s->lz4_buf_cap[0] = s->lz4_buf_cap[1] = 0;

    if (!s->host) {
        av_log(avctx, AV_LOG_ERROR, "vt_remote_host is required\n");
        return AVERROR(EINVAL);
    }
    if (s->wire_compression == 2) {
        av_log(avctx, AV_LOG_ERROR, "vt_remote_wire_compression=zstd not supported\n");
        return AVERROR(ENOSYS);
    }

    if (vtremote_log_enabled(s, AV_LOG_VERBOSE)) {
        av_log(avctx, AV_LOG_VERBOSE, "VT remote decode init codec=%d host=%s timeout_ms=%d\n",
               s->codec_id, s->host, s->timeout_ms);
    }

    ret = vtremote_net_init();
    if (ret < 0)
        return ret;

    ret = vtremote_handshake(avctx);
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
    vtremote_net_close();
    vtremote_wbuf_free(&s->pkt_buf);
    av_freep(&s->lz4_buf[0]);
    av_freep(&s->lz4_buf[1]);
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

static int fill_frame_from_view(AVCodecContext *avctx, AVFrame *frame, const VTRemoteFrameView *view)
{
    if (!view || view->plane_count < 2)
        return AVERROR_INVALIDDATA;
    frame->format = avctx->pix_fmt;
    frame->width = avctx->width;
    frame->height = avctx->height;
    frame->pts = view->pts;
    frame->duration = view->duration;
    int ret = ff_get_buffer(avctx, frame, 0);
    if (ret < 0)
        return ret;
    for (int i = 0; i < 2; i++) {
        const uint8_t *src = view->planes[i].data;
        int src_stride = view->planes[i].stride;
        int rows = view->planes[i].height;
        uint8_t *dst = frame->data[i];
        int dst_stride = frame->linesize[i];
        int row_bytes = FFMIN(src_stride, dst_stride);
        for (int y = 0; y < rows; y++) {
            memcpy(dst + y * dst_stride, src + y * src_stride, row_bytes);
        }
    }
    return 0;
}

static int decompress_frame_lz4(VTRemoteDecContext *s, const VTRemoteFrameView *in, VTRemoteFrameView *out)
{
    if (!s || !in || !out)
        return AVERROR(EINVAL);
    *out = *in;
    if (in->plane_count < 2)
        return AVERROR_INVALIDDATA;
    for (int i = 0; i < 2; i++) {
        int expected = (int)in->planes[i].stride * (int)in->planes[i].height;
        if (expected <= 0)
            return AVERROR_INVALIDDATA;
        if (expected > s->lz4_buf_cap[i]) {
            uint8_t *tmp = av_realloc(s->lz4_buf[i], expected);
            if (!tmp)
                return AVERROR(ENOMEM);
            s->lz4_buf[i] = tmp;
            s->lz4_buf_cap[i] = expected;
        }
        int decoded = LZ4_decompress_safe((const char *)in->planes[i].data,
                                          (char *)s->lz4_buf[i],
                                          in->planes[i].data_len,
                                          expected);
        if (decoded != expected)
            return AVERROR_INVALIDDATA;
        out->planes[i].data = s->lz4_buf[i];
        out->planes[i].data_len = expected;
    }
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
        int64_t pts = (pkt->pts == AV_NOPTS_VALUE) ? 0 : pkt->pts;
        int64_t dts = (pkt->dts == AV_NOPTS_VALUE) ? pts : pkt->dts;
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
                av_free(payload);
                return ret;
            }
            if (s->wire_compression == 1) {
                VTRemoteFrameView dec_view;
                ret = decompress_frame_lz4(s, &view, &dec_view);
                if (ret < 0) {
                    av_free(payload);
                    return ret;
                }
                ret = fill_frame_from_view(avctx, frame, &dec_view);
            } else {
                ret = fill_frame_from_view(avctx, frame, &view);
            }
            av_free(payload);
            if (ret < 0)
                return ret;
            s->frames_recv++;
            if (got_frame)
                *got_frame = 1;
            return 0;
        }
        case VTREMOTE_MSG_DONE:
            av_free(payload);
            s->done = 1;
            return AVERROR_EOF;
        case VTREMOTE_MSG_PING:
        {
            VTRemoteWBuf empty = {0};
            vtremote_send_msg(s, VTREMOTE_MSG_PONG, &empty);
            av_free(payload);
            break;
        }
        case VTREMOTE_MSG_ERROR:
        {
            uint32_t code = 0;
            VTRemoteRBuf er;
            vtremote_rbuf_init(&er, payload, hdr.length);
            vtremote_rbuf_read_u32(&er, &code);
            const uint8_t *msg = NULL; int mlen = 0;
            if (vtremote_rbuf_read_str(&er, &msg, &mlen) == 0)
                av_log(avctx, AV_LOG_ERROR, "vtremote server error %u: %.*s\n", code, mlen, msg);
            else
                av_log(avctx, AV_LOG_ERROR, "vtremote server error %u\n", code);
            av_free(payload);
            return AVERROR(EIO);
        }
        default:
            av_free(payload);
            break;
        }
    }
}
