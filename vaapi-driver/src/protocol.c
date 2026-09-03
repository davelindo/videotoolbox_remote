/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "vtremote/protocol.h"

#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

#include <lz4.h>
#include <zstd.h>

static void write_be16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)v;
}

static void write_be32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)v;
}

static void write_be64(uint8_t *p, uint64_t v) {
    write_be32(p, (uint32_t)(v >> 32));
    write_be32(p + 4, (uint32_t)v);
}

static uint32_t read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint64_t read_be64(const uint8_t *p) {
    return ((uint64_t)read_be32(p) << 32) | read_be32(p + 4);
}

void vtr_buffer_init(VTRBuffer *buffer) {
    if (buffer) memset(buffer, 0, sizeof(*buffer));
}

void vtr_buffer_reset(VTRBuffer *buffer) {
    if (buffer) buffer->size = 0;
}

void vtr_buffer_free(VTRBuffer *buffer) {
    if (!buffer) return;
    free(buffer->data);
    memset(buffer, 0, sizeof(*buffer));
}

int vtr_buffer_reserve(VTRBuffer *buffer, size_t additional) {
    size_t needed;
    size_t capacity;
    uint8_t *next;

    if (!buffer) return -EINVAL;
    if (additional > SIZE_MAX - buffer->size) return -EOVERFLOW;
    needed = buffer->size + additional;
    if (needed <= buffer->capacity) return 0;

    capacity = buffer->capacity ? buffer->capacity : 256;
    while (capacity < needed) {
        if (capacity > SIZE_MAX / 2) {
            capacity = needed;
            break;
        }
        capacity *= 2;
    }
    next = (uint8_t *)realloc(buffer->data, capacity);
    if (!next) return -ENOMEM;
    buffer->data = next;
    buffer->capacity = capacity;
    return 0;
}

int vtr_put_bytes(VTRBuffer *buffer, const void *data, size_t size) {
    int rc;
    if (size && !data) return -EINVAL;
    rc = vtr_buffer_reserve(buffer, size);
    if (rc < 0) return rc;
    if (size) memcpy(buffer->data + buffer->size, data, size);
    buffer->size += size;
    return 0;
}

int vtr_put_u8(VTRBuffer *buffer, uint8_t value) {
    return vtr_put_bytes(buffer, &value, 1);
}

int vtr_put_u16(VTRBuffer *buffer, uint16_t value) {
    uint8_t bytes[2];
    write_be16(bytes, value);
    return vtr_put_bytes(buffer, bytes, sizeof(bytes));
}

int vtr_put_u32(VTRBuffer *buffer, uint32_t value) {
    uint8_t bytes[4];
    write_be32(bytes, value);
    return vtr_put_bytes(buffer, bytes, sizeof(bytes));
}

int vtr_put_u64(VTRBuffer *buffer, uint64_t value) {
    uint8_t bytes[8];
    write_be64(bytes, value);
    return vtr_put_bytes(buffer, bytes, sizeof(bytes));
}

int vtr_put_string(VTRBuffer *buffer, const char *value) {
    size_t length = value ? strlen(value) : 0;
    int rc;
    if (length > UINT16_MAX) return -EOVERFLOW;
    rc = vtr_put_u16(buffer, (uint16_t)length);
    if (rc < 0) return rc;
    return vtr_put_bytes(buffer, value, length);
}

int vtr_build_hello(VTRBuffer *out, const char *token, const char *codec,
                    const char *client_name, const char *client_version) {
    int rc;
    if (!out || !codec || !client_name || !client_version) return -EINVAL;
    vtr_buffer_reset(out);
    if ((rc = vtr_put_string(out, token ? token : "")) < 0) return rc;
    if ((rc = vtr_put_string(out, codec)) < 0) return rc;
    if ((rc = vtr_put_string(out, client_name)) < 0) return rc;
    return vtr_put_string(out, client_version);
}

int vtr_build_configure(VTRBuffer *out, uint32_t width, uint32_t height,
                        VTRPixelFormat pixel_format,
                        uint32_t time_base_num, uint32_t time_base_den,
                        uint32_t frame_rate_num, uint32_t frame_rate_den,
                        const VTRKeyValue *options, size_t option_count) {
    size_t i;
    int rc;
    if (!out || !width || !height || !time_base_num || !time_base_den ||
        option_count > UINT16_MAX || (option_count && !options)) {
        return -EINVAL;
    }
    vtr_buffer_reset(out);
    if ((rc = vtr_put_u32(out, width)) < 0) return rc;
    if ((rc = vtr_put_u32(out, height)) < 0) return rc;
    if ((rc = vtr_put_u8(out, (uint8_t)pixel_format)) < 0) return rc;
    if ((rc = vtr_put_u32(out, time_base_num)) < 0) return rc;
    if ((rc = vtr_put_u32(out, time_base_den)) < 0) return rc;
    if ((rc = vtr_put_u32(out, frame_rate_num)) < 0) return rc;
    if ((rc = vtr_put_u32(out, frame_rate_den)) < 0) return rc;
    if ((rc = vtr_put_u16(out, (uint16_t)option_count)) < 0) return rc;
    for (i = 0; i < option_count; ++i) {
        if (!options[i].key || !options[i].value) return -EINVAL;
        if ((rc = vtr_put_string(out, options[i].key)) < 0) return rc;
        if ((rc = vtr_put_string(out, options[i].value)) < 0) return rc;
    }
    /* No codec extradata is needed for raw-frame encode. */
    return vtr_put_u32(out, 0);
}

