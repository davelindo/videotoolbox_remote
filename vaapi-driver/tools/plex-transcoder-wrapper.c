/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DEFAULT_REAL_TRANSCODER "/usr/lib/plexmediaserver/Plex Transcoder.real"
#define DEFAULT_RENDER_DEVICE "/dev/dri/renderD128"
#define DEFAULT_DRIVERS_PATH "/opt/vtremote-vaapi/lib/dri"

static bool env_enabled(const char *name)
{
    const char *value = getenv(name);
    return value != NULL && strcmp(value, "1") == 0;
}

static void write_audit_marker(void)
{
    static const char marker[] = "software-decode-remote-encode\n";
    const char *path = getenv("VTREMOTE_PLEX_AUDIT_FILE");
    int fd;
    ssize_t written;

    if (path == NULL || *path == '\0') {
        return;
    }
    fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (fd < 0) {
        return;
    }
    written = write(fd, marker, sizeof(marker) - 1);
    (void)written;
    (void)close(fd);
}

static bool is_input_hwaccel_option(const char *argument)
{
    static const char *const prefixes[] = {
        "-hwaccel:",
        "-hwaccel_output_format:",
        "-hwaccel_device:",
    };
    size_t index;

    for (index = 0; index < sizeof(prefixes) / sizeof(prefixes[0]); ++index) {
        if (strncmp(argument, prefixes[index], strlen(prefixes[index])) == 0) {
            return true;
        }
    }
    return false;
}

static bool has_vaapi_encoder(int argc, char *const argv[])
{
    int index;

    for (index = 1; index < argc; ++index) {
        if (strcmp(argv[index], "h264_vaapi") == 0 ||
            strcmp(argv[index], "hevc_vaapi") == 0) {
            return true;
        }
    }
    return false;
}

static bool has_option_with_value(int argc, char *const argv[], const char *option)
{
    int index;

    for (index = 1; index + 1 < argc; ++index) {
        if (strcmp(argv[index], option) == 0) {
            return true;
        }
    }
    return false;
}

static char *copy_range(const char *start, const char *end)
{
    size_t length = (size_t)(end - start);
    char *copy = malloc(length + 1);

    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, start, length);
    copy[length] = '\0';
    return copy;
}

static bool labels_match(const char *first, size_t first_length,
                         const char *second, size_t second_length)
{
    return first_length == second_length &&
           memcmp(first, second, first_length) == 0;
}

static char *rewrite_scale_options(const char *start, const char *end,
                                   char **format_out)
{
    const char *cursor = start;
    char *scale_options = calloc((size_t)(end - start) + 1, 1);
    size_t output_length = 0;

    if (scale_options == NULL) {
        return NULL;
    }
    *format_out = NULL;

    while (cursor < end) {
        const char *separator = memchr(cursor, ':', (size_t)(end - cursor));
        const char *token_end = separator != NULL ? separator : end;
        size_t token_length = (size_t)(token_end - cursor);

        if (token_length > strlen("format=") &&
            strncmp(cursor, "format=", strlen("format=")) == 0) {
            free(*format_out);
            *format_out = copy_range(cursor + strlen("format="), token_end);
            if (*format_out == NULL) {
                free(scale_options);
                return NULL;
            }
        } else {
            if (output_length != 0) {
                scale_options[output_length++] = ':';
            }
            memcpy(scale_options + output_length, cursor, token_length);
            output_length += token_length;
            scale_options[output_length] = '\0';
        }
        cursor = separator != NULL ? separator + 1 : end;
    }

    if (output_length == 0 || *format_out == NULL || **format_out == '\0') {
        free(scale_options);
        free(*format_out);
        *format_out = NULL;
        return NULL;
    }
    return scale_options;
}

/*
 * Plex 1.43 emits this graph for a full VA-API pipeline:
 *   [in]hwupload[a];[a]scale_vaapi=...:format=nv12[b];[b]hwupload[out]
 *
 * VTRemote is encode-only, so retain decode and scale in system memory and
 * upload exactly once immediately before the VA-API encoder.
 */
