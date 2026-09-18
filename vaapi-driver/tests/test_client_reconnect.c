/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "vtremote/client.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>

#define CHECK(expression) do { \
    if (!(expression)) { \
        fprintf(stderr, "%s failed: %s\n", #expression, error); \
        goto fail; \
    } \
} while (0)

/* The recovery peer advertises different parameter sets from the fault peer. */
static const uint8_t recovered_parameters[] = {
    0, 0, 0, 1, 0x67, 0x64, 0, 0x1e, 0, 0, 0, 1, 0x68, 0xee, 0x3c, 0x80
};
static const uint8_t recovered_nal[] = {0, 0, 0, 1, 0x65, 0x88};

static VTRClientConfig make_config(const char *endpoint, const char *token)
{
    VTRClientConfig config;

    memset(&config, 0, sizeof(config));
    config.endpoint = endpoint;
    config.token = token;
    config.codec = "h264";
    config.width = 320;
    config.height = 180;
    config.pixel_format = VTR_PIXFMT_NV12;
    config.frame_rate_num = 24;
    config.frame_rate_den = 1;
    config.bit_rate = 500000;
    config.max_rate = 600000;
    config.gop_size = 24;
    config.profile = 100;
    config.timeout_ms = 3000;
    config.wire_compression = VTR_WIRE_COMPRESSION_NONE;
    return config;
}

int main(int argc, char **argv)
{
    VTRClient client;
    VTRClientConfig config;
    VTRBuffer packet;
    VTRFrame frame = {0};
    uint8_t y[320 * 180], uv[320 * 90];
    int64_t pts = -1, dts = -1;
    uint32_t flags = 0;
    char error[256] = {0};
    int result = 1;

    if (argc != 4) {
        fprintf(stderr, "usage: %s FAIL_ENDPOINT SUCCESS_ENDPOINT "
                        "handshake|header|body|send\n", argv[0]);
        return 2;
    }

    vtr_client_init(&client);
    vtr_buffer_init(&packet);
    memset(y, 16, sizeof(y));
    memset(uv, 128, sizeof(uv));
    frame.pts = 1234;
    frame.duration = 1;
    frame.flags = 1;
    frame.plane_count = 2;
    frame.planes[0] = (VTRFramePlane){y, 320, 180, sizeof(y)};
    frame.planes[1] = (VTRFramePlane){uv, 320, 90, sizeof(uv)};
    config = make_config(argv[1], "wrong-token");
    if (!strcmp(argv[3], "handshake")) {
        CHECK(vtr_client_connect(&client, &config, error, sizeof(error)) < 0);
    } else {
        CHECK(vtr_client_connect(&client, &config, error, sizeof(error)) == 0);
        CHECK(client.parameter_sets.size > 0);
        CHECK(client.parameter_sets.size != sizeof(recovered_parameters) ||
              memcmp(client.parameter_sets.data, recovered_parameters,
                     sizeof(recovered_parameters)) != 0);
        CHECK(vtr_client_send_frame(&client, &frame, error, sizeof(error)) == 0);
        CHECK(client.pending_count == 1 && client.pending_pts[0] == frame.pts);
        if (!strcmp(argv[3], "send")) {
            /* Deterministic terminal send failure after a frame is pending. */
            CHECK(shutdown(client.fd, SHUT_WR) == 0);
            ++frame.pts;
            CHECK(vtr_client_send_frame(&client, &frame, error, sizeof(error)) == -EPIPE);
        } else {
            CHECK(vtr_client_receive_packet(&client, &packet, NULL, NULL, NULL,
                                             error, sizeof(error)) == -ECONNRESET);
            if (!strcmp(argv[3], "header")) {
                CHECK(client.rx_header_read == 7 && client.rx_body_read == 0);
            } else {
                CHECK(!strcmp(argv[3], "body"));
                CHECK(client.rx_header_read == VTR_HEADER_SIZE && client.rx_body_read == 5);
            }
        }
        CHECK(client.pending_count == 1);
        CHECK(client.tx.data && client.rx.data && client.parameter_sets.data);
    }
    CHECK(client.fd == -1 && !client.connected);

    config = make_config(argv[2], "");
    CHECK(vtr_client_connect(&client, &config, error, sizeof(error)) == 0);
    CHECK(client.pending_count == 0 && !client.flushing);
    CHECK(client.rx_header_read == 0 && client.rx_body_read == 0);
    CHECK(client.parameter_sets.size == sizeof(recovered_parameters));
    CHECK(memcmp(client.parameter_sets.data, recovered_parameters,
                 sizeof(recovered_parameters)) == 0);
    frame.pts = 9002;
    CHECK(vtr_client_encode(&client, &frame, &packet, &pts, &dts, &flags,
                            error, sizeof(error)) == 0);
    CHECK(pts == frame.pts && dts == frame.pts && flags == 1);
    CHECK(client.pending_count == 0);
    CHECK(packet.size == sizeof(recovered_parameters) + sizeof(recovered_nal));
    CHECK(memcmp(packet.data, recovered_parameters, sizeof(recovered_parameters)) == 0);
    CHECK(memcmp(packet.data + sizeof(recovered_parameters), recovered_nal,
                 sizeof(recovered_nal)) == 0);
    CHECK(vtr_client_flush(&client, error, sizeof(error)) == 0);
    printf("ok: %s failure -> reconnect -> packet with fresh timestamps/parameters -> flush\n",
           argv[3]);
    result = 0;

fail:
    vtr_buffer_free(&packet);
    vtr_client_destroy(&client);
    return result;
}
