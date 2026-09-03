/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "vtremote/client.h"

#include <stdio.h>
#include <string.h>

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
    char error[256] = {0};

    if (argc != 3) {
        fprintf(stderr, "usage: %s FAIL_ENDPOINT SUCCESS_ENDPOINT\n", argv[0]);
        return 2;
    }

    vtr_client_init(&client);
    config = make_config(argv[1], "wrong-token");
    if (vtr_client_connect(&client, &config, error, sizeof(error)) >= 0) {
        fprintf(stderr, "expected the first handshake to fail\n");
        vtr_client_destroy(&client);
        return 1;
    }

    config = make_config(argv[2], "");
    if (vtr_client_connect(&client, &config, error, sizeof(error)) < 0) {
        fprintf(stderr, "reconnect failed: %s\n", error);
        vtr_client_destroy(&client);
        return 1;
    }

    vtr_client_destroy(&client);
    puts("ok: handshake failure -> reconnect -> destroy");
    return 0;
}
