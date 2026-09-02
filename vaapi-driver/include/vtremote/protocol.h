/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef VTREMOTE_PROTOCOL_H
#define VTREMOTE_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VTR_PROTO_MAGIC 0x56545231U /* VTR1 */
#define VTR_PROTO_VERSION 1U
#define VTR_HEADER_SIZE 12U
#define VTR_DEFAULT_PORT "5555"
#define VTR_MAX_HANDSHAKE_PAYLOAD (64U * 1024U)
#define VTR_MAX_CONTROL_PAYLOAD (4U * 1024U * 1024U)
#define VTR_MAX_MEDIA_PAYLOAD (256U * 1024U * 1024U)

typedef enum VTRMessageType {
    VTR_MSG_HELLO = 1,
    VTR_MSG_HELLO_ACK = 2,
    VTR_MSG_CONFIGURE = 3,
    VTR_MSG_CONFIGURE_ACK = 4,
    VTR_MSG_FRAME = 5,
    VTR_MSG_PACKET = 6,
    VTR_MSG_FLUSH = 7,
    VTR_MSG_DONE = 8,
    VTR_MSG_ERROR = 9,
    VTR_MSG_PING = 10,
    VTR_MSG_PONG = 11,
    VTR_MSG_PACKET_ACK = 12
} VTRMessageType;

typedef enum VTRPixelFormat {
    VTR_PIXFMT_NV12 = 1,
    VTR_PIXFMT_P010 = 2,
    VTR_PIXFMT_BGRA = 3,
    VTR_PIXFMT_AYUV = 4,
    VTR_PIXFMT_P210 = 5,
    VTR_PIXFMT_VIDEOTOOLBOX = 6
} VTRPixelFormat;

typedef enum VTRWireCompression {
    VTR_WIRE_COMPRESSION_NONE = 0,
    VTR_WIRE_COMPRESSION_LZ4 = 1,
    VTR_WIRE_COMPRESSION_ZSTD = 2,
    VTR_WIRE_COMPRESSION_AUTO = 3
} VTRWireCompression;

typedef struct VTRBuffer {
    uint8_t *data;
    size_t size;
    size_t capacity;
} VTRBuffer;

typedef struct VTRMessage {
    uint16_t type;
    uint8_t *payload;
    uint32_t payload_size;
} VTRMessage;

typedef struct VTRKeyValue {
    const char *key;
    const char *value;
} VTRKeyValue;

typedef struct VTRFramePlane {
    const uint8_t *data;
    uint32_t stride;
    uint32_t height;
    uint32_t size;
} VTRFramePlane;

typedef struct VTRFrame {
    int64_t pts;
    int64_t duration;
    uint32_t flags;
    uint8_t plane_count;
    VTRFramePlane planes[4];
} VTRFrame;

typedef struct VTRPacketView {
    int64_t pts;
    int64_t dts;
    int64_t duration;
    uint32_t flags;
    const uint8_t *data;
    uint32_t data_size;
} VTRPacketView;

void vtr_buffer_init(VTRBuffer *buffer);
void vtr_buffer_reset(VTRBuffer *buffer);
void vtr_buffer_free(VTRBuffer *buffer);
int vtr_buffer_reserve(VTRBuffer *buffer, size_t additional);
int vtr_put_u8(VTRBuffer *buffer, uint8_t value);
int vtr_put_u16(VTRBuffer *buffer, uint16_t value);
int vtr_put_u32(VTRBuffer *buffer, uint32_t value);
int vtr_put_u64(VTRBuffer *buffer, uint64_t value);
int vtr_put_bytes(VTRBuffer *buffer, const void *data, size_t size);
int vtr_put_string(VTRBuffer *buffer, const char *value);

int vtr_build_hello(VTRBuffer *out, const char *token, const char *codec,
                    const char *client_name, const char *client_version);
int vtr_build_configure(VTRBuffer *out, uint32_t width, uint32_t height,
                        VTRPixelFormat pixel_format,
                        uint32_t time_base_num, uint32_t time_base_den,
                        uint32_t frame_rate_num, uint32_t frame_rate_den,
                        const VTRKeyValue *options, size_t option_count);
int vtr_build_frame(VTRBuffer *out, const VTRFrame *frame,
                    VTRWireCompression compression);
int vtr_parse_packet(const uint8_t *payload, size_t size, VTRPacketView *view);
int vtr_validate_message_size(uint16_t type, uint32_t size);
const char *vtr_message_type_name(uint16_t type);

#ifdef __cplusplus
}
#endif

#endif
