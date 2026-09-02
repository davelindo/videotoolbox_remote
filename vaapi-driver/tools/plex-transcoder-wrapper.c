/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DEFAULT_REAL_TRANSCODER "/usr/lib/plexmediaserver/Plex Transcoder.real"
#define DEFAULT_BSF_LIBRARY "/opt/vtremote-vaapi/lib/vtremote-plex-bsf.so"

typedef struct RemoteGraph {
    int option_index;
    char *input_map;
    char *output_map;
    unsigned width;
    unsigned height;
} RemoteGraph;

static bool env_enabled(const char *name)
{
    const char *value = getenv(name);
    return value != NULL && strcmp(value, "1") == 0;
}

static bool has_environment_value(const char *name)
{
    const char *value = getenv(name);
    return value != NULL && *value != '\0';
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

static bool parse_positive_uint(const char *text, size_t length,
                                unsigned *value)
{
    unsigned parsed = 0;
    size_t index;

    if (length == 0 || value == NULL) {
        return false;
    }
    for (index = 0; index < length; ++index) {
        unsigned digit;
        if (text[index] < '0' || text[index] > '9') {
            return false;
        }
        digit = (unsigned)(text[index] - '0');
        if (parsed > (100000U - digit) / 10U) {
            return false;
        }
        parsed = parsed * 10U + digit;
    }
    if (parsed == 0) {
        return false;
    }
    *value = parsed;
    return true;
}

static bool parse_scale_options(const char *start, const char *end,
                                unsigned *width, unsigned *height)
{
    const char *cursor = start;
    bool saw_width = false;
    bool saw_height = false;
    bool saw_format = false;

    while (cursor < end) {
        const char *separator = memchr(cursor, ':', (size_t)(end - cursor));
        const char *token_end = separator != NULL ? separator : end;
        size_t token_length = (size_t)(token_end - cursor);

        if (token_length > 2 && strncmp(cursor, "w=", 2) == 0) {
            if (saw_width ||
                !parse_positive_uint(cursor + 2, token_length - 2, width)) {
                return false;
            }
            saw_width = true;
        } else if (token_length > 2 && strncmp(cursor, "h=", 2) == 0) {
            if (saw_height ||
                !parse_positive_uint(cursor + 2, token_length - 2, height)) {
                return false;
            }
            saw_height = true;
        } else if (token_length == strlen("format=nv12") &&
                   strncmp(cursor, "format=nv12", token_length) == 0) {
            if (saw_format) {
                return false;
            }
            saw_format = true;
        } else {
            return false;
        }
        cursor = separator != NULL ? separator + 1 : end;
    }
    return saw_width && saw_height && saw_format;
}

/* Plex 1.43 emits this exact graph for its ordinary VA-API resize path:
 *   [input]hwupload[a];[a]scale_vaapi=w=W:h=H:format=nv12[b];[b]hwupload[out]
 * The packet filter replaces the whole graph, so retain only its source map
 * and requested output geometry. */
static bool parse_remote_graph(const char *graph, RemoteGraph *parsed)
{
    const char *input_label;
    const char *input_close;
    const char *first_upload;
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

    if (graph == NULL || parsed == NULL || graph[0] != '[') {
        return false;
    }
    input_label = graph + 1;
    input_close = strchr(input_label, ']');
    if (input_close == NULL) {
        return false;
    }
    first_upload = input_close + 1;
    if (strncmp(first_upload, "hwupload[", strlen("hwupload[")) != 0) {
        return false;
    }
    first_label = first_upload + strlen("hwupload[");
    first_close = strchr(first_label, ']');
    if (first_close == NULL || first_close[1] != ';' || first_close[2] != '[') {
        return false;
    }
    scale_label = first_close + 3;
    scale_label_close = strchr(scale_label, ']');
    if (scale_label_close == NULL ||
        !labels_match(first_label, (size_t)(first_close - first_label),
                      scale_label, (size_t)(scale_label_close - scale_label)) ||
        strncmp(scale_label_close + 1, scale_prefix, strlen(scale_prefix)) != 0) {
        return false;
    }
    options = scale_label_close + 1 + strlen(scale_prefix);
    options_end = strchr(options, '[');
    if (options_end == NULL ||
        !parse_scale_options(options, options_end,
                             &parsed->width, &parsed->height)) {
        return false;
    }
    second_label = options_end + 1;
    second_close = strchr(second_label, ']');
    if (second_close == NULL || second_close[1] != ';' ||
        second_close[2] != '[') {
        return false;
    }
    second_upload_label = second_close + 3;
    second_upload_close = strchr(second_upload_label, ']');
    if (second_upload_close == NULL ||
        !labels_match(second_label, (size_t)(second_close - second_label),
                      second_upload_label,
                      (size_t)(second_upload_close - second_upload_label)) ||
        strncmp(second_upload_close + 1, "hwupload[", strlen("hwupload[")) != 0) {
        return false;
    }
    output_label = second_upload_close + 1 + strlen("hwupload[");
    output_close = strchr(output_label, ']');
    if (output_close == NULL || output_close[1] != '\0') {
        return false;
    }

    parsed->input_map = copy_range(input_label, input_close);
    parsed->output_map = copy_range(output_label, output_close);
    if (parsed->input_map == NULL || parsed->output_map == NULL) {
        free(parsed->input_map);
        free(parsed->output_map);
        parsed->input_map = NULL;
        parsed->output_map = NULL;
        return false;
    }
    return true;
}

static void free_remote_graph(RemoteGraph *graph)
{
    if (graph == NULL) {
        return;
    }
    free(graph->input_map);
    free(graph->output_map);
    memset(graph, 0, sizeof(*graph));
    graph->option_index = -1;
}

static bool is_option(const char *argument, const char *name)
{
    size_t length = strlen(name);
    return strcmp(argument, name) == 0 ||
           (strncmp(argument, name, length) == 0 && argument[length] == ':');
}

static bool is_hardware_option(const char *argument)
{
    return is_option(argument, "-hwaccel") ||
           is_option(argument, "-hwaccel_output_format") ||
           is_option(argument, "-hwaccel_device") ||
           strcmp(argument, "-init_hw_device") == 0 ||
           strcmp(argument, "-filter_hw_device") == 0;
}

static bool matches_stream_option(const char *argument, const char *base,
                                  const char *codec_option)
{
    const char *suffix = strchr(codec_option, ':');
    char candidate[64];
    int written;

    if (strcmp(argument, base) == 0) {
        return true;
    }
    if (suffix == NULL) {
        return strlen(argument) == strlen(base) + 2 &&
               strncmp(argument, base, strlen(base)) == 0 &&
               strcmp(argument + strlen(base), ":v") == 0;
    }
    written = snprintf(candidate, sizeof(candidate), "%s%s", base, suffix);
    if (written > 0 && (size_t)written < sizeof(candidate) &&
        strcmp(argument, candidate) == 0) {
        return true;
    }
    if (suffix[1] >= '0' && suffix[1] <= '9' &&
        (written = snprintf(candidate, sizeof(candidate), "%s:v%s",
                            base, suffix)) > 0 &&
        (size_t)written < sizeof(candidate) &&
        strcmp(argument, candidate) == 0) {
        return true;
    }
    return false;
}

static bool is_video_encoder_option(const char *argument,
                                    const char *codec_option)
{
    static const char *const names[] = {
        "-b", "-maxrate", "-bufsize", "-g", "-bf", "-pix_fmt",
        "-low_power", "-idr_interval", "-b_depth", "-async_depth",
        "-max_frame_size", "-rc_mode", "-qp", "-quality", "-coder",
        "-aud", "-sei", "-profile", "-level",
    };
    size_t index;

    for (index = 0; index < sizeof(names) / sizeof(names[0]); ++index) {
        if (matches_stream_option(argument, names[index], codec_option)) {
            return true;
        }
    }
    return false;
}

static bool is_codec_option(const char *argument)
{
    return is_option(argument, "-codec") || is_option(argument, "-c");
}

static int find_vaapi_encoder(int argc, char *const argv[])
{
    int index;

    for (index = 2; index < argc; ++index) {
        if ((strcmp(argv[index], "h264_vaapi") == 0 ||
             strcmp(argv[index], "hevc_vaapi") == 0) &&
            is_codec_option(argv[index - 1])) {
            return index;
        }
    }
    return -1;
}

static int find_supported_input_codec(char *const argv[], int encoder_index)
{
    int index;

    for (index = 2; index < encoder_index; ++index) {
        if ((strcmp(argv[index], "h264") == 0 ||
             strcmp(argv[index], "hevc") == 0) &&
            is_codec_option(argv[index - 1])) {
            return index;
        }
    }
    return -1;
}

static bool map_matches(const char *argument, const char *label)
{
    size_t length;

    if (argument == NULL || label == NULL || argument[0] != '[') {
        return false;
    }
    length = strlen(label);
    return strlen(argument) == length + 2 &&
           memcmp(argument + 1, label, length) == 0 &&
           argument[length + 1] == ']';
}

static const char *last_stream_option(int argc, char *const argv[],
                                      const char *base,
                                      const char *codec_option)
{
    const char *value = NULL;
    int index;

    for (index = 1; index + 1 < argc; ++index) {
        if (matches_stream_option(argv[index], base, codec_option)) {
            value = argv[index + 1];
        }
    }
    return value;
}

static bool safe_option_value(const char *value)
{
    return value != NULL && *value != '\0' &&
           strspn(value, "0123456789.kKmMgG-") == strlen(value);
}

static int append_filter_option(char *buffer, size_t size, size_t *used,
                                const char *name, const char *value)
{
    int written;

    if (!safe_option_value(value)) {
        return 0;
    }
    written = snprintf(buffer + *used, size - *used, ":%s=%s", name, value);
    if (written < 0 || (size_t)written >= size - *used) {
        return -1;
    }
    *used += (size_t)written;
    return 0;
}

static char *make_filter_argument(int argc, char *const argv[],
                                  const RemoteGraph *graph,
                                  const char *encoder,
                                  const char *codec_option)
{
    char *argument = malloc(1024);
    const char *output_codec = strcmp(encoder, "hevc_vaapi") == 0
                                   ? "hevc" : "h264";
    size_t used;
    int written;

    if (argument == NULL) {
        return NULL;
    }
    written = snprintf(argument, 1024,
                       "vtremote_transcode=vt_remote_out_codec=%s"
                       ":vt_remote_out_width=%u:vt_remote_out_height=%u"
                       ":vt_remote_scale_mode=stretch:vt_remote_pix_fmt=1"
                       ":vt_remote_decode_async=1"
                       ":vt_remote_decode_reorder_depth=2"
                       ":vt_remote_inflight=16",
                       output_codec, graph->width, graph->height);
    if (written < 0 || written >= 1024) {
        free(argument);
        return NULL;
    }
    used = (size_t)written;
    if (append_filter_option(argument, 1024, &used, "vt_remote_bitrate",
                             last_stream_option(argc, argv, "-b",
                                                codec_option)) < 0 ||
        append_filter_option(argument, 1024, &used, "vt_remote_maxrate",
                             last_stream_option(argc, argv, "-maxrate",
                                                codec_option)) < 0 ||
        append_filter_option(argument, 1024, &used, "vt_remote_gop",
                             last_stream_option(argc, argv, "-g",
                                                codec_option)) < 0 ||
        append_filter_option(argument, 1024, &used, "vt_remote_max_b_frames",
                             last_stream_option(argc, argv, "-bf",
                                                codec_option)) < 0) {
        free(argument);
        return NULL;
    }
    return argument;
}

static char *make_bsf_option(const char *codec_option)
{
    const char *suffix = strchr(codec_option, ':');
    size_t required = strlen("-bsf") + (suffix != NULL ? strlen(suffix) : 2) + 1;
    char *option = malloc(required);

    if (option == NULL) {
        return NULL;
    }
    if (suffix != NULL) {
        snprintf(option, required, "-bsf%s", suffix);
    } else {
        snprintf(option, required, "-bsf:v");
    }
    return option;
}

static int set_preload(const char *library)
{
    const char *existing = getenv("LD_PRELOAD");
    char *value;
    size_t required;
    int result;

    if (existing == NULL || *existing == '\0') {
        return setenv("LD_PRELOAD", library, 1);
    }
    required = strlen(library) + strlen(existing) + 2;
    value = malloc(required);
    if (value == NULL) {
        errno = ENOMEM;
        return -1;
    }
    snprintf(value, required, "%s:%s", library, existing);
    result = setenv("LD_PRELOAD", value, 1);
    free(value);
    return result;
}

int main(int argc, char *argv[])
{
    const char *real_transcoder = getenv("VTREMOTE_PLEX_TRANSCODER_REAL");
    const char *bsf_library = getenv("VTREMOTE_PLEX_BSF_LIBRARY");
    bool test_mode = env_enabled("VTREMOTE_PLEX_WRAPPER_TEST");
    char **rewritten_argv;
    int output_index = 0;
    int encoder_index;
    int input_codec_index;
    int input_index;
    bool transformed = false;
    bool unsupported_graph = false;
    RemoteGraph graph = {.option_index = -1};
    char *filter_argument = NULL;
    char *bsf_option = NULL;

    if (real_transcoder == NULL || *real_transcoder == '\0') {
        real_transcoder = DEFAULT_REAL_TRANSCODER;
    }
    if (bsf_library == NULL || *bsf_library == '\0') {
        bsf_library = DEFAULT_BSF_LIBRARY;
    }
    rewritten_argv = calloc((size_t)argc + 8, sizeof(*rewritten_argv));
    if (rewritten_argv == NULL) {
        fprintf(stderr, "vtremote Plex wrapper: allocation failed\n");
        return 70;
    }

    encoder_index = find_vaapi_encoder(argc, argv);
    input_codec_index = find_supported_input_codec(argv, encoder_index);
    if (env_enabled("VTREMOTE_PLEX_REMOTE_TRANSCODE") &&
        has_environment_value("VTREMOTE_HOST") &&
        (test_mode || access(bsf_library, R_OK) == 0) &&
        encoder_index > 0 && input_codec_index > 0) {
        for (input_index = 1; input_index + 1 < argc; ++input_index) {
            if (strcmp(argv[input_index], "-filter_complex") != 0) {
                continue;
            }

            if (graph.option_index < 0) {
                graph.option_index = input_index;
                if (parse_remote_graph(argv[input_index + 1], &graph)) {
                    continue;
                }
                free_remote_graph(&graph);
            } else {
                RemoteGraph duplicate = {.option_index = input_index};

                if (parse_remote_graph(argv[input_index + 1], &duplicate)) {
                    free_remote_graph(&duplicate);
                    unsupported_graph = true;
                    break;
                }
            }
            if (strstr(argv[input_index + 1], "_vaapi") != NULL ||
                strstr(argv[input_index + 1], "hwupload") != NULL) {
                unsupported_graph = true;
                break;
            }
        }
        if (!unsupported_graph && graph.option_index >= 0) {
            filter_argument = make_filter_argument(argc, argv, &graph,
                                                   argv[encoder_index],
                                                   argv[encoder_index - 1]);
            bsf_option = make_bsf_option(argv[encoder_index - 1]);
            if (filter_argument != NULL && bsf_option != NULL) {
                transformed = true;
            } else {
                free(filter_argument);
                free(bsf_option);
                filter_argument = NULL;
                bsf_option = NULL;
            }
        }
    }

    rewritten_argv[output_index++] = (char *)real_transcoder;
    for (input_index = 1; input_index < argc; ++input_index) {
        if (transformed && input_index + 1 == input_codec_index) {
            ++input_index;
            continue;
        }
        if (transformed && is_hardware_option(argv[input_index])) {
            if (input_index + 1 < argc) {
                ++input_index;
            }
            continue;
        }
        if (transformed && is_video_encoder_option(
                               argv[input_index], argv[encoder_index - 1])) {
            if (input_index + 1 < argc) {
                ++input_index;
            }
            continue;
        }
        if (transformed && input_index == graph.option_index) {
            ++input_index;
            continue;
        }
        if (transformed && strcmp(argv[input_index], "-map") == 0 &&
            input_index + 1 < argc &&
            map_matches(argv[input_index + 1], graph.output_map)) {
            rewritten_argv[output_index++] = argv[input_index];
            rewritten_argv[output_index++] = graph.input_map;
            ++input_index;
            continue;
        }
        if (transformed && input_index + 1 == encoder_index) {
            rewritten_argv[output_index++] = argv[input_index];
            rewritten_argv[output_index++] = "copy";
            rewritten_argv[output_index++] = bsf_option;
            rewritten_argv[output_index++] = filter_argument;
            ++input_index;
            continue;
        }
        rewritten_argv[output_index++] = argv[input_index];
    }
    rewritten_argv[output_index] = NULL;

    if (transformed && set_preload(bsf_library) != 0) {
        fprintf(stderr, "vtremote Plex wrapper: cannot set LD_PRELOAD: %s\n",
                strerror(errno));
        free_remote_graph(&graph);
        free(filter_argument);
        free(bsf_option);
        free(rewritten_argv);
        return 70;
    }

    if (test_mode) {
        for (input_index = 0; input_index < output_index; ++input_index) {
            puts(rewritten_argv[input_index]);
        }
        if (transformed) {
            fprintf(stderr, "LD_PRELOAD=%s\n", getenv("LD_PRELOAD"));
        }
        free_remote_graph(&graph);
        free(filter_argument);
        free(bsf_option);
        free(rewritten_argv);
        return transformed ? 0 : 2;
    }

    execv(real_transcoder, rewritten_argv);
    fprintf(stderr, "vtremote Plex wrapper: cannot execute %s: %s\n",
            real_transcoder, strerror(errno));
    free_remote_graph(&graph);
    free(filter_argument);
    free(bsf_option);
    free(rewritten_argv);
    return 126;
}
