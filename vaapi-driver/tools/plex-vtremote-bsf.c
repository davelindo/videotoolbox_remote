/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "libavcodec/bsf.h"
#include "libavcodec/bsf_internal.h"
#include "libavcodec/avcodec.h"
#include "libavcodec/packet.h"
#include "libavutil/error.h"
#include "libavutil/opt.h"

#include "plex-ffmpeg-compat.h"

extern const FFBitStreamFilter ff_vtremote_transcode_bsf;

typedef int (*parse_bsf_fn)(const char *, AVBSFContext **);

/* FFmpeg 6.1 keeps its input packet immediately after the public context.
 * The helper that moves this packet is hidden in Plex's libavcodec, so the
 * injected filter supplies the equivalent operation itself. */
typedef struct PlexFFBSFContext {
    AVBSFContext public_context;
    AVPacket *buffer_packet;
    int eof;
} PlexFFBSFContext;

int ff_bsf_get_packet_ref(AVBSFContext *context, AVPacket *packet)
{
    PlexFFBSFContext *internal = (PlexFFBSFContext *)context;

    if (internal->eof) {
        return AVERROR_EOF;
    }
    if (internal->buffer_packet == NULL ||
        (internal->buffer_packet->data == NULL &&
         internal->buffer_packet->side_data_elems == 0)) {
        return AVERROR(EAGAIN);
    }
    av_packet_move_ref(packet, internal->buffer_packet);
    return 0;
}

static void write_audit_marker(void)
{
    static const char marker[] = "remote-decode-scale-encode\n";
    const char *path = getenv("VTREMOTE_PLEX_AUDIT_FILE");
    int descriptor;
    ssize_t written;

    if (path == NULL || *path == '\0') {
        return;
    }
    descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (descriptor < 0) {
        return;
    }
    written = write(descriptor, marker, sizeof(marker) - 1);
    (void)written;
    (void)close(descriptor);
}

static int injected_filter_init(AVBSFContext *context)
{
    int result = ff_vtremote_transcode_bsf.init(context);

    if (result >= 0) {
        write_audit_marker();
    }
    return result;
}

static FFBitStreamFilter plex_filter;
static pthread_once_t plex_filter_once = PTHREAD_ONCE_INIT;
static parse_bsf_fn original_parse_bsf;
static pthread_once_t original_parse_once = PTHREAD_ONCE_INIT;

static void initialize_injected_filter(void)
{
    plex_filter = ff_vtremote_transcode_bsf;
    plex_filter.init = injected_filter_init;
}

static const FFBitStreamFilter *injected_filter(void)
{
    (void)pthread_once(&plex_filter_once, initialize_injected_filter);
    return &plex_filter;
}

static void resolve_original_parse_bsf(void)
{
    void *symbol = dlsym(RTLD_NEXT, "av_bsf_list_parse_str");

    memcpy(&original_parse_bsf, &symbol, sizeof(original_parse_bsf));
}

static int apply_environment_options(AVBSFContext *context)
{
    static const struct {
        const char *environment;
        const char *option;
    } mappings[] = {
        {"VTREMOTE_HOST", "vt_remote_host"},
        {"VTREMOTE_PORT", "vt_remote_port"},
        {"VTREMOTE_TOKEN", "vt_remote_token"},
        {"VTREMOTE_TIMEOUT_MS", "vt_remote_timeout_ms"},
    };
    size_t index;

    for (index = 0; index < sizeof(mappings) / sizeof(mappings[0]); ++index) {
        const char *value = getenv(mappings[index].environment);
        int result;

        if (value == NULL || *value == '\0') {
            continue;
        }
        result = av_opt_set(context->priv_data, mappings[index].option, value, 0);
        if (result < 0) {
            return result;
        }
    }
    return 0;
}

__attribute__((visibility("default")))
int av_bsf_list_parse_str(const char *filters, AVBSFContext **context)
{
    static const char filter_name[] = "vtremote_transcode";
    const char *options;
    int result;

    if (filters == NULL ||
        (strcmp(filters, filter_name) != 0 &&
         (strncmp(filters, filter_name, sizeof(filter_name) - 1) != 0 ||
          filters[sizeof(filter_name) - 1] != '='))) {
        (void)pthread_once(&original_parse_once, resolve_original_parse_bsf);
        if (original_parse_bsf == NULL) {
            return AVERROR(ENOSYS);
        }
        return original_parse_bsf(filters, context);
    }

    if (context == NULL) {
        return AVERROR(EINVAL);
    }
    if (!vtremote_plex_avcodec_version_supported(avcodec_version())) {
        return AVERROR(ENOTSUP);
    }
    *context = NULL;
    result = av_bsf_alloc(&injected_filter()->p, context);
    if (result < 0) {
        return result;
    }

    options = filters + sizeof(filter_name) - 1;
    if (*options == '=') {
        ++options;
    }
    if (*options != '\0') {
        result = av_set_options_string((*context)->priv_data, options, "=", ":");
        if (result < 0) {
            av_bsf_free(context);
            return result;
        }
    }
    result = apply_environment_options(*context);
    if (result < 0) {
        av_bsf_free(context);
        return result;
    }
    return 0;
}
