#define _POSIX_C_SOURCE 200809L
#include "vtremote/client.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return time.tv_sec + time.tv_nsec / 1e9;
}
int main(int argc, char **argv) {
    if (argc != 4)
        return 2;
    int depth = !strcmp(argv[2], "sync") ? 1 : 16;
    int count = atoi(argv[3]), sent = 0, received = 0, rc = 0, done = 0;
    char endpoint[64], error[512] = {0};
    snprintf(endpoint, sizeof(endpoint), "127.0.0.1:%s", argv[1]);
    VTRClient client;
    VTRClientConfig config = {0};
    config.endpoint = endpoint;
    config.codec = "h264";
    config.width = config.height = 64;
    config.pixel_format = VTR_PIXFMT_NV12;
    config.frame_rate_num = 60;
    config.frame_rate_den = 1;
    config.bit_rate = 1000000;
    config.gop_size = 60;
    config.profile = 100;
    config.timeout_ms = 2000;
    config.wire_compression = VTR_WIRE_COMPRESSION_NONE;
    vtr_client_init(&client);
    if (vtr_client_connect(&client, &config, error, sizeof(error)) < 0) {
        fprintf(stderr, "%s\n", error);
        return 3;
    }
    uint8_t y[4096], uv[2048];
    memset(y, 16, sizeof(y));
    memset(uv, 128, sizeof(uv));
    VTRFrame frame = {0};
    frame.duration = 1;
    frame.plane_count = 2;
    frame.planes[0] = (VTRFramePlane){y, 64, 64, sizeof(y)};
    frame.planes[1] = (VTRFramePlane){uv, 64, 32, sizeof(uv)};
    VTRBuffer packet;
    vtr_buffer_init(&packet);
    double started = now();
    while (received < count && rc >= 0) {
        while (sent < count && sent - received < depth) {
            frame.pts = sent;
            rc = vtr_client_send_frame(&client, &frame, error, sizeof(error));
            if (rc < 0)
                break;
            ++sent;
        }
        if (rc < 0)
            break;
        int64_t pts, dts;
        uint32_t flags;
        if (!strcmp(argv[2], "poll")) {
            do {
                rc = vtr_client_receive_packet_timeout(&client, &packet, &pts, &dts, &flags, error,
                                                       sizeof(error), 5);
                assert(now() - started < 10);
            } while (rc == -EAGAIN);
        } else {
            rc = vtr_client_receive_packet(&client, &packet, &pts, &dts, &flags, error,
                                           sizeof(error));
        }
        if (rc < 0)
            break;
        if (pts != received || dts != received || !packet.size) {
            rc = -1;
            break;
        }
        ++received;
    }
    if (rc >= 0) {
        rc = vtr_client_flush(&client, error, sizeof(error));
        done = rc == 0;
    }
    double seconds = now() - started;
    printf("{\"mode\":\"%s\",\"frames\":%d,\"seconds\":%.6f,\"fps\":%.3f,\"done\":%s}\n", argv[2],
           received, seconds, received / seconds, done ? "true" : "false");
    if (rc < 0)
        fprintf(stderr, "%s\n", error);
    if (rc < 0 && rc != -EAGAIN)
        assert(!client.connected && client.fd < 0);
    vtr_buffer_free(&packet);
    vtr_client_destroy(&client);
    return !done || received != count;
}
