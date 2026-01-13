/*
 * VTRemote encoder common scaffolding (M0)
 */

#include <errno.h>
#include <string.h>
#include <inttypes.h>
#include <limits.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>
#include <sys/time.h>

#include "config_components.h"
#include "avcodec.h"
#include "codec_internal.h"
#include "encode.h"
#include "internal.h"
#include "libavutil/avstring.h"
#include "libavutil/channel_layout.h"
#include "libavutil/intreadwrite.h"
#include "libavutil/ffversion.h"
#include "libavutil/avassert.h"
#include "libavutil/opt.h"
#include "libavutil/mem.h"
#include "libavutil/pixdesc.h"
#include "libavutil/time.h"
#include "vtremote_enc_common.h"
#include "vtremote_proto.h"
#include <lz4.h>

#define MIN_HVCC_LENGTH 23

static int vtremote_hevc_extradata_to_annexb(const uint8_t *in, int in_size,
                                             uint8_t **out, int *out_size)
{
    const uint8_t *p = in;
    const uint8_t *end = in + in_size;
    uint8_t *buf = NULL;
    int size = 0;

    if (in_size < MIN_HVCC_LENGTH)
        return AVERROR_INVALIDDATA;

    /* If already AnnexB, just copy. */
    if (AV_RB24(in) == 1 || AV_RB32(in) == 1) {
        buf = av_mallocz(in_size + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!buf)
            return AVERROR(ENOMEM);
        memcpy(buf, in, in_size);
        *out = buf;
        *out_size = in_size;
        return 0;
    }

    /* Skip configurationVersion..avgFrameRate (21 bytes). */
    p += 21;
    if (p + 2 > end)
        return AVERROR_INVALIDDATA;
    /* lengthSizeMinusOne in low 2 bits; unused here. */
    p++;
    int num_arrays = *p++;

    for (int i = 0; i < num_arrays; i++) {
        if (p + 3 > end) {
            av_freep(&buf);
            return AVERROR_INVALIDDATA;
        }
        /* array completeness + reserved + nal_unit_type */
        int nal_type = p[0] & 0x3f;
        (void)nal_type;
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
            if (av_reallocp(&buf, size + nal_len + 4 + AV_INPUT_BUFFER_PADDING_SIZE) < 0) {
                av_freep(&buf);
                return AVERROR(ENOMEM);
            }
            AV_WB32(buf + size, 1);
            memcpy(buf + size + 4, p, nal_len);
            size += 4 + nal_len;
            memset(buf + size, 0, AV_INPUT_BUFFER_PADDING_SIZE);
            p += nal_len;
        }
    }

    *out = buf;
    *out_size = size;
    return 0;
}

static int set_socket_timeout(int fd, int timeout_ms)
{
    struct timeval tv;
    tv.tv_sec  = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) < 0)
        return AVERROR(errno);
    if (setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv)) < 0)
        return AVERROR(errno);
    return 0;
}

static int write_full(int fd, const uint8_t *buf, int size)
{
    int sent = 0;
    while (sent < size) {
        ssize_t r = send(fd, buf + sent, size - sent, 0);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            return AVERROR(errno);
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
        ssize_t r = recv(fd, buf + got, size - got, 0);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            return AVERROR(errno);
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
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0)
        return AVERROR(errno ? errno : EIO);
    return fd;
}

static inline int vtremote_log_enabled(const VTRemoteEncContext *s, int level)
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

static int vtremote_send_msg(VTRemoteEncContext *s, int msg_type, VTRemoteWBuf *payload)
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