static char *rewrite_filter_graph(const char *graph)
{
    const char *first_upload = strstr(graph, "hwupload[");
    const char *first_label;
    const char *first_close;
    const char *scale_label;
    const char *scale_label_close;
    const char *scale_prefix = "scale_vaapi=";
    const char *options;
    const char *options_end;
    const char *second_label;
    const char *second_close;
    const char *second_upload_label;
    const char *second_upload_close;
    const char *output_label;
    const char *output_close;
    char *scale_options = NULL;
    char *format = NULL;
    char *rewritten = NULL;
    size_t required;

    if (first_upload == NULL) {
        return NULL;
    }
    first_label = first_upload + strlen("hwupload[");
    first_close = strchr(first_label, ']');
    if (first_close == NULL || first_close[1] != ';' || first_close[2] != '[') {
        return NULL;
    }

    scale_label = first_close + 3;
    scale_label_close = strchr(scale_label, ']');
    if (scale_label_close == NULL ||
        !labels_match(first_label, (size_t)(first_close - first_label),
                      scale_label, (size_t)(scale_label_close - scale_label)) ||
        strncmp(scale_label_close + 1, scale_prefix, strlen(scale_prefix)) != 0) {
        return NULL;
    }

    options = scale_label_close + 1 + strlen(scale_prefix);
    options_end = strchr(options, '[');
    if (options_end == NULL) {
        return NULL;
    }
    second_label = options_end + 1;
    second_close = strchr(second_label, ']');
    if (second_close == NULL || second_close[1] != ';' || second_close[2] != '[') {
        return NULL;
    }

    second_upload_label = second_close + 3;
    second_upload_close = strchr(second_upload_label, ']');
    if (second_upload_close == NULL ||
        !labels_match(second_label, (size_t)(second_close - second_label),
                      second_upload_label,
                      (size_t)(second_upload_close - second_upload_label)) ||
        strncmp(second_upload_close + 1, "hwupload[", strlen("hwupload[")) != 0) {
        return NULL;
    }

    output_label = second_upload_close + 1 + strlen("hwupload[");
    output_close = strchr(output_label, ']');
    if (output_close == NULL || output_close[1] != '\0') {
        return NULL;
    }

    scale_options = rewrite_scale_options(options, options_end, &format);
    if (scale_options == NULL) {
        return NULL;
    }

    required = (size_t)(first_upload - graph) + strlen("scale=") +
               strlen(scale_options) + strlen(",format=") + strlen(format) +
               strlen(",hwupload[") + (size_t)(output_close - output_label) + 2;
    rewritten = malloc(required);
    if (rewritten != NULL) {
        snprintf(rewritten, required, "%.*sscale=%s,format=%s,hwupload[%.*s]",
                 (int)(first_upload - graph), graph, scale_options, format,
                 (int)(output_close - output_label), output_label);
    }

    free(scale_options);
    free(format);
    return rewritten;
}

static char *make_device_argument(void)
{
    const char *device = getenv("VTREMOTE_PLEX_RENDER_DEVICE");
    const char *driver = getenv("VTREMOTE_PLEX_VAAPI_DRIVER");
    size_t required;
    char *argument;

    if (device == NULL || *device == '\0') {
        device = DEFAULT_RENDER_DEVICE;
    }
    if (driver == NULL || *driver == '\0') {
        driver = "vtremote";
    }
    required = strlen("vaapi=vaapi:") + strlen(device) + strlen(",driver=") +
               strlen(driver) + 1;
    argument = malloc(required);
    if (argument != NULL) {
        snprintf(argument, required, "vaapi=vaapi:%s,driver=%s", device, driver);
    }
    return argument;
}

static void free_owned_items(char **owned, size_t count)
{
    size_t index;
    for (index = 0; index < count; ++index) {
        free(owned[index]);
        owned[index] = NULL;
    }
}

static void free_owned(char **owned, size_t count)
{
    free_owned_items(owned, count);
    free(owned);
}

