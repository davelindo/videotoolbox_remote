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
#if defined(HAVE_SYS_UIO_H) && HAVE_SYS_UIO_H
#include <sys/uio.h>
#endif
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
#include "libavutil/pixdesc.h"
#include "libavutil/rational.h"
#include "libavutil/time.h"
#include "../vtremote_proto.h"

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

#include "../vtremote_sock.h"

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
    int bufsize;
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
    int64_t codec_tag;
    int color_range;
    int colorspace;
    int color_primaries;
    int color_trc;
    int sar_num;
    int sar_den;
    int a53_cc;
    int64_t flags;
    int global_quality;
    uint64_t server_caps;
    int warned_packet_side_data_no_cap;
    int fd;
    int connected;
    int flushing;
    int done;
    int codec_id_in;
    int codec_id_out;
    int64_t packets_sent;
    int64_t packets_acked;
    int64_t packets_recv;
    int64_t last_dts;
    VTRemoteWBuf pkt_buf;
    uint8_t rx_header_buf[VTREMOTE_HEADER_SIZE];
    VTRemoteMsgHeader rx_header;
    int rx_header_read;
    int rx_payload_read;
    int rx_have_header;
    uint8_t *rx_buf;
    uint32_t rx_buf_size;
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
    vtremote_disable_sigpipe(fd);

    int bufsize = 16 * 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, VTR_SOCKOPT_ARG &bufsize, sizeof(bufsize));
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, VTR_SOCKOPT_ARG &bufsize, sizeof(bufsize));
}