static int vtremote_read_msg(VTRemoteEncContext *s, VTRemoteMsgHeader *hdr, uint8_t **payload)
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

    /* Skip strings and counts best-effort */
    const uint8_t *s; int slen;
    vtremote_rbuf_read_str(&r, &s, &slen); /* server_name */
    vtremote_rbuf_read_str(&r, &s, &slen); /* server_version */
    uint8_t caps = 0;
    vtremote_rbuf_read_u8(&r, &caps);
    for (int i = 0; i < caps; i++)
        vtremote_rbuf_read_str(&r, &s, &slen);
    uint16_t max_sessions, active;
    vtremote_rbuf_read_u16(&r, &max_sessions);
    vtremote_rbuf_read_u16(&r, &active);
    return 0;
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
        const uint8_t *avcc = payload + r.pos;
        uint8_t *annexb = NULL;
        int annexb_size = 0;

        if (avctx->codec_id == AV_CODEC_ID_HEVC) {
            /* Convert hvcC to AnnexB extradata so muxers can reformat packets. */
            int conv = vtremote_hevc_extradata_to_annexb(avcc, extralen, &annexb, &annexb_size);
            if (conv < 0)
                return conv;
            av_freep(&avctx->extradata);
            avctx->extradata = annexb;
            avctx->extradata_size = annexb_size;
        /* Convert avcC to AnnexB extradata so muxers can reformat packets. */
        } else if (avcc[0] == 1 && extralen > 6) {
            int pos = 5;
            int sps_count = avcc[pos++] & 0x1f;
            for (int i = 0; i < sps_count && pos + 2 <= extralen; i++) {
                int sps_len = AV_RB16(avcc + pos); pos += 2;
                if (pos + sps_len > extralen) break;
                annexb_size += 4 + sps_len;
                pos += sps_len;
            }
            int pps_count = avcc[pos++] & 0xff;
            for (int i = 0; i < pps_count && pos + 2 <= extralen; i++) {
                int pps_len = AV_RB16(avcc + pos); pos += 2;
                if (pos + pps_len > extralen) break;
                annexb_size += 4 + pps_len;
                pos += pps_len;
            }
            annexb = av_mallocz(annexb_size + AV_INPUT_BUFFER_PADDING_SIZE);
            if (!annexb)
                return AVERROR(ENOMEM);
            int w = 0;
            pos = 5;
            sps_count = avcc[pos++] & 0x1f;
            for (int i = 0; i < sps_count && pos + 2 <= extralen; i++) {
                int sps_len = AV_RB16(avcc + pos); pos += 2;
                if (pos + sps_len > extralen) break;
                AV_WB32(annexb + w, 0x00000001); w += 4;
                memcpy(annexb + w, avcc + pos, sps_len); w += sps_len;
                pos += sps_len;
            }
            pps_count = avcc[pos++] & 0xff;
            for (int i = 0; i < pps_count && pos + 2 <= extralen; i++) {
                int pps_len = AV_RB16(avcc + pos); pos += 2;
                if (pos + pps_len > extralen) break;
                AV_WB32(annexb + w, 0x00000001); w += 4;
                memcpy(annexb + w, avcc + pos, pps_len); w += pps_len;
                pos += pps_len;
            }
            av_freep(&avctx->extradata);
            avctx->extradata = annexb;
            avctx->extradata_size = annexb_size;
        } else {
            av_freep(&avctx->extradata);
            avctx->extradata = av_mallocz(extralen + AV_INPUT_BUFFER_PADDING_SIZE);
            if (!avctx->extradata)
                return AVERROR(ENOMEM);
            memcpy(avctx->extradata, avcc, extralen);
            avctx->extradata_size = extralen;
        }
        r.pos += extralen;
    } else {
        av_freep(&avctx->extradata);
        avctx->extradata_size = 0;
    }

    uint8_t reported_pix = 0;
    vtremote_rbuf_read_u8(&r, &reported_pix);
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
    VTRemoteEncContext *s = avctx->priv_data;
    int fd = connect_hostport(s->host, s->timeout_ms);
    if (fd < 0) {
        av_log(avctx, AV_LOG_ERROR, "Failed to connect to %s\n", s->host);
        return fd;
    }
    s->fd = fd;

    /* HELLO */
    VTRemoteWBuf payload;
    vtremote_payload_hello(&payload, s->token, codec_name_for_id(s->codec_id),
                          "ffmpeg-vtremote", FFMPEG_VERSION);
    int ret = vtremote_send_msg(s, VTREMOTE_MSG_HELLO, &payload);
    vtremote_wbuf_free(&payload);
    if (ret < 0) {
        close(fd);
        s->fd = -1;
        return ret;
    }

    VTRemoteMsgHeader hdr;
    uint8_t *pl = NULL;
    ret = vtremote_read_msg(s, &hdr, &pl);
    if (ret < 0) {
        close(fd);
        s->fd = -1;
        return ret;
    }
    if (hdr.type != VTREMOTE_MSG_HELLO_ACK) {
        av_free(pl);
        close(fd);
        s->fd = -1;
        return AVERROR_INVALIDDATA;
    }
    ret = vtremote_handle_hello_ack(avctx, pl, hdr.length);
    av_free(pl);
    if (ret < 0) {
        close(fd);
        s->fd = -1;
        return ret;
    }

    /* CONFIGURE */
    VTRemoteKV *opts = NULL;
    int opt_count = 0;
    int opt_cap = 0;
    char *tmp = NULL;

    tmp = av_strdup("encode");
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "mode", tmp);
    if (ret < 0)
        goto cfg_fail;

    if (s->wire_compression > 0) {
        tmp = av_asprintf("%d", s->wire_compression);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "wire_compression", tmp);
        if (ret < 0) goto cfg_fail;
    }

    if (avctx->bit_rate > 0) {
        tmp = av_asprintf("%"PRId64, avctx->bit_rate);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "bitrate", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (avctx->rc_max_rate > 0) {
        tmp = av_asprintf("%"PRId64, avctx->rc_max_rate);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "maxrate", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (avctx->gop_size > 0) {
        tmp = av_asprintf("%d", avctx->gop_size);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "gop", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (avctx->max_b_frames > 0) {
        tmp = av_asprintf("%d", avctx->max_b_frames);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "max_b_frames", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (avctx->flags) {
        tmp = av_asprintf("%d", avctx->flags);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "flags", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (avctx->global_quality > 0) {
        tmp = av_asprintf("%d", avctx->global_quality);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "global_quality", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (avctx->qmin >= 0) {
        tmp = av_asprintf("%d", avctx->qmin);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "qmin", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (avctx->qmax >= 0) {
        tmp = av_asprintf("%d", avctx->qmax);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "qmax", tmp);
        if (ret < 0) goto cfg_fail;
    }
    {
        int profile = s->profile != AV_PROFILE_UNKNOWN ? s->profile : avctx->profile;
        if (profile != AV_PROFILE_UNKNOWN) {
            tmp = av_asprintf("%d", profile);
            if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
            ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "profile", tmp);
            if (ret < 0) goto cfg_fail;
        }
    }
    if (s->level > 0) {
        tmp = av_asprintf("%d", s->level);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "level", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->entropy >= 0) {
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
    if (s->frames_before) {
        tmp = av_strdup("1");
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "frames_before", tmp);
        if (ret < 0) goto cfg_fail;
    }
    if (s->frames_after) {
        tmp = av_strdup("1");
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "frames_after", tmp);
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
    if (s->spatialaq >= 0) {
        tmp = av_asprintf("%d", s->spatialaq);
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
        tmp = av_asprintf("%.6f", s->alpha_quality);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "alpha_quality", tmp);
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
    if (avctx->sample_aspect_ratio.num > 0 && avctx->sample_aspect_ratio.den > 0) {
        tmp = av_asprintf("%d", avctx->sample_aspect_ratio.num);
        if (!tmp) { ret = AVERROR(ENOMEM); goto cfg_fail; }
        ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "sar_num", tmp);
        if (ret < 0) goto cfg_fail;
        tmp = av_asprintf("%d", avctx->sample_aspect_ratio.den);
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

    int wire_pix_fmt = 0;
    switch (avctx->pix_fmt) {
    case AV_PIX_FMT_NV12:
        wire_pix_fmt = 1;
        break;
    case AV_PIX_FMT_P010LE:
        wire_pix_fmt = 2;
        break;
    default:
        av_log(avctx, AV_LOG_ERROR, "Unsupported pix_fmt for vtremote: %s\n",
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
                              NULL, 0);
    ret = vtremote_send_msg(s, VTREMOTE_MSG_CONFIGURE, &cfg);
cfg_fail:
    for (int i = 0; i < opt_count; i++)
        av_freep(&opts[i].value);
    av_freep(&opts);
    vtremote_wbuf_free(&cfg);
    if (ret < 0) {
        close(fd);
        s->fd = -1;
        return ret;
    }

    ret = vtremote_read_msg(s, &hdr, &pl);
    if (ret < 0) {
        close(fd);
        s->fd = -1;
        return ret;
    }
    if (hdr.type != VTREMOTE_MSG_CONFIGURE_ACK) {
        av_free(pl);
        close(fd);
        s->fd = -1;
        return AVERROR_INVALIDDATA;
    }
    ret = vtremote_handle_configure_ack(avctx, pl, hdr.length);
    av_free(pl);
    if (ret < 0) {
        close(fd);
        s->fd = -1;
        return ret;
    }

    s->connected = 1;
    return 0;
}

static int enqueue_packet(AVCodecContext *avctx, const uint8_t *payload, int payload_size)
{
    VTRemoteEncContext *s = avctx->priv_data;
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
    if (s->pkt_q_count < s->pkt_q_size)
        s->pkt_q_count++;
    else
        return AVERROR_BUFFER_TOO_SMALL;
    s->packets_recv++;
    return 0;
}

int ff_vtremote_common_init(AVCodecContext *avctx)
{
    VTRemoteEncContext *s = avctx->priv_data;
    s->codec_id = avctx->codec_id;
    s->fd = -1;
    s->start_time_us = av_gettime_relative();
    s->frames_sent = 0;
    s->packets_recv = 0;
    s->bytes_sent = 0;
    s->bytes_recv = 0;
    s->max_inflight = 0;
    vtremote_wbuf_init(&s->frame_buf);
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
        av_log(avctx, AV_LOG_VERBOSE, "VT remote init codec=%d host=%s inflight=%d timeout_ms=%d\n",
               s->codec_id, s->host, s->inflight, s->timeout_ms);
    }

    return vtremote_handshake(avctx);
}

int ff_vtremote_common_close(AVCodecContext *avctx)
{
    VTRemoteEncContext *s = avctx->priv_data;
    if (vtremote_log_enabled(s, AV_LOG_VERBOSE))
        av_log(avctx, AV_LOG_VERBOSE, "VT remote close\n");
    if (s->fd >= 0)
        close(s->fd);
    vtremote_wbuf_free(&s->frame_buf);
    if (s->pkt_queue) {
        for (int i = 0; i < s->pkt_q_size; i++)
            av_packet_unref(&s->pkt_queue[i]);
        av_freep(&s->pkt_queue);
    }
    av_freep(&s->lz4_buf[0]);
    av_freep(&s->lz4_buf[1]);
    if (vtremote_log_enabled(s, AV_LOG_INFO) && s->start_time_us > 0) {
        int64_t elapsed_us = av_gettime_relative() - s->start_time_us;
        double elapsed = elapsed_us > 0 ? (double)elapsed_us / 1000000.0 : 0.0;
        double mbps_in = elapsed > 0 ? (double)s->bytes_sent * 8.0 / (elapsed * 1000000.0) : 0.0;
        double mbps_out = elapsed > 0 ? (double)s->bytes_recv * 8.0 / (elapsed * 1000000.0) : 0.0;
        av_log(avctx, AV_LOG_INFO,
               "VT remote summary: frames=%"PRId64" packets=%"PRId64" bytes_in=%"PRId64" bytes_out=%"PRId64
               " max_inflight=%d elapsed=%.3fs in=%.2fMb/s out=%.2fMb/s\n",
               s->frames_sent, s->packets_recv, s->bytes_sent, s->bytes_recv,
               s->max_inflight, elapsed, mbps_in, mbps_out);
    }
    av_opt_free(s);
    return 0;
}

int ff_vtremote_common_send_frame(AVCodecContext *avctx, const AVFrame *frame)
{
    VTRemoteEncContext *s = avctx->priv_data;
    if (!s->connected)
        return AVERROR(EPIPE);

    if (!frame) {
        s->flushing = 1;
        VTRemoteWBuf empty = {0};
        return vtremote_send_msg(s, VTREMOTE_MSG_FLUSH, &empty);
    }

    if (frame->format != AV_PIX_FMT_NV12 &&
        frame->format != AV_PIX_FMT_P010LE &&
        frame->format != AV_PIX_FMT_P010) {
        av_log(avctx, AV_LOG_ERROR, "VTRemote supports NV12/P010 only\n");
        return AVERROR(EINVAL);
    }
    if (s->codec_id == AV_CODEC_ID_H264 && frame->format != AV_PIX_FMT_NV12) {
        av_log(avctx, AV_LOG_ERROR, "H.264 VTRemote only supports NV12\n");
        return AVERROR(EINVAL);
    }

    const uint8_t *planes[2] = { frame->data[0], frame->data[1] };
    uint32_t strides[2] = { frame->linesize[0], frame->linesize[1] };
    uint32_t heights[2] = { (uint32_t)frame->height, (uint32_t)(frame->height / 2) };
    uint32_t sizes[2] = { strides[0] * heights[0], strides[1] * heights[1] };
    const uint8_t *send_planes[2] = { planes[0], planes[1] };
    uint32_t send_sizes[2] = { sizes[0], sizes[1] };

    if (s->wire_compression == 1) {
        for (int i = 0; i < 2; i++) {
            int src_size = (int)sizes[i];
            int bound = LZ4_compressBound(src_size);
            if (bound <= 0)
                return AVERROR_EXTERNAL;
            if (bound > s->lz4_buf_cap[i]) {
                uint8_t *tmp = av_realloc(s->lz4_buf[i], bound);
                if (!tmp)
                    return AVERROR(ENOMEM);
                s->lz4_buf[i] = tmp;
                s->lz4_buf_cap[i] = bound;
            }
            int out = LZ4_compress_default((const char *)planes[i], (char *)s->lz4_buf[i],
                                           src_size, s->lz4_buf_cap[i]);
            if (out <= 0)
                return AVERROR_EXTERNAL;
            send_planes[i] = s->lz4_buf[i];
            send_sizes[i] = out;
        }
    }

    VTRemoteWBuf *payload = &s->frame_buf;
    vtremote_wbuf_reset(payload);
    int ret = vtremote_payload_frame(payload, frame->pts, frame->duration, frame->pict_type == AV_PICTURE_TYPE_I,
                                    2, send_planes, strides, heights, send_sizes);
    if (ret < 0)
        return ret;
    ret = vtremote_send_msg(s, VTREMOTE_MSG_FRAME, payload);
    if (ret == 0)
        s->inflight_frames++;
    if (s->inflight_frames > s->max_inflight)
        s->max_inflight = s->inflight_frames;
    if (ret == 0)
        s->frames_sent++;
    return ret;
}

int ff_vtremote_common_receive_packet(AVCodecContext *avctx, AVPacket *pkt)
{
    VTRemoteEncContext *s = avctx->priv_data;
    if (s->done)
        return AVERROR_EOF;

    /* if queued packets, pop */
    if (s->pkt_q_count > 0) {
        AVPacket *src = &s->pkt_queue[s->pkt_q_head];
        int ret = av_packet_ref(pkt, src);
        av_packet_unref(src);
        s->pkt_q_head = (s->pkt_q_head + 1) % s->pkt_q_size;
        s->pkt_q_count--;
        return ret;
    }

    for (;;) {
        VTRemoteMsgHeader hdr;
        uint8_t *payload = NULL;
        int ret = vtremote_read_msg(s, &hdr, &payload);
        if (ret < 0)
            return ret;

        switch (hdr.type) {
        case VTREMOTE_MSG_PACKET:
            ret = enqueue_packet(avctx, payload, hdr.length);
            av_free(payload);
            if (ret < 0)
                return ret;
            /* pop immediately */
            if (s->pkt_q_count > 0) {
                AVPacket *src = &s->pkt_queue[s->pkt_q_head];
                int rc = av_packet_ref(pkt, src);
                av_packet_unref(src);
                s->pkt_q_head = (s->pkt_q_head + 1) % s->pkt_q_size;
                s->pkt_q_count--;
                if (s->inflight_frames > 0)
                    s->inflight_frames--;
                return rc;
            }
            return AVERROR_BUG;
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

int ff_vtremote_encode(AVCodecContext *avctx, AVPacket *pkt, const AVFrame *frame, int *got_packet)
{
    VTRemoteEncContext *s = avctx->priv_data;
    if (!s->pkt_queue) {
        s->pkt_q_size = FFMAX(4, s->inflight);
        s->pkt_queue = av_calloc(s->pkt_q_size, sizeof(AVPacket));
        if (!s->pkt_queue)
            return AVERROR(ENOMEM);
    }

    int ret = 0;

    if (frame && s->inflight_frames >= s->inflight) {
        /* backpressure: drain before sending more */
        ret = ff_vtremote_common_receive_packet(avctx, pkt);
        if (ret >= 0) {
            if (got_packet)
                *got_packet = 1;
            return 0;
        }
        if (got_packet)
            *got_packet = 0;
        return ret;
    }

    if (frame || avctx->internal->draining) {
        ret = ff_vtremote_common_send_frame(avctx, frame);
        if (ret < 0 && ret != AVERROR_EOF)
            return ret;
    }

    ret = ff_vtremote_common_receive_packet(avctx, pkt);
    if (ret >= 0) {
        if (got_packet)
            *got_packet = 1;
        return 0;
    }
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
        if (got_packet)
            *got_packet = 0;
    }
    return ret;
}
