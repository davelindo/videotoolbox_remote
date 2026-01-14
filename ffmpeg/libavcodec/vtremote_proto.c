/*
 * VTRemote protocol helpers (v1)
 *
 * Non-inline utilities shared across encoder and any mock/test harnesses.
 */

#include <string.h>

#include "libavutil/log.h"
#include "vtremote_proto.h"

static const char *msg_names[] = {
    [VTREMOTE_MSG_HELLO]         = "HELLO",
    [VTREMOTE_MSG_HELLO_ACK]     = "HELLO_ACK",
    [VTREMOTE_MSG_CONFIGURE]     = "CONFIGURE",
    [VTREMOTE_MSG_CONFIGURE_ACK] = "CONFIGURE_ACK",
    [VTREMOTE_MSG_FRAME]         = "FRAME",
    [VTREMOTE_MSG_PACKET]        = "PACKET",
    [VTREMOTE_MSG_FLUSH]         = "FLUSH",
    [VTREMOTE_MSG_DONE]          = "DONE",
    [VTREMOTE_MSG_ERROR]         = "ERROR",
    [VTREMOTE_MSG_PING]          = "PING",
    [VTREMOTE_MSG_PONG]          = "PONG",
};

const char *vtremote_msg_type_name(int type)
{
    if (type <= 0 || type >= (int)(sizeof(msg_names) / sizeof(msg_names[0])))
        return "UNKNOWN";
    return msg_names[type] ? msg_names[type] : "UNKNOWN";
}

/* --- write buffer helpers ------------------------------------------------ */

#include "libavutil/mem.h"

static int wbuf_reserve(VTRemoteWBuf *b, size_t add)
{
    if (!b)
        return AVERROR(EINVAL);
    size_t needed = b->size + add;
    b->data = av_fast_realloc(b->data, &b->capacity, needed);
    if (!b->data)
        return AVERROR(ENOMEM);
    return 0;
}

void vtremote_wbuf_init(VTRemoteWBuf *b)
{
    if (!b) return;
    b->data = NULL;
    b->size = 0;
    b->capacity = 0;
}

void vtremote_wbuf_reset(VTRemoteWBuf *b)
{
    if (!b) return;
    b->size = 0;
}

void vtremote_wbuf_free(VTRemoteWBuf *b)
{
    if (!b) return;
    av_freep(&b->data);
    b->size = 0;
    b->capacity = 0;
}

int vtremote_wbuf_put_u8(VTRemoteWBuf *b, uint8_t v)
{
    int ret = wbuf_reserve(b, 1);
    if (ret < 0)
        return ret;
    b->data[b->size++] = v;
    return 0;
}

int vtremote_wbuf_put_u16(VTRemoteWBuf *b, uint16_t v)
{
    int ret = wbuf_reserve(b, 2);
    if (ret < 0)
        return ret;
    AV_WB16(b->data + b->size, v);
    b->size += 2;
    return 0;
}

int vtremote_wbuf_put_u32(VTRemoteWBuf *b, uint32_t v)
{
    int ret = wbuf_reserve(b, 4);
    if (ret < 0)
        return ret;
    AV_WB32(b->data + b->size, v);
    b->size += 4;
    return 0;
}

int vtremote_wbuf_put_u64(VTRemoteWBuf *b, uint64_t v)
{
    int ret = wbuf_reserve(b, 8);
    if (ret < 0)
        return ret;
    AV_WB64(b->data + b->size, v);
    b->size += 8;
    return 0;
}

int vtremote_wbuf_put_bytes(VTRemoteWBuf *b, const uint8_t *src, int len)
{
    if (len < 0)
        return AVERROR(EINVAL);
    int ret = wbuf_reserve(b, (size_t)len);
    if (ret < 0)
        return ret;
    if (len)
        memcpy(b->data + b->size, src, len);
    b->size += len;
    return 0;
}

