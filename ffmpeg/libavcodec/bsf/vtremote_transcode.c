/*
 * VTRemote transcode bitstream filter
 */

#include "config.h"
#include "config_components.h"

#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#if defined(HAVE_WINSOCK2_H) && HAVE_WINSOCK2_H
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <netdb.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#endif

#include "avcodec.h"
#include "bsf.h"
#include "bsf_internal.h"
#include "libavutil/avstring.h"
#include "libavutil/common.h"
#include "libavutil/error.h"
#include "libavutil/ffversion.h"
#include "libavutil/intreadwrite.h"
#include "libavutil/log.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/rational.h"
#include "libavutil/time.h"
#include "vtremote_proto.h"

#if defined(HAVE_WINSOCK2_H) && HAVE_WINSOCK2_H
#define VTR_CLOSE_SOCKET closesocket
#define VTR_SOCKOPT_ARG (const char *)
static int vtremote_net_init(void) {
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa))
        return AVERROR(WSAGetLastError());
    return 0;
}
static void vtremote_net_close(void) { WSACleanup(); }
static int vtremote_sock_errno(void) { return WSAGetLastError(); }
#else
#define VTR_CLOSE_SOCKET close
#define VTR_SOCKOPT_ARG
static int vtremote_net_init(void) { return 0; }
static void vtremote_net_close(void) {}
static int vtremote_sock_errno(void) { return errno; }
#endif

#ifndef MSG_DONTWAIT
#define MSG_DONTWAIT 0
#endif

#define MIN_HVCC_LENGTH 23

typedef struct VTRemoteTranscodeContext {
    const AVClass *class;
    char *host;
    char *token;
    char *out_codec;
    char *scale_mode;
    int port;
    int timeout_ms;
    int inflight;
    int log_level;
    int pixel_format;
    int out_width;
    int out_height;
    int decode_async;
    int decode_reorder_depth;
    int bitrate;
    int maxrate;
    int gop;
    int max_b_frames;
    int profile;
    int level;
    int entropy;
    int allow_sw;
    int require_sw;
    int realtime;
    int prio_speed;
    int power_efficient;
    int spatial_aq;
    int max_ref_frames;
    int max_slice_bytes;
    int constant_bit_rate;
    double alpha_quality;
    int color_range;
    int colorspace;
    int color_primaries;
    int color_trc;
    int sar_num;
    int sar_den;
    int a53_cc;
    int64_t flags;
    int fd;
    int connected;
    int flushing;
    int done;
    int codec_id_in;
    int codec_id_out;
    int64_t packets_sent;
    int64_t packets_recv;
    int64_t last_dts;
    VTRemoteWBuf pkt_buf;
    AVPacket *pkt_queue;
    int pkt_q_size;
    int pkt_q_head;
    int pkt_q_count;
    AVBSFContext *annexb_bsf;
} VTRemoteTranscodeContext;

static int set_socket_timeout(int fd, int timeout_ms) {
    struct timeval tv;
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, VTR_SOCKOPT_ARG &tv, sizeof(tv)) < 0)
        return AVERROR(vtremote_sock_errno());
    if (setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, VTR_SOCKOPT_ARG &tv, sizeof(tv)) < 0)
        return AVERROR(vtremote_sock_errno());
    return 0;
}

static void configure_socket_buffers(int fd) {
    int bufsize = 16 * 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, VTR_SOCKOPT_ARG &bufsize, sizeof(bufsize));
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, VTR_SOCKOPT_ARG &bufsize, sizeof(bufsize));
}

