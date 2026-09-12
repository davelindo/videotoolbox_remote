/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef VTREMOTE_CLIENT_H
#define VTREMOTE_CLIENT_H

#include <stddef.h>
#include <stdint.h>
#include "vtremote/protocol.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VTRClientConfig {
    const char *endpoint;      /* host:port or [IPv6]:port */
    const char *token;
    const char *codec;         /* h264 or hevc */
    uint32_t width;
    uint32_t height;
    VTRPixelFormat pixel_format;
    uint32_t frame_rate_num;
    uint32_t frame_rate_den;
    uint32_t bit_rate;
    uint32_t max_rate;
    uint32_t gop_size;
    uint32_t max_b_frames;
    int profile;             /* FFmpeg AVProfile numeric value, or -1 */
    uint32_t global_quality; /* VideoToolbox quality, 1 (lowest) to 100 */
    int realtime;
    int constant_bit_rate;
    int timeout_ms;
    VTRWireCompression wire_compression;
} VTRClientConfig;

typedef struct VTRClient {
    int fd;
    int connected;
    int timeout_ms;
    char endpoint[512];
    char codec[16];
    uint64_t server_caps;
    VTRWireCompression wire_compression;
    VTRBuffer parameter_sets;
    VTRBuffer tx;
    VTRBuffer rx;
    unsigned pending_count;
    int64_t pending_pts[16];
    int flushing;
    uint8_t rx_header[VTR_HEADER_SIZE];
    size_t rx_header_read;
    size_t rx_body_read;
} VTRClient;

void vtr_client_init(VTRClient *client);
void vtr_client_destroy(VTRClient *client);
int vtr_client_connect(VTRClient *client, const VTRClientConfig *config,
                       char *error, size_t error_size);
/* Serialized calls may keep up to 16 frames in flight. Send returns -EAGAIN
 * at capacity. Receive returns 0 for a packet, 1 for a validated DONE. */
int vtr_client_send_frame(VTRClient *client, const VTRFrame *frame,
                          char *error, size_t error_size);
int vtr_client_receive_packet(VTRClient *client, VTRBuffer *packet,
                              int64_t *packet_pts, int64_t *packet_dts,
                              uint32_t *packet_flags, char *error, size_t error_size);
/* -EAGAIN preserves partial input and permits another bounded wait. */
int vtr_client_receive_packet_timeout(VTRClient *client, VTRBuffer *packet,
    int64_t *packet_pts, int64_t *packet_dts, uint32_t *packet_flags,
    char *error, size_t error_size, int timeout_ms);
int vtr_client_start_flush(VTRClient *client, char *error, size_t error_size);
int vtr_client_encode(VTRClient *client, const VTRFrame *frame,
                      VTRBuffer *packet, int64_t *packet_pts,
                      int64_t *packet_dts, uint32_t *packet_flags,
                      char *error, size_t error_size);
/* Convenience drain for a session with no outstanding output. */
int vtr_client_flush(VTRClient *client, char *error, size_t error_size);

#ifdef __cplusplus
}
#endif

#endif