static int put_frame_plane(VTRBuffer *out, const VTRFramePlane *plane,
                           VTRWireCompression compression) {
    uint8_t *compressed = NULL;
    size_t capacity = 0;
    size_t encoded_size = plane->size;
    int rc;

    if (compression == VTR_WIRE_COMPRESSION_LZ4) {
        int bound;
        int written;
        if (plane->size > INT_MAX) return -EOVERFLOW;
        bound = LZ4_compressBound((int)plane->size);
        if (bound <= 0) return -EOVERFLOW;
        capacity = (size_t)bound;
        compressed = (uint8_t *)malloc(capacity);
        if (!compressed) return -ENOMEM;
        written = LZ4_compress_default((const char *)plane->data,
                                       (char *)compressed,
                                       (int)plane->size, bound);
        if (written <= 0) {
            free(compressed);
            return -EIO;
        }
        encoded_size = (size_t)written;
    } else if (compression == VTR_WIRE_COMPRESSION_ZSTD) {
        capacity = ZSTD_compressBound(plane->size);
        if (ZSTD_isError(capacity)) return -EIO;
        compressed = (uint8_t *)malloc(capacity);
        if (!compressed) return -ENOMEM;
        encoded_size = ZSTD_compress(compressed, capacity, plane->data,
                                     plane->size, 1);
        if (ZSTD_isError(encoded_size)) {
            free(compressed);
            return -EIO;
        }
    } else if (compression != VTR_WIRE_COMPRESSION_NONE) {
        return -EINVAL;
    }

    if (encoded_size > UINT32_MAX) {
        free(compressed);
        return -EOVERFLOW;
    }
    if ((rc = vtr_put_u32(out, plane->stride)) < 0 ||
        (rc = vtr_put_u32(out, plane->height)) < 0 ||
        (rc = vtr_put_u32(out, (uint32_t)encoded_size)) < 0 ||
        (rc = vtr_put_bytes(out, compressed ? compressed : plane->data,
                            encoded_size)) < 0) {
        free(compressed);
        return rc;
    }
    free(compressed);
    return 0;
}

int vtr_build_frame(VTRBuffer *out, const VTRFrame *frame,
                    VTRWireCompression compression) {
    unsigned i;
    int rc;
    if (!out || !frame || frame->plane_count == 0 || frame->plane_count > 4)
        return -EINVAL;
    vtr_buffer_reset(out);
    if ((rc = vtr_put_u64(out, (uint64_t)frame->pts)) < 0) return rc;
    if ((rc = vtr_put_u64(out, (uint64_t)frame->duration)) < 0) return rc;
    if ((rc = vtr_put_u32(out, frame->flags)) < 0) return rc;
    if ((rc = vtr_put_u8(out, frame->plane_count)) < 0) return rc;
    for (i = 0; i < frame->plane_count; ++i) {
        const VTRFramePlane *plane = &frame->planes[i];
        if (!plane->data || !plane->stride || !plane->height || !plane->size)
            return -EINVAL;
        if ((rc = put_frame_plane(out, plane, compression)) < 0) return rc;
    }
    /* Side-data v2 count.  v1 currently sends none. */
    return vtr_put_u8(out, 0);
}

int vtr_parse_packet(const uint8_t *payload, size_t size, VTRPacketView *view) {
    uint32_t data_size;
    size_t offset;
    uint8_t side_data_count;
    unsigned i;
    if (!payload || !view || size < 32) return -EINVAL;
    data_size = read_be32(payload + 28);
    if ((size_t)data_size > size - 32) return -EINVAL;
    offset = 32U + data_size;
    if (offset < size) {
        side_data_count = payload[offset++];
        for (i = 0; i < side_data_count; ++i) {
            uint32_t side_size;
            if (size - offset < 8) return -EINVAL;
            side_size = read_be32(payload + offset + 4);
            offset += 8;
            if ((size_t)side_size > size - offset) return -EINVAL;
            offset += side_size;
        }
    }
    if (offset != size) return -EINVAL;
    memset(view, 0, sizeof(*view));
    view->pts = (int64_t)read_be64(payload);
    view->dts = (int64_t)read_be64(payload + 8);
    view->duration = (int64_t)read_be64(payload + 16);
    view->flags = read_be32(payload + 24);
    view->data_size = data_size;
    view->data = payload + 32;
    return 0;
}

int vtr_validate_message_size(uint16_t type, uint32_t size) {
    switch (type) {
        case VTR_MSG_FRAME:
        case VTR_MSG_PACKET:
            return size <= VTR_MAX_MEDIA_PAYLOAD ? 0 : -EOVERFLOW;
        case VTR_MSG_CONFIGURE:
        case VTR_MSG_CONFIGURE_ACK:
            return size <= VTR_MAX_CONTROL_PAYLOAD ? 0 : -EOVERFLOW;
        default:
            return size <= VTR_MAX_HANDSHAKE_PAYLOAD ? 0 : -EOVERFLOW;
    }
}

const char *vtr_message_type_name(uint16_t type) {
    switch (type) {
        case VTR_MSG_HELLO: return "HELLO";
        case VTR_MSG_HELLO_ACK: return "HELLO_ACK";
        case VTR_MSG_CONFIGURE: return "CONFIGURE";
        case VTR_MSG_CONFIGURE_ACK: return "CONFIGURE_ACK";
        case VTR_MSG_FRAME: return "FRAME";
        case VTR_MSG_PACKET: return "PACKET";
        case VTR_MSG_FLUSH: return "FLUSH";
        case VTR_MSG_DONE: return "DONE";
        case VTR_MSG_ERROR: return "ERROR";
        case VTR_MSG_PING: return "PING";
        case VTR_MSG_PONG: return "PONG";
        case VTR_MSG_PACKET_ACK: return "PACKET_ACK";
        default: return "UNKNOWN";
    }
}