int vtremote_wbuf_put_str(VTRemoteWBuf *b, const char *s)
{
    if (!s)
        s = "";
    size_t len = strlen(s);
    if (len > 0xFFFF)
        return AVERROR(EINVAL);
    int ret = vtremote_wbuf_put_u16(b, (uint16_t)len);
    if (ret < 0)
        return ret;
    return vtremote_wbuf_put_bytes(b, (const uint8_t *)s, (int)len);
}

int vtremote_build_message(int msg_type, const VTRemoteWBuf *payload,
                          uint8_t **out_buf, int *out_size)
{
    if (!out_buf || !out_size)
        return AVERROR(EINVAL);
    const uint8_t *payload_data = payload ? payload->data : NULL;
    size_t payload_size = payload ? payload->size : 0;

    size_t total = VTREMOTE_HEADER_SIZE + payload_size;
    uint8_t *buf = av_malloc(total);
    if (!buf)
        return AVERROR(ENOMEM);

    VTRemoteMsgHeader hdr = {
        .magic   = VTREMOTE_PROTO_MAGIC,
        .version = VTREMOTE_PROTO_VERSION,
        .type    = msg_type,
        .length  = payload_size,
    };
    int ret = vtremote_write_header(buf, VTREMOTE_HEADER_SIZE, &hdr);
    if (ret < 0) {
        av_free(buf);
        return ret;
    }
    if (payload_size && payload_data)
        memcpy(buf + VTREMOTE_HEADER_SIZE, payload_data, payload_size);

    *out_buf = buf;
    *out_size = total;
    return 0;
}

/* --- read buffer helpers ------------------------------------------------- */

static int rbuf_need(VTRemoteRBuf *r, int n)
{
    if (!r || n < 0)
        return AVERROR(EINVAL);
    if (r->pos + n > r->size)
        return AVERROR(EINVAL);
    return 0;
}

int vtremote_rbuf_read_u8(VTRemoteRBuf *r, uint8_t *out)
{
    int ret = rbuf_need(r, 1);
    if (ret < 0)
        return ret;
    if (out)
        *out = r->data[r->pos];
    r->pos += 1;
    return 0;
}

int vtremote_rbuf_read_u16(VTRemoteRBuf *r, uint16_t *out)
{
    int ret = rbuf_need(r, 2);
    if (ret < 0)
        return ret;
    if (out)
        *out = AV_RB16(r->data + r->pos);
    r->pos += 2;
    return 0;
}

int vtremote_rbuf_read_u32(VTRemoteRBuf *r, uint32_t *out)
{
    int ret = rbuf_need(r, 4);
    if (ret < 0)
        return ret;
    if (out)
        *out = AV_RB32(r->data + r->pos);
    r->pos += 4;
    return 0;
}

int vtremote_rbuf_read_u64(VTRemoteRBuf *r, uint64_t *out)
{
    int ret = rbuf_need(r, 8);
    if (ret < 0)
        return ret;
    if (out)
        *out = AV_RB64(r->data + r->pos);
    r->pos += 8;
    return 0;
}

int vtremote_rbuf_read_str(VTRemoteRBuf *r, const uint8_t **str, int *len)
{
    uint16_t l = 0;
    int ret = vtremote_rbuf_read_u16(r, &l);
    if (ret < 0)
        return ret;
    ret = rbuf_need(r, l);
    if (ret < 0)
        return ret;
    if (str)
        *str = r->data + r->pos;
    if (len)
        *len = l;
    r->pos += l;
    return 0;
}

/* --- high-level payload helpers ----------------------------------------- */

int vtremote_payload_hello(VTRemoteWBuf *b,
                          const char *token,
                          const char *requested_codec,
                          const char *client_name,
                          const char *client_build_id)
{
    vtremote_wbuf_reset(b);
    int ret = 0;
    ret |= vtremote_wbuf_put_str(b, token);
    ret |= vtremote_wbuf_put_str(b, requested_codec);
    ret |= vtremote_wbuf_put_str(b, client_name);
    ret |= vtremote_wbuf_put_str(b, client_build_id);
    return ret;
}