int main(int argc, char *argv[])
{
    const char *real_transcoder = getenv("VTREMOTE_PLEX_TRANSCODER_REAL");
    char **rewritten_argv;
    char **replacements;
    char **owned;
    size_t owned_count = 0;
    int input_index;
    int output_index = 0;
    bool transformed = false;
    bool unsupported_graph = false;

    if (real_transcoder == NULL || *real_transcoder == '\0') {
        real_transcoder = DEFAULT_REAL_TRANSCODER;
    }

    rewritten_argv = calloc((size_t)argc + 1, sizeof(*rewritten_argv));
    replacements = calloc((size_t)argc + 1, sizeof(*replacements));
    owned = calloc((size_t)argc + 1, sizeof(*owned));
    if (rewritten_argv == NULL || replacements == NULL || owned == NULL) {
        fprintf(stderr, "vtremote Plex wrapper: allocation failed\n");
        free(rewritten_argv);
        free(replacements);
        free(owned);
        return 70;
    }

    rewritten_argv[output_index++] = (char *)real_transcoder;
    if (env_enabled("VTREMOTE_PLEX_SOFTWARE_PIPELINE") &&
        has_vaapi_encoder(argc, argv) &&
        has_option_with_value(argc, argv, "-init_hw_device")) {
        for (input_index = 1; input_index < argc; ++input_index) {
            char *filter;

            if (strcmp(argv[input_index], "-filter_complex") != 0 ||
                input_index + 1 >= argc) {
                continue;
            }
            filter = rewrite_filter_graph(argv[input_index + 1]);
            if (filter != NULL) {
                replacements[input_index + 1] = filter;
                owned[owned_count++] = filter;
                transformed = true;
            } else if (strstr(argv[input_index + 1], "_vaapi") != NULL ||
                       strstr(argv[input_index + 1], "hwupload") != NULL) {
                unsupported_graph = true;
                break;
            }
        }
    }
    if (unsupported_graph) {
        free_owned_items(owned, owned_count);
        owned_count = 0;
        memset(replacements, 0, ((size_t)argc + 1) * sizeof(*replacements));
        transformed = false;
    }

    for (input_index = 1; input_index < argc; ++input_index) {
        char *replacement = NULL;

        if (transformed && is_input_hwaccel_option(argv[input_index])) {
            if (input_index + 1 < argc) {
                ++input_index;
            }
            continue;
        }
        if (transformed && strcmp(argv[input_index], "-init_hw_device") == 0 &&
            input_index + 1 < argc) {
            replacement = make_device_argument();
            if (replacement == NULL) {
                fprintf(stderr, "vtremote Plex wrapper: allocation failed\n");
                free_owned(owned, owned_count);
                free(replacements);
                free(rewritten_argv);
                return 70;
            }
            owned[owned_count++] = replacement;
            rewritten_argv[output_index++] = argv[input_index];
            rewritten_argv[output_index++] = replacement;
            ++input_index;
            continue;
        }
        if (transformed && strcmp(argv[input_index], "-filter_complex") == 0 &&
            input_index + 1 < argc) {
            replacement = replacements[input_index + 1];
            rewritten_argv[output_index++] = argv[input_index];
            if (replacement != NULL) {
                rewritten_argv[output_index++] = replacement;
            } else {
                rewritten_argv[output_index++] = argv[input_index + 1];
            }
            ++input_index;
            continue;
        }
        rewritten_argv[output_index++] = argv[input_index];
    }
    rewritten_argv[output_index] = NULL;

    if (transformed) {
        const char *drivers_path = getenv("VTREMOTE_PLEX_DRIVERS_PATH");
        if (drivers_path == NULL || *drivers_path == '\0') {
            drivers_path = DEFAULT_DRIVERS_PATH;
        }
        if (setenv("LIBVA_DRIVERS_PATH", drivers_path, 1) != 0) {
            fprintf(stderr, "vtremote Plex wrapper: cannot set driver path: %s\n",
                    strerror(errno));
            free_owned(owned, owned_count);
            free(replacements);
            free(rewritten_argv);
            return 70;
        }
        write_audit_marker();
    }

    if (env_enabled("VTREMOTE_PLEX_WRAPPER_TEST")) {
        for (input_index = 0; input_index < output_index; ++input_index) {
            puts(rewritten_argv[input_index]);
        }
        free_owned(owned, owned_count);
        free(replacements);
        free(rewritten_argv);
        return transformed ? 0 : 2;
    }

    execv(real_transcoder, rewritten_argv);
    fprintf(stderr, "vtremote Plex wrapper: cannot execute %s: %s\n",
            real_transcoder, strerror(errno));
    free_owned(owned, owned_count);
    free(replacements);
    free(rewritten_argv);
    return 126;
}
