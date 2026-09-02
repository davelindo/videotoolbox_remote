/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "vtremote/protocol.h"

#include <lz4.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zstd.h>

static uint32_t read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | p[3];
}

static int check_frame_mode(VTRWireCompression compression) {
    uint8_t y[64 * 32];
    uint8_t uv[64 * 16];
    uint8_t decoded[sizeof(y)];
    VTRFrame frame;
    VTRBuffer buffer;
    uint32_t encoded_size;
    size_t offset = 21;
    int decoded_size;

    memset(y, 17, sizeof(y));
    memset(uv, 128, sizeof(uv));
    memset(&frame, 0, sizeof(frame));
    frame.pts = 7;
    frame.duration = 1;
    frame.flags = 1;
    frame.plane_count = 2;
    frame.planes[0] = (VTRFramePlane){y, 64, 32, sizeof(y)};
    frame.planes[1] = (VTRFramePlane){uv, 64, 16, sizeof(uv)};
    vtr_buffer_init(&buffer);
    if (vtr_build_frame(&buffer, &frame, compression) < 0) return 1;
    if (buffer.size <= offset + 12 || buffer.data[20] != 2) return 1;
    if (read_be32(buffer.data + offset) != 64 ||
        read_be32(buffer.data + offset + 4) != 32) return 1;
    encoded_size = read_be32(buffer.data + offset + 8);
    offset += 12;
    if (offset + encoded_size > buffer.size) return 1;
    if (compression == VTR_WIRE_COMPRESSION_NONE) {
        if (encoded_size != sizeof(y) || memcmp(buffer.data + offset, y, sizeof(y)))
            return 1;
    } else if (compression == VTR_WIRE_COMPRESSION_LZ4) {
        decoded_size = LZ4_decompress_safe((const char *)buffer.data + offset,
                                           (char *)decoded,
                                           (int)encoded_size,
                                           (int)sizeof(decoded));
        if (decoded_size != (int)sizeof(y) || memcmp(decoded, y, sizeof(y)))
            return 1;
    } else {
        size_t result = ZSTD_decompress(decoded, sizeof(decoded),
                                        buffer.data + offset, encoded_size);
        if (ZSTD_isError(result) || result != sizeof(y) ||
            memcmp(decoded, y, sizeof(y))) return 1;
    }
    vtr_buffer_free(&buffer);
    return 0;
}

int main(void) {
    VTRBuffer buffer;
    VTRPacketView packet;
    static const uint8_t packet_payload[] = {
        0,0,0,0,0,0,0,1, 0,0,0,0,0,0,0,1,
        0,0,0,0,0,0,0,1, 0,0,0,1, 0,0,0,4,
        0,0,0,1
    };
    static const uint8_t packet_with_side_data[] = {
        0,0,0,0,0,0,0,1, 0,0,0,0,0,0,0,1,
        0,0,0,0,0,0,0,1, 0,0,0,1, 0,0,0,4,
        0,0,0,1, 1, 0,0,0,7, 0,0,0,2, 0xaa,0xbb
    };

    vtr_buffer_init(&buffer);
    if (vtr_put_string(&buffer, "hello") < 0 || buffer.size != 7) return 1;
    vtr_buffer_free(&buffer);
    if (vtr_parse_packet(packet_payload, sizeof(packet_payload), &packet) < 0 ||
        packet.data_size != 4 || packet.flags != 1 || packet.pts != 1)
        return 1;
    if (vtr_parse_packet(packet_payload, sizeof(packet_payload) - 1, &packet) == 0)
        return 1;
    if (vtr_parse_packet(packet_with_side_data, sizeof(packet_with_side_data),
                         &packet) < 0 || packet.data_size != 4)
        return 1;
    if (vtr_parse_packet(packet_with_side_data,
                         sizeof(packet_with_side_data) - 1, &packet) == 0)
        return 1;
    if (vtr_validate_message_size(VTR_MSG_HELLO,
                                  VTR_MAX_HANDSHAKE_PAYLOAD + 1) == 0 ||
        vtr_validate_message_size(VTR_MSG_CONFIGURE,
                                  VTR_MAX_CONTROL_PAYLOAD) < 0 ||
        vtr_validate_message_size(VTR_MSG_PACKET,
                                  VTR_MAX_MEDIA_PAYLOAD) < 0)
        return 1;
    if (check_frame_mode(VTR_WIRE_COMPRESSION_NONE) ||
        check_frame_mode(VTR_WIRE_COMPRESSION_LZ4) ||
        check_frame_mode(VTR_WIRE_COMPRESSION_ZSTD)) return 1;
    puts("ok");
    return 0;
}