int vtremote_payload_configure(VTRemoteWBuf *b,
                              uint32_t width, uint32_t height,
                              uint8_t pix_fmt,
                              uint32_t time_base_num, uint32_t time_base_den,
                              uint32_t fr_num, uint32_t fr_den,
                              const VTRemoteKV *options, int options_count,
                              const uint8_t *extradata, uint32_t extradata_len)
{
    if (options_count < 0)
        return AVERROR(EINVAL);
    vtremote_wbuf_reset(b);
    int ret = 0;
    ret |= vtremote_wbuf_put_u32(b, width);
    ret |= vtremote_wbuf_put_u32(b, height);
    ret |= vtremote_wbuf_put_u8(b, pix_fmt);
    ret |= vtremote_wbuf_put_u32(b, time_base_num);
    ret |= vtremote_wbuf_put_u32(b, time_base_den);
    ret |= vtremote_wbuf_put_u32(b, fr_num);
    ret |= vtremote_wbuf_put_u32(b, fr_den);
    ret |= vtremote_wbuf_put_u16(b, (uint16_t)options_count);
    if (ret < 0)
        return ret;
    for (int i = 0; i < options_count; i++) {
        ret |= vtremote_wbuf_put_str(b, options[i].key);
        ret |= vtremote_wbuf_put_str(b, options[i].value);
        if (ret < 0)
            return ret;
    }
    ret |= vtremote_wbuf_put_u32(b, extradata_len);
    if (ret < 0)
        return ret;
    if (extradata_len && extradata) {
        ret |= vtremote_wbuf_put_bytes(b, extradata, extradata_len);
        if (ret < 0)
            return ret;
    }
    return ret;
}

int vtremote_payload_frame(VTRemoteWBuf *b,
                          int64_t pts, int64_t duration, uint32_t flags,
                          uint8_t plane_count,
                          const uint8_t *const *planes,
                          const uint32_t *strides,
                          const uint32_t *heights,
                          const uint32_t *sizes,
                          const VTRemoteSideData *side_data,
                          uint8_t side_data_count)
{
    if (!planes || !strides || !heights || !sizes)
        return AVERROR(EINVAL);
    vtremote_wbuf_reset(b);
    int ret = 0;
    ret |= vtremote_wbuf_put_u64(b, (uint64_t)pts);
    ret |= vtremote_wbuf_put_u64(b, (uint64_t)duration);
    ret |= vtremote_wbuf_put_u32(b, flags);
    ret |= vtremote_wbuf_put_u8(b, plane_count);
    if (ret < 0)
        return ret;
    for (int i = 0; i < plane_count; i++) {
        ret |= vtremote_wbuf_put_u32(b, strides[i]);
        ret |= vtremote_wbuf_put_u32(b, heights[i]);
        ret |= vtremote_wbuf_put_u32(b, sizes[i]);
        if (ret < 0)
            return ret;
        ret |= vtremote_wbuf_put_bytes(b, planes[i], sizes[i]);
        if (ret < 0)
            return ret;
    }
    
    if (side_data_count > 0 && side_data) {
        ret |= vtremote_wbuf_put_u8(b, side_data_count);
        for (int i = 0; i < side_data_count; i++) {
            ret |= vtremote_wbuf_put_u32(b, side_data[i].type);
            ret |= vtremote_wbuf_put_u32(b, side_data[i].size);
            if (ret < 0) return ret;
            ret |= vtremote_wbuf_put_bytes(b, side_data[i].data, (int)side_data[i].size);
            if (ret < 0) return ret;
        }
    }
    
    return ret;
}

int vtremote_payload_packet(VTRemoteWBuf *b,
                           int64_t pts, int64_t dts, int64_t duration, uint32_t flags,
                           const uint8_t *data, uint32_t data_len)
{
    vtremote_wbuf_reset(b);
    int ret = 0;
    ret |= vtremote_wbuf_put_u64(b, (uint64_t)pts);
    ret |= vtremote_wbuf_put_u64(b, (uint64_t)dts);
    ret |= vtremote_wbuf_put_u64(b, (uint64_t)duration);
    ret |= vtremote_wbuf_put_u32(b, flags);
    ret |= vtremote_wbuf_put_u32(b, data_len);
    if (ret < 0)
        return ret;
    if (data_len && data) {
        ret |= vtremote_wbuf_put_bytes(b, data, data_len);
        if (ret < 0)
            return ret;
    }
    return ret;
}

