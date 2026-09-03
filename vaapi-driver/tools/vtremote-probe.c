/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define _POSIX_C_SOURCE 200809L
#include "vtremote/client.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef VTREMOTE_VERSION
#define VTREMOTE_VERSION "dev"
#endif

static const char *compression_name(VTRWireCompression compression) {
    switch (compression) {
        case VTR_WIRE_COMPRESSION_NONE: return "none";
        case VTR_WIRE_COMPRESSION_LZ4: return "lz4";
        case VTR_WIRE_COMPRESSION_ZSTD: return "zstd";
        case VTR_WIRE_COMPRESSION_AUTO: return "auto";
        default: return "invalid";
    }
}

static int parse_compression(const char *value, VTRWireCompression *result) {
    if (!strcmp(value, "none")) *result = VTR_WIRE_COMPRESSION_NONE;
    else if (!strcmp(value, "lz4")) *result = VTR_WIRE_COMPRESSION_LZ4;
    else if (!strcmp(value, "zstd")) *result = VTR_WIRE_COMPRESSION_ZSTD;
    else if (!strcmp(value, "auto")) *result = VTR_WIRE_COMPRESSION_AUTO;
    else return -1;
    return 0;
}

static void usage(const char *program) {
    fprintf(stderr,
            "usage: %s [--host HOST:PORT] [--token TOKEN] "
            "[--codec h264|hevc] [--p010] "
            "[--wire none|lz4|zstd|auto] [--version]\n",
            program);
}

int main(int argc, char **argv) {
    const char *host = getenv("VTREMOTE_HOST");
    const char *token = getenv("VTREMOTE_TOKEN");
    const char *codec = "h264";
    VTRPixelFormat pixel_format = VTR_PIXFMT_NV12;
    VTRWireCompression wire_compression = VTR_WIRE_COMPRESSION_AUTO;
    VTRClientConfig config;
    VTRClient client;
    char error[512] = {0};
    int i;
    int rc;

    if (!token) token = "";
    for (i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--host") && i + 1 < argc) host = argv[++i];
        else if (!strcmp(argv[i], "--token") && i + 1 < argc) token = argv[++i];
        else if (!strcmp(argv[i], "--codec") && i + 1 < argc) codec = argv[++i];
        else if (!strcmp(argv[i], "--p010")) pixel_format = VTR_PIXFMT_P010;
        else if (!strcmp(argv[i], "--wire") && i + 1 < argc) {
            if (parse_compression(argv[++i], &wire_compression) < 0) {
                fprintf(stderr, "unsupported wire compression: %s\n", argv[i]);
                return 2;
            }
        } else if (!strcmp(argv[i], "--version")) {
            printf("vtremote-probe %s\n", VTREMOTE_VERSION);
            return 0;
        }
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            usage(argv[0]);
            return 0;
        } else {
            usage(argv[0]);
            return 2;
        }
    }
    if (!host || !*host) {
        fprintf(stderr, "--host or VTREMOTE_HOST is required\n");
        return 2;
    }
    if (strcmp(codec, "h264") && strcmp(codec, "hevc")) {
        fprintf(stderr, "unsupported codec: %s\n", codec);
        return 2;
    }
    if (pixel_format == VTR_PIXFMT_P010 && strcmp(codec, "hevc")) {
        fprintf(stderr, "P010 probe requires --codec hevc\n");
        return 2;
    }

    memset(&config, 0, sizeof(config));
    config.endpoint = host;
    config.token = token;
    config.codec = codec;
    config.width = 64;
    config.height = 64;
    config.pixel_format = pixel_format;
    config.frame_rate_num = 30;
    config.frame_rate_den = 1;
    config.bit_rate = 1000000;
    config.max_rate = 1000000;
    config.gop_size = 30;
    config.max_b_frames = 0;
    config.profile = !strcmp(codec, "h264") ? 100
                     : (pixel_format == VTR_PIXFMT_P010 ? 2 : 1);
    config.realtime = 1;
    config.constant_bit_rate = 0;
    config.timeout_ms = 5000;
    config.wire_compression = wire_compression;

    vtr_client_init(&client);
    rc = vtr_client_connect(&client, &config, error, sizeof(error));
    if (rc < 0) {
        fprintf(stderr, "probe failed: %s (%d)\n", error[0] ? error : "unknown", rc);
        vtr_client_destroy(&client);
        return 1;
    }
    printf("connected: endpoint=%s codec=%s pixel_format=%s wire=%s caps=0x%llx\n",
           host, codec, pixel_format == VTR_PIXFMT_P010 ? "p010" : "nv12",
           compression_name(client.wire_compression),
           (unsigned long long)client.server_caps);
    rc = vtr_client_flush(&client, error, sizeof(error));
    vtr_client_destroy(&client);
    if (rc < 0) {
        fprintf(stderr, "flush failed: %s (%d)\n", error[0] ? error : "unknown", rc);
        return 1;
    }
    return 0;
}