static int write_full(int fd, const uint8_t *buf, int size) {
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

static int read_full(int fd, uint8_t *buf, int size) {
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

static int check_readable(int fd, int timeout_ms) {
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

static int connect_hostport(const char *hostport, int timeout_ms) {
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
    hints.ai_family = AF_INET;
    int err = getaddrinfo(host, port, &hints, &res);
    if (err)
        return AVERROR(EIO);

    int fd = -1;
    for (rp = res; rp; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0)
            continue;
        configure_socket_buffers(fd);
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

static int vtremote_add_opt(VTRemoteKV **opts, int *count, int *cap,
                            const char *key, char *value) {
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

static void vtremote_free_opts(VTRemoteKV **opts, int count) {
    if (!opts || !*opts)
        return;
    for (int i = 0; i < count; i++)
        av_freep((void *)&(*opts)[i].value);
    av_freep(opts);
}

static const char *codec_name_for_id(int codec_id) {
    switch (codec_id) {
    case AV_CODEC_ID_H264: return "h264";
    case AV_CODEC_ID_HEVC: return "hevc";
    default: return "unknown";
    }
}

static int codec_id_from_name(const char *name) {
    if (!name || !*name)
        return 0;
    if (!strcmp(name, "h264"))
        return AV_CODEC_ID_H264;
    if (!strcmp(name, "hevc"))
        return AV_CODEC_ID_HEVC;
    return 0;
}

static int vtremote_hevc_extradata_to_annexb(const uint8_t *in, int in_size,
                                             uint8_t **out, int *out_size) {
    const uint8_t *p = in;
    const uint8_t *end = in + in_size;
    uint8_t *buf = NULL;
    int size = 0;

    if (in_size < MIN_HVCC_LENGTH)
        return AVERROR_INVALIDDATA;

    if (AV_RB24(in) == 1 || AV_RB32(in) == 1) {
        buf = av_mallocz(in_size + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!buf)
            return AVERROR(ENOMEM);
        memcpy(buf, in, in_size);
        *out = buf;
        *out_size = in_size;
        return 0;
    }

    p += 21;
    if (p + 2 > end)
        return AVERROR_INVALIDDATA;
    p++;
    int num_arrays = *p++;

    for (int i = 0; i < num_arrays; i++) {
        if (p + 3 > end) {
            av_freep(&buf);
            return AVERROR_INVALIDDATA;
        }
        p++;
        int num_nalus = AV_RB16(p);
        p += 2;

        for (int j = 0; j < num_nalus; j++) {
            if (p + 2 > end) {
                av_freep(&buf);
                return AVERROR_INVALIDDATA;
            }
            int nal_len = AV_RB16(p);
            p += 2;
            if (nal_len <= 0 || p + nal_len > end) {
                av_freep(&buf);
                return AVERROR_INVALIDDATA;
            }
            if (size > INT_MAX - (nal_len + 4 + AV_INPUT_BUFFER_PADDING_SIZE)) {
                av_freep(&buf);
                return AVERROR(ENOMEM);
            }
            uint8_t *tmp = av_realloc(buf, size + nal_len + 4 + AV_INPUT_BUFFER_PADDING_SIZE);
            if (!tmp) {
                av_freep(&buf);
                return AVERROR(ENOMEM);
            }
            buf = tmp;
            AV_WB32(buf + size, 0x00000001);
            memcpy(buf + size + 4, p, nal_len);
            size += nal_len + 4;
            p += nal_len;
        }
    }

    if (!buf)
        return AVERROR_INVALIDDATA;
    *out = buf;
    *out_size = size;
    return 0;
}

static int vtremote_h264_extradata_to_annexb(const uint8_t *in, int in_size,
                                             uint8_t **out, int *out_size) {
    uint8_t *buf = NULL;
    int size = 0;

    if (in_size < 7)
        return AVERROR_INVALIDDATA;

    if (AV_RB24(in) == 1 || AV_RB32(in) == 1) {
        buf = av_mallocz(in_size + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!buf)
            return AVERROR(ENOMEM);
        memcpy(buf, in, in_size);
        *out = buf;
        *out_size = in_size;
        return 0;
    }

    if (in[0] != 1) {
        buf = av_mallocz(in_size + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!buf)
            return AVERROR(ENOMEM);
        memcpy(buf, in, in_size);
        *out = buf;
        *out_size = in_size;
        return 0;
    }

    int pos = 5;
    int sps_count = in[pos++] & 0x1f;
    for (int i = 0; i < sps_count && pos + 2 <= in_size; i++) {
        int sps_len = AV_RB16(in + pos);
        pos += 2;
        if (pos + sps_len > in_size)
            break;
        size += 4 + sps_len;
        pos += sps_len;
    }
    int pps_count = in[pos++] & 0xff;
    for (int i = 0; i < pps_count && pos + 2 <= in_size; i++) {
        int pps_len = AV_RB16(in + pos);
        pos += 2;
        if (pos + pps_len > in_size)
            break;
        size += 4 + pps_len;
        pos += pps_len;
    }

    buf = av_mallocz(size + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!buf)
        return AVERROR(ENOMEM);

    int w = 0;
    pos = 5;
    sps_count = in[pos++] & 0x1f;
    for (int i = 0; i < sps_count && pos + 2 <= in_size; i++) {
        int sps_len = AV_RB16(in + pos);
        pos += 2;
        if (pos + sps_len > in_size)
            break;
        AV_WB32(buf + w, 0x00000001);
        w += 4;
        memcpy(buf + w, in + pos, sps_len);
        w += sps_len;
        pos += sps_len;
    }
    pps_count = in[pos++] & 0xff;
    for (int i = 0; i < pps_count && pos + 2 <= in_size; i++) {
        int pps_len = AV_RB16(in + pos);
        pos += 2;
        if (pos + pps_len > in_size)
            break;
        AV_WB32(buf + w, 0x00000001);
        w += 4;
        memcpy(buf + w, in + pos, pps_len);
        w += pps_len;
        pos += pps_len;
    }

    *out = buf;
    *out_size = w;
    return 0;
}

static int vtremote_send_msg(VTRemoteTranscodeContext *s, int msg_type, VTRemoteWBuf *payload) {
    if (!s)
        return AVERROR(EINVAL);
    const uint8_t *payload_data = payload ? payload->data : NULL;
    const uint32_t payload_size = payload ? (uint32_t)payload->size : 0;
    uint8_t header_buf[VTREMOTE_HEADER_SIZE];
    VTRemoteMsgHeader hdr = {
        .magic = VTREMOTE_PROTO_MAGIC,
        .version = VTREMOTE_PROTO_VERSION,
        .type = msg_type,
        .length = payload_size,
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
    return 0;
}

static int vtremote_read_msg(VTRemoteTranscodeContext *s, VTRemoteMsgHeader *hdr, uint8_t **payload) {
    uint8_t header_buf[VTREMOTE_HEADER_SIZE];
    if (!s || !hdr || !payload)
        return AVERROR(EINVAL);
    int ret = read_full(s->fd, header_buf, VTREMOTE_HEADER_SIZE);
    if (ret < 0)
        return ret;
    ret = vtremote_read_header(header_buf, VTREMOTE_HEADER_SIZE, hdr);
    if (ret < 0)
        return ret;
    if (hdr->length == 0) {
        *payload = NULL;
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
    return 0;
}

static int vtremote_read_msg_nonblock(VTRemoteTranscodeContext *s, VTRemoteMsgHeader *hdr, uint8_t **payload) {
    if (!s || !hdr || !payload)
        return AVERROR(EINVAL);
    int ready = check_readable(s->fd, 0);
    if (ready <= 0)
        return AVERROR(EAGAIN);
    return vtremote_read_msg(s, hdr, payload);
}

static void vtremote_log_error_payload(AVBSFContext *ctx, const uint8_t *payload, int len)
{
    uint32_t code = 0;
    VTRemoteRBuf r;
    vtremote_rbuf_init(&r, payload, len);
    vtremote_rbuf_read_u32(&r, &code);
    const uint8_t *msg = NULL;
    int mlen = 0;
    if (vtremote_rbuf_read_str(&r, &msg, &mlen) == 0)
        av_log(ctx, AV_LOG_ERROR, "vtremote server error %u: %.*s\n", code, mlen, msg);
    else
        av_log(ctx, AV_LOG_ERROR, "vtremote server error %u\n", code);
}

static int vtremote_handle_hello_ack(AVBSFContext *ctx, const uint8_t *payload, int len) {
    VTRemoteRBuf r;
    vtremote_rbuf_init(&r, payload, len);
    uint8_t status;
    int ret = vtremote_rbuf_read_u8(&r, &status);
    if (ret < 0)
        return ret;

    const uint8_t *server_name = NULL, *server_ver = NULL;
    int server_name_len = 0, server_ver_len = 0;
    vtremote_rbuf_read_str(&r, &server_name, &server_name_len);
    vtremote_rbuf_read_str(&r, &server_ver, &server_ver_len);
    uint8_t caps = 0;
    vtremote_rbuf_read_u8(&r, &caps);
    for (int i = 0; i < caps; i++) {
        const uint8_t *s = NULL;
        int slen = 0;
        vtremote_rbuf_read_str(&r, &s, &slen);
    }
    uint16_t max_sessions = 0, active = 0;
    vtremote_rbuf_read_u16(&r, &max_sessions);
    vtremote_rbuf_read_u16(&r, &active);

    if (status != 0) {
        if (status == 1) {
            av_log(ctx, AV_LOG_ERROR,
                   "vtremote server busy (sessions active=%u max=%u) [%.*s %.*s]\n",
                   active, max_sessions,
                   server_name_len, server_name ? (const char *)server_name : "",
                   server_ver_len, server_ver ? (const char *)server_ver : "");
            return AVERROR(EAGAIN);
        }
        if (status == 2) {
            av_log(ctx, AV_LOG_ERROR,
                   "vtremote server unauthorized (token mismatch) [%.*s %.*s]\n",
                   server_name_len, server_name ? (const char *)server_name : "",
                   server_ver_len, server_ver ? (const char *)server_ver : "");
            return AVERROR(EACCES);
        }
        av_log(ctx, AV_LOG_ERROR,
               "vtremote server refused handshake (status=%u) [%.*s %.*s]\n", status,
               server_name_len, server_name ? (const char *)server_name : "",
               server_ver_len, server_ver ? (const char *)server_ver : "");
        return AVERROR(EACCES);
    }
    return 0;
}

static int vtremote_handle_configure_ack(AVBSFContext *ctx, const uint8_t *payload, int len) {
    VTRemoteTranscodeContext *s = ctx->priv_data;
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
        const uint8_t *avcc = payload + r.pos;
        uint8_t *annexb = NULL;
        int annexb_size = 0;

        if (s->codec_id_out == AV_CODEC_ID_HEVC) {
            int conv = vtremote_hevc_extradata_to_annexb(avcc, extralen, &annexb, &annexb_size);
            if (conv < 0)
                return conv;
        } else if (s->codec_id_out == AV_CODEC_ID_H264) {
            int conv = vtremote_h264_extradata_to_annexb(avcc, extralen, &annexb, &annexb_size);
            if (conv < 0)
                return conv;
        }

        if (annexb) {
            av_freep(&ctx->par_out->extradata);
            ctx->par_out->extradata = annexb;
            ctx->par_out->extradata_size = annexb_size;
        }
        r.pos += extralen;
    }

    uint8_t reported_pix = 0;
    vtremote_rbuf_read_u8(&r, &reported_pix);
    (void)reported_pix;
    uint8_t warn_count = 0;
    vtremote_rbuf_read_u8(&r, &warn_count);
    const uint8_t *s_ptr;
    int s_len;
    for (int i = 0; i < warn_count; i++) {
        if (vtremote_rbuf_read_str(&r, &s_ptr, &s_len) < 0)
            break;
        av_log(ctx, AV_LOG_WARNING, "vtremote warning: %.*s\n", s_len, s_ptr);
    }
    return 0;
}

static int vtremote_handshake(AVBSFContext *ctx) {
    VTRemoteTranscodeContext *s = ctx->priv_data;
    if (!s->host || !*s->host)
        return AVERROR(EINVAL);
    char hostport[320];
    if (strrchr(s->host, ':')) {
        av_strlcpy(hostport, s->host, sizeof(hostport));
    } else {
        if (s->port <= 0 || s->port > 65535)
            return AVERROR(EINVAL);
        snprintf(hostport, sizeof(hostport), "%s:%d", s->host, s->port);
    }
    int fd = connect_hostport(hostport, s->timeout_ms);
    if (fd < 0) {
        av_log(ctx, AV_LOG_ERROR, "Failed to connect to %s\n", hostport);
        return fd;
    }
    s->fd = fd;

    VTRemoteWBuf payload;
    vtremote_wbuf_init(&payload);
    vtremote_payload_hello(&payload, s->token, codec_name_for_id(s->codec_id_in),
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
        vtremote_log_error_payload(ctx, pl, hdr.length);
        av_free(pl);
        VTR_CLOSE_SOCKET(fd);
        s->fd = -1;
        return AVERROR(EIO);
    }
    if (hdr.type != VTREMOTE_MSG_HELLO_ACK) {
        av_free(pl);
        VTR_CLOSE_SOCKET(fd);
        s->fd = -1;
        return AVERROR_INVALIDDATA;
    }
    ret = vtremote_handle_hello_ack(ctx, pl, hdr.length);
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

    tmp = av_strdup("transcode");
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "mode", tmp);
    if (ret < 0)
        goto cfg_fail;

    if (s->decode_async >= 0) {
        tmp = av_asprintf("%d", s->decode_async);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "decode_async", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->decode_reorder_depth >= -1) {
        tmp = av_asprintf("%d", s->decode_reorder_depth);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "decode_reorder_depth", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->out_codec && *s->out_codec) {
        tmp = av_strdup(s->out_codec);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "out_codec", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->out_width > 0) {
        tmp = av_asprintf("%d", s->out_width);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "out_width", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->out_height > 0) {
        tmp = av_asprintf("%d", s->out_height);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "out_height", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->scale_mode && *s->scale_mode) {
        tmp = av_strdup(s->scale_mode);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "scale_mode", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->bitrate > 0) {
        tmp = av_asprintf("%d", s->bitrate);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "bitrate", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->maxrate > 0) {
        tmp = av_asprintf("%d", s->maxrate);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "maxrate", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->gop > 0) {
        tmp = av_asprintf("%d", s->gop);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "gop", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->max_b_frames >= 0) {
        tmp = av_asprintf("%d", s->max_b_frames);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "max_b_frames", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->profile >= 0) {
        tmp = av_asprintf("%d", s->profile);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "profile", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->level > 0) {
        tmp = av_asprintf("%d", s->level);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "level", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->entropy > 0) {
        tmp = av_asprintf("%d", s->entropy);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "entropy", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->allow_sw) {
        tmp = av_strdup("1");
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "allow_sw", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->require_sw) {
        tmp = av_strdup("1");
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "require_sw", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->realtime >= 0) {
        tmp = av_asprintf("%d", s->realtime);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "realtime", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->prio_speed >= 0) {
        tmp = av_asprintf("%d", s->prio_speed);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "prio_speed", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->power_efficient >= 0) {
        tmp = av_asprintf("%d", s->power_efficient);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "power_efficient", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->spatial_aq >= 0) {
        tmp = av_asprintf("%d", s->spatial_aq);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "spatial_aq", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->max_ref_frames > 0) {
        tmp = av_asprintf("%d", s->max_ref_frames);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "max_ref_frames", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->max_slice_bytes >= 0) {
        tmp = av_asprintf("%d", s->max_slice_bytes);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "max_slice_bytes", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->constant_bit_rate) {
        tmp = av_strdup("1");
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "constant_bit_rate", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->alpha_quality > 0.0) {
        tmp = av_asprintf("%.3f", s->alpha_quality);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "alpha_quality", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->color_range > 0) {
        tmp = av_asprintf("%d", s->color_range);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "color_range", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->colorspace > 0) {
        tmp = av_asprintf("%d", s->colorspace);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "colorspace", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->color_primaries > 0) {
        tmp = av_asprintf("%d", s->color_primaries);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "color_primaries", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->color_trc > 0) {
        tmp = av_asprintf("%d", s->color_trc);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "color_trc", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->sar_num > 0 && s->sar_den > 0) {
        tmp = av_asprintf("%d", s->sar_num);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "sar_num", tmp);
        if (ret < 0) goto cfg_fail;
        tmp = av_asprintf("%d", s->sar_den);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "sar_den", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->a53_cc >= 0) {
        tmp = av_asprintf("%d", s->a53_cc);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "a53_cc", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->flags != 0) {
        tmp = av_asprintf("%" PRId64, s->flags);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "flags", tmp);
        if (ret < 0) goto cfg_fail;
    }

    VTRemoteWBuf cfg;
    vtremote_wbuf_init(&cfg);
    const uint8_t *extradata = ctx->par_in->extradata;
    uint32_t extradata_len = ctx->par_in->extradata_size > 0 ? (uint32_t)ctx->par_in->extradata_size : 0;
    AVRational tb = ctx->time_base_in.num && ctx->time_base_in.den ? ctx->time_base_in : (AVRational){1, 90000};
    int retcfg = vtremote_payload_configure(&cfg,
                                            ctx->par_in->width,
                                            ctx->par_in->height,
                                            (uint8_t)s->pixel_format,
                                            tb.num, tb.den,
                                            0, 1,
                                            opts, opt_count,
                                            extradata, extradata_len);
    if (retcfg < 0) {
        vtremote_wbuf_free(&cfg);
        ret = retcfg;
        goto cfg_fail;
    }
    ret = vtremote_send_msg(s, VTREMOTE_MSG_CONFIGURE, &cfg);
    vtremote_wbuf_free(&cfg);
    if (ret < 0)
        goto cfg_fail;

    ret = vtremote_read_msg(s, &hdr, &pl);
    if (ret < 0)
        goto cfg_fail;
    if (hdr.type == VTREMOTE_MSG_ERROR) {
        vtremote_log_error_payload(ctx, pl, hdr.length);
        av_free(pl);
        ret = AVERROR(EIO);
        goto cfg_fail;
    }
    if (hdr.type != VTREMOTE_MSG_CONFIGURE_ACK) {
        av_free(pl);
        ret = AVERROR_INVALIDDATA;
        goto cfg_fail;
    }
    ret = vtremote_handle_configure_ack(ctx, pl, hdr.length);
    av_free(pl);
    if (ret < 0)
        goto cfg_fail;

    vtremote_free_opts(&opts, opt_count);
    s->connected = 1;
    return 0;

cfg_fail:
    vtremote_free_opts(&opts, opt_count);
    VTR_CLOSE_SOCKET(fd);
    s->fd = -1;
    return ret;
}

static int enqueue_packet(AVBSFContext *ctx, const uint8_t *payload, int payload_size) {
    VTRemoteTranscodeContext *s = ctx->priv_data;
    VTRemotePacketView view;
    int ret = vtremote_parse_packet(payload, payload_size, &view);
    if (ret < 0)
        return ret;
    if (!s->pkt_queue)
        return AVERROR_BUG;
    int idx = (s->pkt_q_head + s->pkt_q_count) % s->pkt_q_size;
    AVPacket *dst = &s->pkt_queue[idx];
    av_packet_unref(dst);
    ret = av_new_packet(dst, view.data_len);
    if (ret < 0)
        return ret;
    memcpy(dst->data, view.data, view.data_len);
    dst->pts = view.pts;
    dst->dts = view.dts;
    dst->duration = view.duration;
    dst->flags = (view.flags & 1) ? AV_PKT_FLAG_KEY : 0;
    if (dst->dts == AV_NOPTS_VALUE)
        dst->dts = dst->pts;
    if (dst->dts != AV_NOPTS_VALUE) {
        if (s->last_dts != AV_NOPTS_VALUE && dst->dts <= s->last_dts)
            dst->dts = s->last_dts + 1;
        s->last_dts = dst->dts;
    }
    if (dst->pts == AV_NOPTS_VALUE)
        dst->pts = dst->dts;
    if (s->pkt_q_count < s->pkt_q_size)
        s->pkt_q_count++;
    else
        return AVERROR_BUFFER_TOO_SMALL;
    s->packets_recv++;
    return 0;
}

static int pop_packet(VTRemoteTranscodeContext *s, AVPacket *pkt) {
    if (s->pkt_q_count <= 0)
        return AVERROR(EAGAIN);
    AVPacket *src = &s->pkt_queue[s->pkt_q_head];
    int ret = av_packet_ref(pkt, src);
    av_packet_unref(src);
    s->pkt_q_head = (s->pkt_q_head + 1) % s->pkt_q_size;
    s->pkt_q_count--;
    return ret;
}

static int vtremote_send_packet(VTRemoteTranscodeContext *s, const AVPacket *pkt) {
    if (!s || !pkt)
        return AVERROR(EINVAL);
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
    return 0;
}

static int vtremote_drain_available_packets(AVBSFContext *ctx) {
    VTRemoteTranscodeContext *s = ctx->priv_data;
    int packets_read = 0;

    while (s->pkt_q_count < s->pkt_q_size) {
        VTRemoteMsgHeader hdr;
        uint8_t *payload = NULL;
        int ret = vtremote_read_msg_nonblock(s, &hdr, &payload);
        if (ret == AVERROR(EAGAIN))
            break;
        if (ret < 0)
            return ret;

        switch (hdr.type) {
        case VTREMOTE_MSG_PACKET:
            ret = enqueue_packet(ctx, payload, hdr.length);
            av_free(payload);
            if (ret < 0)
                return ret;
            packets_read++;
            break;
        case VTREMOTE_MSG_DONE:
            av_free(payload);
            s->done = 1;
            return packets_read;
        case VTREMOTE_MSG_PING: {
            VTRemoteWBuf empty = {0};
            vtremote_send_msg(s, VTREMOTE_MSG_PONG, &empty);
            av_free(payload);
            break;
        }
        case VTREMOTE_MSG_ERROR: {
            vtremote_log_error_payload(ctx, payload, hdr.length);
            av_free(payload);
            return AVERROR(EIO);
        }
        default:
            av_free(payload);
            break;
        }
    }

    return packets_read > 0 ? 0 : AVERROR(EAGAIN);
}

static int vtremote_receive_packet_blocking(AVBSFContext *ctx) {
    VTRemoteTranscodeContext *s = ctx->priv_data;
    for (;;) {
        VTRemoteMsgHeader hdr;
        uint8_t *payload = NULL;
        int ret = vtremote_read_msg(s, &hdr, &payload);
        if (ret < 0)
            return ret;

        switch (hdr.type) {
        case VTREMOTE_MSG_PACKET:
            ret = enqueue_packet(ctx, payload, hdr.length);
            av_free(payload);
            return ret;
        case VTREMOTE_MSG_DONE:
            av_free(payload);
            s->done = 1;
            return 0;
        case VTREMOTE_MSG_PING: {
            VTRemoteWBuf empty = {0};
            vtremote_send_msg(s, VTREMOTE_MSG_PONG, &empty);
            av_free(payload);
            break;
        }
        case VTREMOTE_MSG_ERROR: {
            vtremote_log_error_payload(ctx, payload, hdr.length);
            av_free(payload);
            return AVERROR(EIO);
        }
        default:
            av_free(payload);
            break;
        }
    }
}

static int vtremote_send_flush(VTRemoteTranscodeContext *s) {
    VTRemoteWBuf empty = {0};
    return vtremote_send_msg(s, VTREMOTE_MSG_FLUSH, &empty);
}

static int maybe_convert_to_annexb(VTRemoteTranscodeContext *s, AVPacket *pkt) {
    if (!s->annexb_bsf)
        return 0;
    int ret = av_bsf_send_packet(s->annexb_bsf, pkt);
    if (ret < 0)
        return ret;
    av_packet_unref(pkt);
    ret = av_bsf_receive_packet(s->annexb_bsf, pkt);
    if (ret < 0)
        return ret;
    return 0;
}

static int vtremote_transcode_init(AVBSFContext *ctx) {
    VTRemoteTranscodeContext *s = ctx->priv_data;
    int ret;

    s->fd = -1;
    s->connected = 0;
    s->flushing = 0;
    s->done = 0;
    s->packets_sent = 0;
    s->packets_recv = 0;
    s->last_dts = AV_NOPTS_VALUE;

    if (!s->host) {
        av_log(ctx, AV_LOG_ERROR, "vt_remote_host is required\n");
        return AVERROR(EINVAL);
    }

    if (ctx->par_in->codec_id != AV_CODEC_ID_H264 && ctx->par_in->codec_id != AV_CODEC_ID_HEVC) {
        av_log(ctx, AV_LOG_ERROR, "vtremote_transcode supports H.264/HEVC only\n");
        return AVERROR(EINVAL);
    }

    s->codec_id_in = ctx->par_in->codec_id;
    if (s->out_codec && *s->out_codec) {
        int out_id = codec_id_from_name(s->out_codec);
        if (!out_id) {
            av_log(ctx, AV_LOG_ERROR, "unsupported out_codec=%s\n", s->out_codec);
            return AVERROR(EINVAL);
        }
        s->codec_id_out = out_id;
    } else {
        s->codec_id_out = s->codec_id_in;
    }

    ret = avcodec_parameters_copy(ctx->par_out, ctx->par_in);
    if (ret < 0)
        return ret;
    ctx->par_out->codec_id = s->codec_id_out;
    ctx->par_out->codec_tag = 0;
    ctx->time_base_out = ctx->time_base_in;

    if (ctx->par_in->width <= 0 || ctx->par_in->height <= 0) {
        av_log(ctx, AV_LOG_ERROR, "input width/height required for vtremote_transcode\n");
        return AVERROR(EINVAL);
    }

    if ((s->out_width > 0) != (s->out_height > 0)) {
        av_log(ctx, AV_LOG_ERROR, "vt_remote_out_width and vt_remote_out_height must be set together\n");
        return AVERROR(EINVAL);
    }

    if (s->out_width > 0 && s->out_height > 0) {
        ctx->par_out->width = s->out_width;
        ctx->par_out->height = s->out_height;
    }

    if (s->pixel_format != 1 && s->pixel_format != 2) {
        av_log(ctx, AV_LOG_ERROR, "vt_remote_pix_fmt must be 1 (nv12) or 2 (p010)\n");
        return AVERROR(EINVAL);
    }

    s->pkt_q_size = FFMAX(4, s->inflight * 2);
    s->pkt_queue = av_calloc(s->pkt_q_size, sizeof(AVPacket));
    if (!s->pkt_queue)
        return AVERROR(ENOMEM);

    vtremote_wbuf_init(&s->pkt_buf);

    if (ctx->par_in->extradata_size > 0 && ctx->par_in->extradata && ctx->par_in->extradata[0] == 1) {
        const char *bsf_name = (s->codec_id_in == AV_CODEC_ID_H264) ? "h264_mp4toannexb" : "hevc_mp4toannexb";
        const AVBitStreamFilter *filter = av_bsf_get_by_name(bsf_name);
        if (filter) {
            AVBSFContext *annexb = NULL;
            ret = av_bsf_alloc(filter, &annexb);
            if (ret < 0)
                return ret;
            ret = avcodec_parameters_copy(annexb->par_in, ctx->par_in);
            if (ret < 0) {
                av_bsf_free(&annexb);
                return ret;
            }
            annexb->time_base_in = ctx->time_base_in;
            ret = av_bsf_init(annexb);
            if (ret < 0) {
                av_bsf_free(&annexb);
                return ret;
            }
            s->annexb_bsf = annexb;
        }
    }

    ret = vtremote_net_init();
    if (ret < 0)
        return ret;

    ret = vtremote_handshake(ctx);
    if (ret < 0) {
        vtremote_net_close();
        return ret;
    }

    return 0;
}

static int vtremote_transcode_filter(AVBSFContext *ctx, AVPacket *pkt) {
    VTRemoteTranscodeContext *s = ctx->priv_data;
    int ret;

    if (s->pkt_q_count > 0) {
        return pop_packet(s, pkt);
    }

    ret = vtremote_drain_available_packets(ctx);
    if (ret < 0 && ret != AVERROR(EAGAIN))
        return ret;
    if (s->pkt_q_count > 0)
        return pop_packet(s, pkt);
    if (s->done)
        return AVERROR_EOF;

    AVPacket in_pkt;
    av_init_packet(&in_pkt);
    ret = ff_bsf_get_packet_ref(ctx, &in_pkt);
    if (ret == AVERROR_EOF) {
        av_packet_unref(&in_pkt);
        if (!s->flushing) {
            ret = vtremote_send_flush(s);
            if (ret < 0)
                return ret;
            s->flushing = 1;
        }
        while (!s->done && s->pkt_q_count == 0) {
            ret = vtremote_receive_packet_blocking(ctx);
            if (ret < 0 && ret != AVERROR(EAGAIN))
                return ret;
        }
        if (s->pkt_q_count > 0)
            return pop_packet(s, pkt);
        return AVERROR_EOF;
    } else if (ret < 0) {
        av_packet_unref(&in_pkt);
        return ret;
    }

    ret = maybe_convert_to_annexb(s, &in_pkt);
    if (ret < 0) {
        av_packet_unref(&in_pkt);
        return ret;
    }

    if (s->inflight > 0 && (s->packets_sent - s->packets_recv) >= s->inflight) {
        ret = vtremote_receive_packet_blocking(ctx);
        if (ret < 0 && ret != AVERROR(EAGAIN)) {
            av_packet_unref(&in_pkt);
            return ret;
        }
    }

    ret = vtremote_send_packet(s, &in_pkt);
    av_packet_unref(&in_pkt);
    if (ret < 0)
        return ret;

    ret = vtremote_drain_available_packets(ctx);
    if (ret < 0 && ret != AVERROR(EAGAIN))
        return ret;
    if (s->pkt_q_count > 0)
        return pop_packet(s, pkt);

    return AVERROR(EAGAIN);
}

static void vtremote_transcode_flush(AVBSFContext *ctx) {
    VTRemoteTranscodeContext *s = ctx->priv_data;
    s->flushing = 0;
    s->done = 0;
    s->packets_sent = 0;
    s->packets_recv = 0;
    s->last_dts = AV_NOPTS_VALUE;
    if (s->pkt_queue) {
        for (int i = 0; i < s->pkt_q_size; i++)
            av_packet_unref(&s->pkt_queue[i]);
        s->pkt_q_head = 0;
        s->pkt_q_count = 0;
    }
    if (s->annexb_bsf)
        av_bsf_flush(s->annexb_bsf);
}

static void vtremote_transcode_close(AVBSFContext *ctx) {
    VTRemoteTranscodeContext *s = ctx->priv_data;
    if (s->fd >= 0)
        VTR_CLOSE_SOCKET(s->fd);
    vtremote_net_close();
    vtremote_wbuf_free(&s->pkt_buf);
    if (s->pkt_queue) {
        for (int i = 0; i < s->pkt_q_size; i++)
            av_packet_unref(&s->pkt_queue[i]);
        av_freep(&s->pkt_queue);
    }
    if (s->annexb_bsf)
        av_bsf_free(&s->annexb_bsf);
}

#define OFFSET(x) offsetof(VTRemoteTranscodeContext, x)
#define FLAGS (AV_OPT_FLAG_VIDEO_PARAM|AV_OPT_FLAG_BSF_PARAM)
static const AVOption vtremote_transcode_options[] = {
    { "vt_remote_host", "VideoToolbox remote server host:port", OFFSET(host), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, FLAGS },
    { "vt_remote_port", "VideoToolbox remote server port", OFFSET(port), AV_OPT_TYPE_INT, { .i64 = 5555 }, 1, 65535, FLAGS },
    { "vt_remote_token", "authentication token (optional)", OFFSET(token), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, FLAGS },
    { "vt_remote_timeout_ms", "socket timeout in ms", OFFSET(timeout_ms), AV_OPT_TYPE_INT, { .i64 = 5000 }, 100, 60000, FLAGS },
    { "vt_remote_inflight", "max in-flight packets", OFFSET(inflight), AV_OPT_TYPE_INT, { .i64 = 16 }, 1, 128, FLAGS },
    { "vt_remote_log_level", "remote log level", OFFSET(log_level), AV_OPT_TYPE_INT, { .i64 = AV_LOG_INFO }, AV_LOG_QUIET, AV_LOG_TRACE, FLAGS },
    { "vt_remote_out_codec", "output codec (h264|hevc)", OFFSET(out_codec), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, FLAGS },
    { "vt_remote_out_width", "output width", OFFSET(out_width), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, INT_MAX, FLAGS },
    { "vt_remote_out_height", "output height", OFFSET(out_height), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, INT_MAX, FLAGS },
    { "vt_remote_scale_mode", "scale mode (stretch|aspect|aspect_fill)", OFFSET(scale_mode), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, FLAGS },
    { "vt_remote_pix_fmt", "pixel format (1=nv12,2=p010)", OFFSET(pixel_format), AV_OPT_TYPE_INT, { .i64 = 1 }, 1, 2, FLAGS },
    { "vt_remote_decode_async", "allow async decode on server", OFFSET(decode_async), AV_OPT_TYPE_BOOL, { .i64 = 1 }, 0, 1, FLAGS },
    { "vt_remote_decode_reorder_depth", "decode reorder depth", OFFSET(decode_reorder_depth), AV_OPT_TYPE_INT, { .i64 = 2 }, -1, 64, FLAGS },
    { "vt_remote_bitrate", "target bitrate", OFFSET(bitrate), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, INT_MAX, FLAGS },
    { "vt_remote_maxrate", "max bitrate", OFFSET(maxrate), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, INT_MAX, FLAGS },
    { "vt_remote_gop", "gop size", OFFSET(gop), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, INT_MAX, FLAGS },
    { "vt_remote_max_b_frames", "max b-frames", OFFSET(max_b_frames), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, 16, FLAGS },
    { "vt_remote_profile", "profile", OFFSET(profile), AV_OPT_TYPE_INT, { .i64 = -99 }, -99, INT_MAX, FLAGS },
    { "vt_remote_level", "level", OFFSET(level), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, INT_MAX, FLAGS },
    { "vt_remote_entropy", "entropy", OFFSET(entropy), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, 2, FLAGS },
    { "vt_remote_allow_sw", "allow software encoding", OFFSET(allow_sw), AV_OPT_TYPE_BOOL, { .i64 = 0 }, 0, 1, FLAGS },
    { "vt_remote_require_sw", "require software encoding", OFFSET(require_sw), AV_OPT_TYPE_BOOL, { .i64 = 0 }, 0, 1, FLAGS },
    { "vt_remote_realtime", "realtime encode hint", OFFSET(realtime), AV_OPT_TYPE_INT, { .i64 = -1 }, -1, 1, FLAGS },
    { "vt_remote_prio_speed", "prioritize speed", OFFSET(prio_speed), AV_OPT_TYPE_INT, { .i64 = -1 }, -1, 1, FLAGS },
    { "vt_remote_power_efficient", "power efficient", OFFSET(power_efficient), AV_OPT_TYPE_INT, { .i64 = -1 }, -1, 1, FLAGS },
    { "vt_remote_spatial_aq", "spatial AQ", OFFSET(spatial_aq), AV_OPT_TYPE_INT, { .i64 = -1 }, -1, 1, FLAGS },
    { "vt_remote_max_ref_frames", "max reference frames", OFFSET(max_ref_frames), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, INT_MAX, FLAGS },
    { "vt_remote_max_slice_bytes", "max slice bytes", OFFSET(max_slice_bytes), AV_OPT_TYPE_INT, { .i64 = -1 }, -1, INT_MAX, FLAGS },
    { "vt_remote_constant_bit_rate", "constant bit rate", OFFSET(constant_bit_rate), AV_OPT_TYPE_BOOL, { .i64 = 0 }, 0, 1, FLAGS },
    { "vt_remote_alpha_quality", "alpha quality", OFFSET(alpha_quality), AV_OPT_TYPE_DOUBLE, { .dbl = 0.0 }, 0.0, 1.0, FLAGS },
    { "vt_remote_color_range", "color range", OFFSET(color_range), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, 4, FLAGS },
    { "vt_remote_colorspace", "colorspace", OFFSET(colorspace), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, 12, FLAGS },
    { "vt_remote_color_primaries", "color primaries", OFFSET(color_primaries), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, 12, FLAGS },
    { "vt_remote_color_trc", "color transfer", OFFSET(color_trc), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, 18, FLAGS },
    { "vt_remote_sar_num", "sample aspect ratio num", OFFSET(sar_num), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, INT_MAX, FLAGS },
    { "vt_remote_sar_den", "sample aspect ratio den", OFFSET(sar_den), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, INT_MAX, FLAGS },
    { "vt_remote_a53_cc", "a53 cc", OFFSET(a53_cc), AV_OPT_TYPE_INT, { .i64 = -1 }, -1, INT_MAX, FLAGS },
    { "vt_remote_flags", "codec flags", OFFSET(flags), AV_OPT_TYPE_INT64, { .i64 = 0 }, INT64_MIN, INT64_MAX, FLAGS },
    { NULL },
};

static const AVClass vtremote_transcode_class = {
    .class_name = "vtremote_transcode",
    .item_name = av_default_item_name,
    .option = vtremote_transcode_options,
    .version = LIBAVUTIL_VERSION_INT,
};

const FFBitStreamFilter ff_vtremote_transcode_bsf = {
    .p.name         = "vtremote_transcode",
    .p.priv_class   = &vtremote_transcode_class,
    .priv_data_size = sizeof(VTRemoteTranscodeContext),
    .init           = vtremote_transcode_init,
    .filter         = vtremote_transcode_filter,
    .flush          = vtremote_transcode_flush,
    .close          = vtremote_transcode_close,
};