int vtremote_parse_packet(const uint8_t *payload, int payload_size, VTRemotePacketView *out)
{
    if (!payload || !out || payload_size < 8 + 8 + 8 + 4 + 4)
        return AVERROR(EINVAL);
    VTRemoteRBuf r;
    vtremote_rbuf_init(&r, payload, payload_size);
    uint64_t pts, dts, dur;
    uint32_t flags, data_len;
    int ret = 0;
    ret |= vtremote_rbuf_read_u64(&r, &pts);
    ret |= vtremote_rbuf_read_u64(&r, &dts);
    ret |= vtremote_rbuf_read_u64(&r, &dur);
    ret |= vtremote_rbuf_read_u32(&r, &flags);
    ret |= vtremote_rbuf_read_u32(&r, &data_len);
    if (ret < 0)
        return ret;
    if (data_len > (uint32_t)(r.size - r.pos))
        return AVERROR_INVALIDDATA;
    out->pts = (int64_t)pts;
    out->dts = (int64_t)dts;
    out->duration = (int64_t)dur;
    out->flags = flags;
    out->data_len = data_len;
    out->data = r.data + r.pos;
    return 0;
}

int vtremote_parse_frame(const uint8_t *payload, int payload_size, VTRemoteFrameView *out)
{
    if (!payload || !out || payload_size < 8 + 8 + 4 + 1)
        return AVERROR(EINVAL);
    VTRemoteRBuf r;
    vtremote_rbuf_init(&r, payload, payload_size);
    uint64_t pts, dur;
    uint32_t flags;
    uint8_t plane_count;
    int ret = 0;
    ret |= vtremote_rbuf_read_u64(&r, &pts);
    ret |= vtremote_rbuf_read_u64(&r, &dur);
    ret |= vtremote_rbuf_read_u32(&r, &flags);
    ret |= vtremote_rbuf_read_u8(&r, &plane_count);
    if (ret < 0)
        return ret;
    if (plane_count > 4)
        return AVERROR_INVALIDDATA;
    out->pts = (int64_t)pts;
    out->duration = (int64_t)dur;
    out->flags = flags;
    out->plane_count = plane_count;
    for (int i = 0; i < plane_count; i++) {
        uint32_t stride, height, data_len;
        ret |= vtremote_rbuf_read_u32(&r, &stride);
        ret |= vtremote_rbuf_read_u32(&r, &height);
        ret |= vtremote_rbuf_read_u32(&r, &data_len);
        if (ret < 0)
            return ret;
        if (data_len > (uint32_t)(r.size - r.pos))
            return AVERROR_INVALIDDATA;
        out->planes[i].stride = stride;
        out->planes[i].height = height;
        out->planes[i].data_len = data_len;
        out->planes[i].data = r.data + r.pos;
        r.pos += data_len;
    }
    
    if (r.pos < r.size) {
        uint8_t sd_count = 0;
        ret |= vtremote_rbuf_read_u8(&r, &sd_count);
        if (ret < 0) return ret;
        
        out->side_data_count = sd_count > 8 ? 8 : sd_count;
        
        for (int i = 0; i < sd_count; i++) {
            uint32_t type, size;
            ret |= vtremote_rbuf_read_u32(&r, &type);
            ret |= vtremote_rbuf_read_u32(&r, &size);
            if (ret < 0) return ret;
            if (size > (uint32_t)(r.size - r.pos)) return AVERROR_INVALIDDATA;
            
            if (i < 8) {
                out->side_data[i].type = type;
                out->side_data[i].size = size;
                out->side_data[i].data = r.data + r.pos;
            }
            r.pos += size;
        }
    } else {
        out->side_data_count = 0;
    }
    
    return 0;
}