static int write_full(int fd, const uint8_t *buf, int size) {
    int sent = 0;
    while (sent < size) {
        int r = (int)send(fd, buf + sent, size - sent, vtremote_send_flags(0));
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

static int write_full_iov(int fd, const uint8_t *buf0, int size0,
                          const uint8_t *buf1, int size1)
{
#if defined(HAVE_WINSOCK2_H) && HAVE_WINSOCK2_H
    int ret = write_full(fd, buf0, size0);
    if (ret < 0 || size1 <= 0)
        return ret;
    return write_full(fd, buf1, size1);
#elif defined(HAVE_SYS_UIO_H) && HAVE_SYS_UIO_H
    if (size1 <= 0)
        return write_full(fd, buf0, size0);

    struct iovec iov[2];
    int iovcnt = 0;

    if (size0 > 0) {
        iov[iovcnt].iov_base = (void *)buf0;
        iov[iovcnt].iov_len = size0;
        iovcnt++;
    }
    if (size1 > 0) {
        iov[iovcnt].iov_base = (void *)buf1;
        iov[iovcnt].iov_len = size1;
        iovcnt++;
    }

    while (iovcnt > 0) {
        struct msghdr msg = {0};
        msg.msg_iov = iov;
        msg.msg_iovlen = iovcnt;

        ssize_t r = sendmsg(fd, &msg, 0);
        if (r < 0) {
            int err = vtremote_sock_errno();
            if (err == EINTR)
                continue;
            return AVERROR(err);
        }
        if (r == 0)
            return AVERROR_EOF;

        ssize_t consumed = r;
        while (iovcnt > 0 && consumed >= (ssize_t)iov[0].iov_len) {
            consumed -= (ssize_t)iov[0].iov_len;
            if (iovcnt > 1)
                iov[0] = iov[1];
            iovcnt--;
        }
        if (iovcnt > 0 && consumed > 0) {
            iov[0].iov_base = (uint8_t *)iov[0].iov_base + consumed;
            iov[0].iov_len -= consumed;
        }
    }
    return 0;
#else
    int ret = write_full(fd, buf0, size0);
    if (ret < 0 || size1 <= 0)
        return ret;
    return write_full(fd, buf1, size1);
#endif
}

static void vtremote_reset_rx_state(VTRemoteTranscodeContext *s)
{
    if (!s)
        return;
    s->rx_header_read = 0;
    s->rx_payload_read = 0;
    s->rx_have_header = 0;
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

static int connect_hostport(AVBSFContext *ctx, const char *hostport,
                            int timeout_ms) {
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
    int last_err = EIO;
    for (rp = res; rp; rp = rp->ai_next) {
        int sock_err;
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0) {
            sock_err = vtremote_sock_errno();
            last_err = sock_err ? sock_err : EIO;
            continue;
        }
        configure_socket_buffers(fd);
        set_socket_timeout(fd, timeout_ms);
        int ret = vtremote_connect_or_finish(fd, rp->ai_addr, rp->ai_addrlen, timeout_ms);
        if (ret == 0)
            break;
        last_err = AVUNERROR(ret);
        av_log(ctx, AV_LOG_VERBOSE, "vtremote transcode connect attempt failed: %s\n",
               av_err2str(ret));
        VTR_CLOSE_SOCKET(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0)
        return AVERROR(last_err);

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

static int vtremote_add_opt_value(VTRemoteKV **opts, int *count, int *cap,
                                  const char *key, char *value)
{
    int ret = vtremote_add_opt(opts, count, cap, key, value);
    if (ret < 0)
        av_freep(&value);
    return ret;
}

static int vtremote_add_opt_string(VTRemoteKV **opts, int *count, int *cap,
                                   const char *key, const char *value)
{
    char *tmp;
    if (!value)
        return AVERROR(EINVAL);
    tmp = av_strdup(value);
    if (!tmp)
        return AVERROR(ENOMEM);
    return vtremote_add_opt_value(opts, count, cap, key, tmp);
}

static int vtremote_add_opt_int(VTRemoteKV **opts, int *count, int *cap,
                                const char *key, int value)
{
    char *tmp = av_asprintf("%d", value);
    if (!tmp)
        return AVERROR(ENOMEM);
    return vtremote_add_opt_value(opts, count, cap, key, tmp);
}

static int vtremote_add_opt_int64(VTRemoteKV **opts, int *count, int *cap,
                                  const char *key, int64_t value)
{
    char *tmp = av_asprintf("%" PRId64, value);
    if (!tmp)
        return AVERROR(ENOMEM);
    return vtremote_add_opt_value(opts, count, cap, key, tmp);
}

static int vtremote_add_opt_double(VTRemoteKV **opts, int *count, int *cap,
                                   const char *key, double value)
{
    char *tmp = av_asprintf("%.6f", value);
    if (!tmp)
        return AVERROR(ENOMEM);
    return vtremote_add_opt_value(opts, count, cap, key, tmp);
}

typedef struct VTRemoteIntOptSpec {
    const char *key;
    int value;
    int min_value;
} VTRemoteIntOptSpec;

static int vtremote_add_int_opt_specs(VTRemoteKV **opts, int *count, int *cap,
                                      const VTRemoteIntOptSpec *specs, size_t nb_specs)
{
    int ret;
    for (size_t i = 0; i < nb_specs; i++) {
        if (specs[i].value < specs[i].min_value)
            continue;
        ret = vtremote_add_opt_int(opts, count, cap, specs[i].key, specs[i].value);
        if (ret < 0)
            return ret;
    }
    return 0;
}

static int vtremote_add_opt_nonempty_string(VTRemoteKV **opts, int *count, int *cap,
                                            const char *key, const char *value)
{
    if (!value || !*value)
        return 0;
    return vtremote_add_opt_string(opts, count, cap, key, value);
}

static int vtremote_add_opt_if_enabled(VTRemoteKV **opts, int *count, int *cap,
                                       const char *key, int enabled)
{
    if (!enabled)
        return 0;
    return vtremote_add_opt_string(opts, count, cap, key, "1");
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

static int vtremote_validate_color_range(int value)
{
    return av_color_range_name((enum AVColorRange)value) != NULL;
}

static int vtremote_validate_colorspace(int value)
{
    return av_color_space_name((enum AVColorSpace)value) != NULL;
}

static int vtremote_validate_color_primaries(int value)
{
    return av_color_primaries_name((enum AVColorPrimaries)value) != NULL;
}

static int vtremote_validate_color_trc(int value)
{
    return av_color_transfer_name((enum AVColorTransferCharacteristic)value) != NULL;
}

static int vtremote_validate_explicit_color_props(AVBSFContext *ctx)
{
    VTRemoteTranscodeContext *s = ctx->priv_data;
    const struct {
        const char *label;
        int value;
        int (*validator)(int);
    } color_opts[] = {
        { "color_range", s->color_range, vtremote_validate_color_range },
        { "colorspace", s->colorspace, vtremote_validate_colorspace },
        { "color_primaries", s->color_primaries, vtremote_validate_color_primaries },
        { "color_trc", s->color_trc, vtremote_validate_color_trc },
    };

    for (size_t i = 0; i < FF_ARRAY_ELEMS(color_opts); i++) {
        if (color_opts[i].value < 0)
            continue;
        if (!color_opts[i].validator(color_opts[i].value)) {
            av_log(ctx, AV_LOG_ERROR,
                   "Invalid %s %d for vtremote_transcode\n",
                   color_opts[i].label, color_opts[i].value);
            return AVERROR(EINVAL);
        }
    }

    return 0;
}

static int vtremote_seed_color_props(AVBSFContext *ctx)
{
    VTRemoteTranscodeContext *s = ctx->priv_data;
    int ret;

    if (s->color_range < 0 &&
        ctx->par_in->color_range != AVCOL_RANGE_UNSPECIFIED)
        s->color_range = ctx->par_in->color_range;
    if (s->colorspace < 0 &&
        ctx->par_in->color_space != AVCOL_SPC_UNSPECIFIED)
        s->colorspace = ctx->par_in->color_space;
    if (s->color_primaries < 0 &&
        ctx->par_in->color_primaries != AVCOL_PRI_UNSPECIFIED)
        s->color_primaries = ctx->par_in->color_primaries;
    if (s->color_trc < 0 &&
        ctx->par_in->color_trc != AVCOL_TRC_UNSPECIFIED)
        s->color_trc = ctx->par_in->color_trc;

    ret = vtremote_validate_explicit_color_props(ctx);
    if (ret < 0)
        return ret;

    if (s->color_range >= 0)
        ctx->par_out->color_range = s->color_range;
    if (s->colorspace >= 0)
        ctx->par_out->color_space = s->colorspace;
    if (s->color_primaries >= 0)
        ctx->par_out->color_primaries = s->color_primaries;
    if (s->color_trc >= 0)
        ctx->par_out->color_trc = s->color_trc;

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
    return write_full_iov(s->fd, header_buf, VTREMOTE_HEADER_SIZE,
                          payload_data, payload_size);
}

static int vtremote_ensure_rx_capacity(VTRemoteTranscodeContext *s, uint32_t size)
{
    if (size <= s->rx_buf_size)
        return 0;
    uint8_t *buf = av_realloc(s->rx_buf, size);
    if (!buf)
        return AVERROR(ENOMEM);
    s->rx_buf = buf;
    s->rx_buf_size = size;
    return 0;
}

static int vtremote_recv_some(VTRemoteTranscodeContext *s, uint8_t *dst, int size,
                              int nonblock, int had_partial_read)
{
    if (size <= 0)
        return 0;

    if (!s || !dst)
        return AVERROR(EINVAL);

    while (1) {
        if (nonblock) {
            int ready = check_readable(s->fd, 0);
            if (ready == 0)
                return AVERROR(EAGAIN);
            if (ready < 0)
                return AVERROR(vtremote_sock_errno());
        }

        int r = (int)recv(s->fd, dst, size, 0);
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
            ) {
                if (nonblock)
                    return AVERROR(EAGAIN);
                return had_partial_read ? AVERROR(EIO) : AVERROR(EAGAIN);
            }
            return AVERROR(err);
        }
        if (r == 0)
            return AVERROR_EOF;
        return r;
    }
}

static int vtremote_read_msg_internal(VTRemoteTranscodeContext *s, VTRemoteMsgHeader *hdr,
                                      const uint8_t **payload, int nonblock)
{
    int ret;
    if (!s || !hdr || !payload)
        return AVERROR(EINVAL);

    if (!s->rx_have_header) {
        while (s->rx_header_read < VTREMOTE_HEADER_SIZE) {
            ret = vtremote_recv_some(s,
                                     s->rx_header_buf + s->rx_header_read,
                                     VTREMOTE_HEADER_SIZE - s->rx_header_read,
                                     nonblock,
                                     s->rx_header_read > 0);
            if (ret < 0)
                return ret;
            s->rx_header_read += ret;
        }

        ret = vtremote_read_header(s->rx_header_buf, VTREMOTE_HEADER_SIZE, &s->rx_header);
        if (ret < 0) {
            vtremote_reset_rx_state(s);
            return ret;
        }
        ret = vtremote_validate_payload_length(s->rx_header.type,
                                               s->rx_header.length);
        if (ret < 0) {
            vtremote_reset_rx_state(s);
            return ret;
        }
        s->rx_have_header = 1;
        s->rx_payload_read = 0;
    }

    if (s->rx_header.length == 0) {
        *hdr = s->rx_header;
        *payload = NULL;
        vtremote_reset_rx_state(s);
        return 0;
    }

    ret = vtremote_ensure_rx_capacity(s, s->rx_header.length);
    if (ret < 0)
        return ret;

    const int payload_len = (int)s->rx_header.length;
    while (s->rx_payload_read < payload_len) {
        ret = vtremote_recv_some(s,
                                 s->rx_buf + s->rx_payload_read,
                                 payload_len - s->rx_payload_read,
                                 nonblock,
                                 s->rx_payload_read > 0);
        if (ret < 0)
            return ret;
        s->rx_payload_read += ret;
    }

    *hdr = s->rx_header;
    *payload = s->rx_buf;
    vtremote_reset_rx_state(s);
    return 0;
}

static int vtremote_read_msg(VTRemoteTranscodeContext *s, VTRemoteMsgHeader *hdr, const uint8_t **payload) {
    return vtremote_read_msg_internal(s, hdr, payload, 0);
}

static int vtremote_read_msg_nonblock(VTRemoteTranscodeContext *s, VTRemoteMsgHeader *hdr, const uint8_t **payload) {
    return vtremote_read_msg_internal(s, hdr, payload, 1);
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
    VTRemoteTranscodeContext *s = ctx->priv_data;
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
    if (s->log_level >= AV_LOG_VERBOSE) {
        av_log(ctx, AV_LOG_VERBOSE,
               "vtremote server [%.*s %.*s] caps=0x%" PRIx64 " active=%u max=%u\n",
               server_name_len, server_name ? (const char *)server_name : "",
               server_ver_len, server_ver ? (const char *)server_ver : "",
               caps, active, max_sessions);
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

static int vtremote_require_server_cap(AVBSFContext *ctx, uint64_t required_cap,
                                       const char *what)
{
    VTRemoteTranscodeContext *s = ctx->priv_data;

    if (!required_cap || (s->server_caps & required_cap))
        return 0;

    av_log(ctx, AV_LOG_ERROR,
           "vtremote server does not advertise required capability for %s.\n",
           what);
    return AVERROR(ENOSYS);
}

static int vtremote_build_hostport(const VTRemoteTranscodeContext *s,
                                   char *hostport, size_t hostport_size)
{
    if (!s || !s->host || !*s->host || !hostport || !hostport_size)
        return AVERROR(EINVAL);

    if (strrchr(s->host, ':')) {
        if (av_strlcpy(hostport, s->host, hostport_size) >= hostport_size)
            return AVERROR(EINVAL);
        return 0;
    }

    if (s->port <= 0 || s->port > 65535)
        return AVERROR(EINVAL);
    {
        int n = snprintf(hostport, hostport_size, "%s:%d", s->host, s->port);
        if (n < 0 || (size_t)n >= hostport_size)
            return AVERROR(EINVAL);
    }

    return 0;
}

static int vtremote_read_expected_ack(AVBSFContext *ctx, uint8_t expected_type,
                                      int (*handler)(AVBSFContext *, const uint8_t *, int))
{
    VTRemoteTranscodeContext *s = ctx->priv_data;
    VTRemoteMsgHeader hdr;
    const uint8_t *payload = NULL;
    int ret = vtremote_read_msg(s, &hdr, &payload);
    if (ret < 0)
        return ret;

    if (hdr.type == VTREMOTE_MSG_ERROR) {
        vtremote_log_error_payload(ctx, payload, hdr.length);
        return AVERROR(EIO);
    }
    if (hdr.type != expected_type) {
        return AVERROR_INVALIDDATA;
    }

    ret = handler(ctx, payload, hdr.length);
    return ret;
}

static int vtremote_send_hello(AVBSFContext *ctx)
{
    VTRemoteTranscodeContext *s = ctx->priv_data;
    VTRemoteWBuf payload;
    int ret;

    vtremote_wbuf_init(&payload);
    vtremote_payload_hello(&payload, s->token, codec_name_for_id(s->codec_id_in),
                           "ffmpeg-vtremote", FFMPEG_VERSION);
    ret = vtremote_send_msg(s, VTREMOTE_MSG_HELLO, &payload);
    vtremote_wbuf_free(&payload);
    if (ret < 0)
        return ret;

    return vtremote_read_expected_ack(ctx, VTREMOTE_MSG_HELLO_ACK, vtremote_handle_hello_ack);
}

static int vtremote_append_transcode_opts(AVBSFContext *ctx, VTRemoteKV **opts,
                                          int *opt_count, int *opt_cap)
{
    VTRemoteTranscodeContext *s = ctx->priv_data;
    const VTRemoteIntOptSpec pre_codec_int_opts[] = {
        { "decode_async", s->decode_async, 0 },
        { "decode_reorder_depth", s->decode_reorder_depth, -1 },
    };
    const VTRemoteIntOptSpec scale_int_opts[] = {
        { "out_width", s->out_width, 1 },
        { "out_height", s->out_height, 1 },
    };
    const VTRemoteIntOptSpec encode_int_opts[] = {
        { "bitrate", s->bitrate, 1 },
        { "maxrate", s->maxrate, 1 },
        { "bufsize", s->bufsize, 1 },
        { "gop", s->gop, 1 },
        { "max_b_frames", s->max_b_frames, 0 },
        { "profile", s->profile, 0 },
        { "level", s->level, 1 },
        { "entropy", s->entropy, 0 },
        { "global_quality", s->global_quality, 1 },
    };
    const VTRemoteIntOptSpec post_bool_int_opts[] = {
        { "realtime", s->realtime, 0 },
        { "prio_speed", s->prio_speed, 0 },
        { "power_efficient", s->power_efficient, 0 },
        { "spatial_aq", s->spatial_aq, 0 },
        { "max_ref_frames", s->max_ref_frames, 1 },
        { "max_slice_bytes", s->max_slice_bytes, 0 },
    };
    const VTRemoteIntOptSpec color_int_opts[] = {
        { "color_range", s->color_range, 0 },
        { "colorspace", s->colorspace, 0 },
        { "color_primaries", s->color_primaries, 0 },
        { "color_trc", s->color_trc, 0 },
    };
    const VTRemoteIntOptSpec tail_int_opts[] = {
        { "a53_cc", s->a53_cc, 0 },
    };
    int ret;

    ret = vtremote_add_opt_string(opts, opt_count, opt_cap, "mode", "transcode");
    if (ret < 0)
        return ret;

    if (s->server_caps & VTREMOTE_CAP_PACKET_ACK_V1) {
        ret = vtremote_add_opt_string(opts, opt_count, opt_cap, "packet_ack.v1", "1");
        if (ret < 0)
            return ret;
    }

    ret = vtremote_add_int_opt_specs(opts, opt_count, opt_cap, pre_codec_int_opts,
                                     FF_ARRAY_ELEMS(pre_codec_int_opts));
    if (ret < 0)
        return ret;

    ret = vtremote_add_opt_nonempty_string(opts, opt_count, opt_cap, "out_codec", s->out_codec);
    if (ret < 0)
        return ret;

    ret = vtremote_add_int_opt_specs(opts, opt_count, opt_cap, scale_int_opts,
                                     FF_ARRAY_ELEMS(scale_int_opts));
    if (ret < 0)
        return ret;

    ret = vtremote_add_opt_nonempty_string(opts, opt_count, opt_cap, "scale_mode", s->scale_mode);
    if (ret < 0)
        return ret;

    ret = vtremote_add_int_opt_specs(opts, opt_count, opt_cap, encode_int_opts,
                                     FF_ARRAY_ELEMS(encode_int_opts));
    if (ret < 0)
        return ret;

    ret = vtremote_add_opt_if_enabled(opts, opt_count, opt_cap, "allow_sw", s->allow_sw);
    if (ret < 0)
        return ret;
    ret = vtremote_add_opt_if_enabled(opts, opt_count, opt_cap, "require_sw", s->require_sw);
    if (ret < 0)
        return ret;

    ret = vtremote_add_int_opt_specs(opts, opt_count, opt_cap, post_bool_int_opts,
                                     FF_ARRAY_ELEMS(post_bool_int_opts));
    if (ret < 0)
        return ret;

    ret = vtremote_add_opt_if_enabled(opts, opt_count, opt_cap, "constant_bit_rate",
                                      s->constant_bit_rate);
    if (ret < 0)
        return ret;

    if (s->alpha_quality > 0.0) {
        ret = vtremote_add_opt_double(opts, opt_count, opt_cap, "alpha_quality",
                                      s->alpha_quality);
        if (ret < 0)
            return ret;
    }

    ret = vtremote_add_int_opt_specs(opts, opt_count, opt_cap, color_int_opts,
                                     FF_ARRAY_ELEMS(color_int_opts));
    if (ret < 0)
        return ret;

    if (s->sar_num > 0 && s->sar_den > 0) {
        ret = vtremote_add_opt_int(opts, opt_count, opt_cap, "sar_num", s->sar_num);
        if (ret < 0)
            return ret;
        ret = vtremote_add_opt_int(opts, opt_count, opt_cap, "sar_den", s->sar_den);
        if (ret < 0)
            return ret;
    }

    ret = vtremote_add_int_opt_specs(opts, opt_count, opt_cap, tail_int_opts,
                                     FF_ARRAY_ELEMS(tail_int_opts));
    if (ret < 0)
        return ret;

    if (s->flags != 0) {
        ret = vtremote_add_opt_int64(opts, opt_count, opt_cap, "flags", s->flags);
        if (ret < 0)
            return ret;
    }

    return 0;
}

static int vtremote_send_configure(AVBSFContext *ctx, VTRemoteKV *opts, int opt_count)
{
    VTRemoteTranscodeContext *s = ctx->priv_data;
    VTRemoteWBuf cfg;
    const uint8_t *extradata = ctx->par_in->extradata;
    uint32_t extradata_len = ctx->par_in->extradata_size > 0 ?
                             (uint32_t)ctx->par_in->extradata_size : 0;
    AVRational tb = ctx->time_base_in.num && ctx->time_base_in.den ?
                    ctx->time_base_in : (AVRational){1, 90000};
    int ret;

    ret = vtremote_require_server_cap(
        ctx,
        vtremote_cap_flag_for_pix_fmt((uint8_t)s->pixel_format),
        vtremote_pix_fmt_name((uint8_t)s->pixel_format));
    if (ret < 0)
        return ret;

    vtremote_wbuf_init(&cfg);
    ret = vtremote_payload_configure(&cfg,
                                     ctx->par_in->width,
                                     ctx->par_in->height,
                                     (uint8_t)s->pixel_format,
                                     tb.num, tb.den,
                                     0, 1,
                                     opts, opt_count,
                                     extradata, extradata_len);
    if (ret < 0) {
        vtremote_wbuf_free(&cfg);
        return ret;
    }

    ret = vtremote_send_msg(s, VTREMOTE_MSG_CONFIGURE, &cfg);
    vtremote_wbuf_free(&cfg);
    if (ret < 0)
        return ret;

    return vtremote_read_expected_ack(ctx, VTREMOTE_MSG_CONFIGURE_ACK,
                                      vtremote_handle_configure_ack);
}

static int vtremote_handshake(AVBSFContext *ctx) {
    VTRemoteTranscodeContext *s = ctx->priv_data;
    char hostport[320];
    VTRemoteKV *opts = NULL;
    int opt_count = 0;
    int opt_cap = 0;
    int ret;

    ret = vtremote_build_hostport(s, hostport, sizeof(hostport));
    if (ret < 0)
        return ret;

    s->fd = connect_hostport(ctx, hostport, s->timeout_ms);
    if (s->fd < 0) {
        av_log(ctx, AV_LOG_ERROR, "Failed to connect to %s\n", hostport);
        return s->fd;
    }
    vtremote_reset_rx_state(s);

    ret = vtremote_send_hello(ctx);
    if (ret < 0)
        goto fail;

    ret = vtremote_append_transcode_opts(ctx, &opts, &opt_count, &opt_cap);
    if (ret < 0)
        goto fail;

    ret = vtremote_send_configure(ctx, opts, opt_count);
    if (ret < 0)
        goto fail;

    vtremote_free_opts(&opts, opt_count);
    s->connected = 1;
    return 0;

fail:
    vtremote_free_opts(&opts, opt_count);
    vtremote_reset_rx_state(s);
    if (s->fd >= 0) {
        VTR_CLOSE_SOCKET(s->fd);
        s->fd = -1;
    }
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
    int idx = s->pkt_q_head + s->pkt_q_count;
    if (idx >= s->pkt_q_size)
        idx -= s->pkt_q_size;
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
    for (int i = 0; i < view.side_data_count; i++) {
        uint8_t *sd = av_packet_new_side_data(
            dst, (enum AVPacketSideDataType)view.side_data[i].type,
            view.side_data[i].size);
        if (!sd) {
            av_log(ctx, AV_LOG_WARNING,
                   "Could not attach packet side data type=%u size=%u\n",
                   view.side_data[i].type, view.side_data[i].size);
            continue;
        }
        memcpy(sd, view.side_data[i].data, view.side_data[i].size);
    }
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
    av_packet_unref(pkt);
    av_packet_move_ref(pkt, src);
    s->pkt_q_head++;
    if (s->pkt_q_head >= s->pkt_q_size)
        s->pkt_q_head = 0;
    s->pkt_q_count--;
    return 0;
}

static int packet_side_data_from_avpacket(AVBSFContext *ctx,
                                          const AVPacket *pkt,
                                          VTRemoteSideData *side_data,
                                          int max_side_data)
{
    int count = 0;
    int valid_count = 0;

    if (!pkt || !side_data || max_side_data <= 0)
        return 0;
    for (int i = 0; i < pkt->side_data_elems; i++) {
        if (!pkt->side_data[i].data || pkt->side_data[i].size <= 0)
            continue;
        valid_count++;
        if (count >= max_side_data)
            continue;
        side_data[count].type = (uint32_t)pkt->side_data[i].type;
        side_data[count].size = (uint32_t)pkt->side_data[i].size;
        side_data[count].data = pkt->side_data[i].data;
        count++;
    }
    if (valid_count > count)
        av_log(ctx, AV_LOG_DEBUG,
               "Truncating packet side data records from %d to %d\n",
               valid_count, count);
    return count;
}

static int vtremote_send_packet(AVBSFContext *ctx, VTRemoteTranscodeContext *s, const AVPacket *pkt) {
    if (!s || !pkt)
        return AVERROR(EINVAL);
    VTRemoteWBuf *payload = &s->pkt_buf;
    vtremote_wbuf_reset(payload);
    /* Preserve timestamp semantics, including AV_NOPTS_VALUE. */
    int64_t pts = pkt->pts;
    int64_t dts = pkt->dts;
    int64_t dur = pkt->duration > 0 ? pkt->duration : 0;
    VTRemoteSideData side_data[16];
    int side_data_count = 0;
    if (pkt->side_data_elems > 0) {
        if (s->server_caps & VTREMOTE_CAP_SIDE_DATA_V2) {
            side_data_count = packet_side_data_from_avpacket(
                ctx, pkt, side_data, FF_ARRAY_ELEMS(side_data));
        } else if (!s->warned_packet_side_data_no_cap) {
            av_log(ctx, AV_LOG_WARNING,
                   "Remote server does not advertise side_data.v2; dropping packet side data\n");
            s->warned_packet_side_data_no_cap = 1;
        }
    }
    int ret = vtremote_payload_packet_ex(payload,
                                         pts, dts, dur,
                                         (pkt->flags & AV_PKT_FLAG_KEY) ? 1 : 0,
                                         pkt->data, pkt->size,
                                         side_data,
                                         (uint8_t)side_data_count);
    if (ret < 0)
        return ret;
    ret = vtremote_send_msg(s, VTREMOTE_MSG_PACKET, payload);
    if (ret < 0)
        return ret;
    s->packets_sent++;
    return 0;
}

static int64_t vtremote_transcode_inflight_count(const VTRemoteTranscodeContext *s)
{
    int64_t in_flight;

    if (!s)
        return 0;
    if (s->server_caps & VTREMOTE_CAP_PACKET_ACK_V1)
        in_flight = s->packets_sent - s->packets_acked;
    else
        in_flight = s->packets_sent - s->packets_recv;
    return FFMAX(INT64_C(0), in_flight);
}

static void vtremote_note_packet_ack(VTRemoteTranscodeContext *s)
{
    if (s && s->packets_acked < s->packets_sent)
        s->packets_acked++;
}

static int vtremote_handle_packet_ack(VTRemoteTranscodeContext *s,
                                      const VTRemoteMsgHeader *hdr)
{
    if (!hdr || hdr->length != 0)
        return AVERROR_INVALIDDATA;
    vtremote_note_packet_ack(s);
    return 0;
}

static int vtremote_drain_available_packets(AVBSFContext *ctx) {
    VTRemoteTranscodeContext *s = ctx->priv_data;
    int packets_read = 0;

    while (s->pkt_q_count < s->pkt_q_size) {
        VTRemoteMsgHeader hdr;
        const uint8_t *payload = NULL;
        int ret = vtremote_read_msg_nonblock(s, &hdr, &payload);
        if (ret == AVERROR(EAGAIN))
            break;
        if (ret < 0)
            return ret;

        switch (hdr.type) {
        case VTREMOTE_MSG_PACKET:
            ret = enqueue_packet(ctx, payload, hdr.length);
            if (ret < 0)
                return ret;
            packets_read++;
            break;
        case VTREMOTE_MSG_PACKET_ACK:
            ret = vtremote_handle_packet_ack(s, &hdr);
            if (ret < 0)
                return ret;
            break;
        case VTREMOTE_MSG_DONE:
            s->done = 1;
            return packets_read;
        case VTREMOTE_MSG_PING: {
            VTRemoteWBuf empty = {0};
            vtremote_send_msg(s, VTREMOTE_MSG_PONG, &empty);
            break;
        }
        case VTREMOTE_MSG_ERROR: {
            vtremote_log_error_payload(ctx, payload, hdr.length);
            return AVERROR(EIO);
        }
        default:
            break;
        }
    }

    return packets_read > 0 ? 0 : AVERROR(EAGAIN);
}

static int vtremote_receive_packet_blocking(AVBSFContext *ctx) {
    VTRemoteTranscodeContext *s = ctx->priv_data;
    for (;;) {
        VTRemoteMsgHeader hdr;
        const uint8_t *payload = NULL;
        int ret = vtremote_read_msg(s, &hdr, &payload);
        if (ret < 0)
            return ret;

        switch (hdr.type) {
        case VTREMOTE_MSG_PACKET:
            ret = enqueue_packet(ctx, payload, hdr.length);
            return ret;
        case VTREMOTE_MSG_PACKET_ACK:
            return vtremote_handle_packet_ack(s, &hdr);
        case VTREMOTE_MSG_DONE:
            s->done = 1;
            return 0;
        case VTREMOTE_MSG_PING: {
            VTRemoteWBuf empty = {0};
            vtremote_send_msg(s, VTREMOTE_MSG_PONG, &empty);
            break;
        }
        case VTREMOTE_MSG_ERROR: {
            vtremote_log_error_payload(ctx, payload, hdr.length);
            return AVERROR(EIO);
        }
        default:
            break;
        }
    }
}

static int vtremote_wait_for_inflight_slot(AVBSFContext *ctx)
{
    VTRemoteTranscodeContext *s = ctx->priv_data;

    if (s->inflight <= 0 || vtremote_transcode_inflight_count(s) < s->inflight)
        return 0;

    if (!(s->server_caps & VTREMOTE_CAP_PACKET_ACK_V1)) {
        int ret = vtremote_receive_packet_blocking(ctx);
        if (ret < 0 && ret != AVERROR(EAGAIN))
            return ret;
        return 0;
    }

    while (vtremote_transcode_inflight_count(s) >= s->inflight) {
        int ret = vtremote_receive_packet_blocking(ctx);
        if (ret == AVERROR(EAGAIN)) {
            av_log(ctx, AV_LOG_ERROR,
                   "Timed out waiting for vtremote_transcode input credit "
                   "(sent=%" PRId64 " acked=%" PRId64 " recv=%" PRId64 ")\n",
                   s->packets_sent, s->packets_acked, s->packets_recv);
            return AVERROR(ETIMEDOUT);
        }
        if (ret < 0)
            return ret;
        if (s->done)
            return AVERROR_EOF;
    }

    return 0;
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
    s->packets_acked = 0;
    s->packets_recv = 0;
    s->last_dts = AV_NOPTS_VALUE;
    s->rx_buf_size = 0;
    vtremote_reset_rx_state(s);

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
    ctx->par_out->codec_tag = s->codec_tag >= 0 ? (uint32_t)s->codec_tag : 0;
    ctx->time_base_out = ctx->time_base_in;
    ret = vtremote_seed_color_props(ctx);
    if (ret < 0)
        return ret;

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

    if (s->pixel_format != VTREMOTE_PIX_FMT_NV12 &&
        s->pixel_format != VTREMOTE_PIX_FMT_P010 &&
        s->pixel_format != VTREMOTE_PIX_FMT_BGRA &&
        s->pixel_format != VTREMOTE_PIX_FMT_AYUV &&
        s->pixel_format != VTREMOTE_PIX_FMT_P210) {
        av_log(ctx, AV_LOG_ERROR,
               "vt_remote_pix_fmt must be 1 (nv12), 2 (p010), 3 (bgra), "
               "4 (ayuv), or 5 (p210)\n");
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

    ret = vtremote_wait_for_inflight_slot(ctx);
    if (ret < 0)
        return ret;
    if (s->pkt_q_count > 0)
        return pop_packet(s, pkt);
    if (s->done)
        return AVERROR_EOF;

    AVPacket in_pkt = { 0 };
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

    ret = vtremote_send_packet(ctx, s, &in_pkt);
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
    s->packets_acked = 0;
    s->packets_recv = 0;
    s->last_dts = AV_NOPTS_VALUE;
    vtremote_reset_rx_state(s);
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
    vtremote_reset_rx_state(s);
    av_freep(&s->rx_buf);
    s->rx_buf_size = 0;
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
    { "vt_remote_pix_fmt", "pixel format (1=nv12,2=p010,3=bgra,4=ayuv,5=p210)", OFFSET(pixel_format), AV_OPT_TYPE_INT, { .i64 = VTREMOTE_PIX_FMT_NV12 }, VTREMOTE_PIX_FMT_NV12, VTREMOTE_PIX_FMT_P210, FLAGS },
    { "vt_remote_decode_async", "allow async decode on server", OFFSET(decode_async), AV_OPT_TYPE_BOOL, { .i64 = 1 }, 0, 1, FLAGS },
    { "vt_remote_decode_reorder_depth", "decode reorder depth", OFFSET(decode_reorder_depth), AV_OPT_TYPE_INT, { .i64 = 2 }, -1, 64, FLAGS },
    { "vt_remote_bitrate", "target bitrate", OFFSET(bitrate), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, INT_MAX, FLAGS },
    { "vt_remote_maxrate", "max bitrate", OFFSET(maxrate), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, INT_MAX, FLAGS },
    { "vt_remote_bufsize", "VBV buffer size in bits", OFFSET(bufsize), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, INT_MAX, FLAGS },
    { "vt_remote_gop", "gop size", OFFSET(gop), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, INT_MAX, FLAGS },
    { "vt_remote_max_b_frames", "max b-frames", OFFSET(max_b_frames), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, 16, FLAGS },
    { "vt_remote_profile", "profile", OFFSET(profile), AV_OPT_TYPE_INT, { .i64 = -99 }, -99, INT_MAX, FLAGS },
    { "vt_remote_level", "level", OFFSET(level), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, INT_MAX, FLAGS },
    { "vt_remote_entropy", "entropy", OFFSET(entropy), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, 2, FLAGS },
    { "vt_remote_global_quality", "VideoToolbox quality from 1 to 100", OFFSET(global_quality), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, 100, FLAGS },
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
    { "vt_remote_codec_tag", "output codec tag", OFFSET(codec_tag), AV_OPT_TYPE_INT64, { .i64 = -1 }, -1, UINT32_MAX, FLAGS },
    { "vt_remote_color_range", "color range", OFFSET(color_range), AV_OPT_TYPE_INT, { .i64 = -1 }, -1, INT_MAX, FLAGS },
    { "vt_remote_colorspace", "colorspace", OFFSET(colorspace), AV_OPT_TYPE_INT, { .i64 = -1 }, -1, INT_MAX, FLAGS },
    { "vt_remote_color_primaries", "color primaries", OFFSET(color_primaries), AV_OPT_TYPE_INT, { .i64 = -1 }, -1, INT_MAX, FLAGS },
    { "vt_remote_color_trc", "color transfer", OFFSET(color_trc), AV_OPT_TYPE_INT, { .i64 = -1 }, -1, INT_MAX, FLAGS },
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
