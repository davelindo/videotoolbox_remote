/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define _POSIX_C_SOURCE 200809L

#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#include "plex-ffmpeg-compat.h"

#define DEFAULT_REAL_TRANSCODER "/usr/lib/plexmediaserver/Plex Transcoder.real"
#define DEFAULT_BSF_LIBRARY "/opt/vtremote-vaapi/lib/vtremote-plex-bsf.so"
#define DEFAULT_AVCODEC_LIBRARY "/usr/lib/plexmediaserver/lib/libavcodec.so.60"

typedef unsigned (*avcodec_version_fn)(void);

typedef struct RemoteGraph {
    int option_index;
    char *input_map;
    char *output_map;
    unsigned width;
    unsigned height;
} RemoteGraph;

typedef struct RemoteEncoderOptions {
    char profile[16];
    char level[16];
    char entropy[8];
    char gop[32];
    char global_quality[16];
    bool constant_bit_rate;
    bool a53_cc;
    bool closed_gop;
} RemoteEncoderOptions;

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

static bool parse_version_component(const char **cursor, unsigned *value,
                                    bool final)
{
    char *end = NULL;
    unsigned long parsed;

    errno = 0;
    parsed = strtoul(*cursor, &end, 10);
    if (errno != 0 || end == *cursor || parsed > 255 ||
        (final ? *end != '\0' : *end != '.')) {
        return false;
    }
    *value = (unsigned)parsed;
    *cursor = final ? end : end + 1;
    return true;
}

static bool parse_avcodec_version(const char *text, uint32_t *version)
{
    const char *cursor = text;
    unsigned major;
    unsigned minor;
    unsigned micro;

    if (text == NULL || version == NULL ||
        !parse_version_component(&cursor, &major, false) ||
        !parse_version_component(&cursor, &minor, false) ||
        !parse_version_component(&cursor, &micro, true)) {
        return false;
    }
    *version = VTREMOTE_AV_VERSION_INT(major, minor, micro);
    return true;
}

static bool plex_runtime_supported(bool test_mode)
{
    const char *library = getenv("VTREMOTE_PLEX_AVCODEC_LIBRARY");
    uint32_t version;
    void *handle;
    void *symbol;
    avcodec_version_fn version_function = NULL;

    if (test_mode) {
        return parse_avcodec_version(
                   getenv("VTREMOTE_PLEX_TEST_AVCODEC_VERSION"), &version) &&
               vtremote_plex_avcodec_version_supported(version);
    }
    if (library == NULL || *library == '\0') {
        library = DEFAULT_AVCODEC_LIBRARY;
    }
    handle = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        return false;
    }
    symbol = dlsym(handle, "avcodec_version");
    memcpy(&version_function, &symbol, sizeof(version_function));
    if (version_function == NULL) {
        (void)dlclose(handle);
        return false;
    }
    version = version_function();
    (void)dlclose(handle);
    return vtremote_plex_avcodec_version_supported(version);
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

static bool is_direct_stream_specifier(const char *start, const char *end)
{
    const char *cursor = start;

    if (start == NULL || end == NULL || start >= end) {
        return false;
    }
    while (cursor < end && *cursor >= '0' && *cursor <= '9') {
        ++cursor;
    }
    if (cursor == start || cursor >= end || *cursor++ != ':') {
        return false;
    }
    start = cursor;
    while (cursor < end && *cursor >= '0' && *cursor <= '9') {
        ++cursor;
    }
    return cursor == end && cursor != start;
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

static bool parse_software_scale_options(const char *start, const char *end,
                                         unsigned *width, unsigned *height)
{
    const char *cursor = start;
    bool saw_width = false;
    bool saw_height = false;
    bool saw_divisibility = false;

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
        } else if (token_length == strlen("force_divisible_by=4") &&
                   strncmp(cursor, "force_divisible_by=4",
                           token_length) == 0) {
            if (saw_divisibility) {
                return false;
            }
            saw_divisibility = true;
        } else {
            return false;
        }
        cursor = separator != NULL ? separator + 1 : end;
    }
    return saw_width && saw_height && saw_divisibility;
}

/* Plex 1.43 emits this exact graph for its ordinary VA-API transcode path:
 *   [input]scale=w=W:h=H:force_divisible_by=4[a];
 *   [a]format=pix_fmts=nv12[b];[b]hwupload[out]
 * The packet filter replaces the whole graph, so retain only its source map
 * and requested output geometry. */
static bool parse_remote_graph(const char *graph, RemoteGraph *parsed)
{
    const char *input_label;
    const char *input_close;
    const char *scale_prefix = "scale=";
    const char *options;
    const char *options_end;
    const char *scale_output;
    const char *scale_output_close;
    const char *format_input;
    const char *format_input_close;
    const char *format_output;
    const char *format_output_close;
    const char *upload_input;
    const char *upload_input_close;
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
    if (!is_direct_stream_specifier(input_label, input_close)) {
        return false;
    }
    if (strncmp(input_close + 1, scale_prefix, strlen(scale_prefix)) != 0) {
        return false;
    }
    options = input_close + 1 + strlen(scale_prefix);
    options_end = strchr(options, '[');
    if (options_end == NULL ||
        !parse_software_scale_options(options, options_end,
                                      &parsed->width, &parsed->height)) {
        return false;
    }
    scale_output = options_end + 1;
    scale_output_close = strchr(scale_output, ']');
    if (scale_output_close == NULL || scale_output_close[1] != ';' ||
        scale_output_close[2] != '[') {
        return false;
    }
    format_input = scale_output_close + 3;
    format_input_close = strchr(format_input, ']');
    if (format_input_close == NULL ||
        !labels_match(scale_output,
                      (size_t)(scale_output_close - scale_output),
                      format_input,
                      (size_t)(format_input_close - format_input)) ||
        strncmp(format_input_close + 1, "format=pix_fmts=nv12[",
                strlen("format=pix_fmts=nv12[")) != 0) {
        return false;
    }
    format_output = format_input_close + 1 + strlen("format=pix_fmts=nv12[");
    format_output_close = strchr(format_output, ']');
    if (format_output_close == NULL || format_output_close[1] != ';' ||
        format_output_close[2] != '[') {
        return false;
    }
    upload_input = format_output_close + 3;
    upload_input_close = strchr(upload_input, ']');
    if (upload_input_close == NULL ||
        !labels_match(format_output,
                      (size_t)(format_output_close - format_output),
                      upload_input,
                      (size_t)(upload_input_close - upload_input)) ||
        strncmp(upload_input_close + 1, "hwupload[", strlen("hwupload[")) != 0) {
        return false;
    }
    output_label = upload_input_close + 1 + strlen("hwupload[");
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
        "-aud", "-sei", "-profile", "-level", "-force_key_frames",
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

static int find_unique_vaapi_encoder(int argc, char *const argv[])
{
    int found = -1;
    int index;

    for (index = 2; index < argc; ++index) {
        if ((strcmp(argv[index], "h264_vaapi") == 0 ||
             strcmp(argv[index], "hevc_vaapi") == 0) &&
            is_codec_option(argv[index - 1])) {
            if (found >= 0) {
                return -1;
            }
            found = index;
        }
    }
    return found;
}

static int find_unique_supported_input_codec(char *const argv[],
                                             int encoder_index)
{
    int found = -1;
    int index;

    for (index = 2; index < encoder_index; ++index) {
        if ((strcmp(argv[index], "h264") == 0 ||
             strcmp(argv[index], "hevc") == 0) &&
            is_codec_option(argv[index - 1])) {
            if (found >= 0) {
                return -1;
            }
            found = index;
        }
    }
    return found;
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

static int mapped_output_count(int argc, char *const argv[], const char *label)
{
    int count = 0;
    int index;

    for (index = 1; index + 1 < argc; ++index) {
        if (strcmp(argv[index], "-map") == 0 &&
            map_matches(argv[index + 1], label)) {
            ++count;
        }
    }
    return count;
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

static bool parse_unsigned_value(const char *text, unsigned maximum,
                                 unsigned *value)
{
    char *end = NULL;
    unsigned long parsed;

    if (text == NULL || *text == '\0' || value == NULL) {
        return false;
    }
    errno = 0;
    parsed = strtoul(text, &end, 10);
    if (errno != 0 || *end != '\0' || parsed > maximum) {
        return false;
    }
    *value = (unsigned)parsed;
    return true;
}

static bool parse_rate_value(const char *text, unsigned *value)
{
    char *end = NULL;
    double parsed;
    double multiplier = 1.0;

    if (text == NULL || *text == '\0' || value == NULL) {
        return false;
    }
    errno = 0;
    parsed = strtod(text, &end);
    if (errno != 0 || end == text || parsed < 0.0) {
        return false;
    }
    if (*end != '\0') {
        if (end[1] != '\0') {
            return false;
        }
        switch (*end) {
        case 'k':
        case 'K':
            multiplier = 1000.0;
            break;
        case 'm':
        case 'M':
            multiplier = 1000000.0;
            break;
        case 'g':
        case 'G':
            multiplier = 1000000000.0;
            break;
        default:
            return false;
        }
    }
    parsed *= multiplier;
    if (parsed > 2147483647.0) {
        return false;
    }
    *value = (unsigned)(parsed + 0.5);
    return true;
}

static bool translate_profile(const char *encoder, const char *value,
                              char *translated, size_t size)
{
    static const struct {
        const char *name;
        unsigned h264;
        unsigned hevc;
    } profiles[] = {
        {"baseline", 66, 0},
        {"constrained_baseline", 578, 0},
        {"main", 77, 1},
        {"high", 100, 0},
        {"constrained_high", 612, 0},
        {"main10", 0, 2},
    };
    bool hevc = strcmp(encoder, "hevc_vaapi") == 0;
    unsigned numeric;
    size_t index;

    if (value == NULL) {
        translated[0] = '\0';
        return true;
    }
    if (parse_unsigned_value(value, 65535, &numeric)) {
        if ((hevc && numeric != 1 && numeric != 2) ||
            (!hevc && numeric != 66 && numeric != 77 && numeric != 100 &&
             numeric != 578 && numeric != 612)) {
            return false;
        }
        (void)snprintf(translated, size, "%u", numeric);
        return true;
    }
    for (index = 0; index < sizeof(profiles) / sizeof(profiles[0]); ++index) {
        numeric = hevc ? profiles[index].hevc : profiles[index].h264;
        if (numeric != 0 && strcasecmp(value, profiles[index].name) == 0) {
            (void)snprintf(translated, size, "%u", numeric);
            return true;
        }
    }
    return false;
}

static bool translate_level(const char *value, char *translated, size_t size)
{
    char *end = NULL;
    double parsed;
    unsigned numeric;

    if (value == NULL || strcmp(value, "0") == 0 ||
        strcasecmp(value, "auto") == 0) {
        translated[0] = '\0';
        return true;
    }
    errno = 0;
    parsed = strtod(value, &end);
    if (errno != 0 || end == value || *end != '\0' || parsed <= 0.0 ||
        parsed > 255.0) {
        return false;
    }
    numeric = strchr(value, '.') != NULL
                  ? (unsigned)(parsed * 10.0 + 0.5)
                  : (unsigned)(parsed + 0.5);
    if (numeric != 13 && (numeric < 30 || numeric > 52)) {
        return false;
    }
    (void)snprintf(translated, size, "%u", numeric);
    return true;
}

static bool translate_entropy(const char *encoder, const char *value,
                              char *translated, size_t size)
{
    if (value == NULL) {
        translated[0] = '\0';
        return true;
    }
    if (strcmp(encoder, "h264_vaapi") != 0) {
        return false;
    }
    if (strcasecmp(value, "cabac") == 0 || strcasecmp(value, "ac") == 0 ||
        strcmp(value, "1") == 0) {
        (void)snprintf(translated, size, "2");
        return true;
    }
    if (strcasecmp(value, "cavlc") == 0 || strcasecmp(value, "vlc") == 0 ||
        strcmp(value, "0") == 0) {
        (void)snprintf(translated, size, "1");
        return true;
    }
    return false;
}

static bool translate_force_keyframes(const char *value, const char *rate,
                                      char *translated, size_t size)
{
    static const char prefix[] = "expr:gte(t,n_forced*";
    const char *seconds_text;
    char *seconds_end = NULL;
    char *rate_end = NULL;
    double seconds;
    double frames_per_second;
    unsigned frames;

    if (value == NULL) {
        translated[0] = '\0';
        return true;
    }
    if (*value == '\0' || strncmp(value, prefix, sizeof(prefix) - 1) != 0 ||
        value[strlen(value) - 1] != ')' || rate == NULL) {
        return false;
    }
    seconds_text = value + sizeof(prefix) - 1;
    errno = 0;
    seconds = strtod(seconds_text, &seconds_end);
    if (errno != 0 || seconds_end == seconds_text ||
        strcmp(seconds_end, ")") != 0 || seconds <= 0.0) {
        return false;
    }
    errno = 0;
    frames_per_second = strtod(rate, &rate_end);
    if (errno != 0 || rate_end == rate || *rate_end != '\0' ||
        frames_per_second <= 0.0) {
        return false;
    }
    if (seconds * frames_per_second > 100000.0) {
        return false;
    }
    frames = (unsigned)(seconds * frames_per_second + 0.5);
    if (frames == 0) {
        return false;
    }
    (void)snprintf(translated, size, "%u", frames);
    return true;
}

static bool translate_encoder_options(int argc, char *const argv[],
                                      const char *encoder,
                                      const char *codec_option,
                                      RemoteEncoderOptions *translated)
{
    const char *rc_mode = last_stream_option(argc, argv, "-rc_mode",
                                             codec_option);
    const char *qp = last_stream_option(argc, argv, "-qp", codec_option);
    const char *quality = last_stream_option(argc, argv, "-quality",
                                             codec_option);
    const char *force_keyframes = last_stream_option(
        argc, argv, "-force_key_frames", codec_option);
    const char *gop = last_stream_option(argc, argv, "-g", codec_option);
    const char *rate = last_stream_option(argc, argv, "-r", codec_option);
    const char *coder = last_stream_option(argc, argv, "-coder", codec_option);
    const char *sei = last_stream_option(argc, argv, "-sei", codec_option);
    const char *pixel_format = last_stream_option(argc, argv, "-pix_fmt",
                                                  codec_option);
    const char *bitrate = last_stream_option(argc, argv, "-b", codec_option);
    const char *maxrate = last_stream_option(argc, argv, "-maxrate",
                                             codec_option);
    const char *bufsize = last_stream_option(argc, argv, "-bufsize",
                                             codec_option);
    const char *bframes = last_stream_option(argc, argv, "-bf", codec_option);
    const char *unsupported_names[] = {
        "-low_power", "-idr_interval", "-b_depth", "-async_depth",
        "-max_frame_size", "-aud",
    };
    unsigned parsed;
    unsigned parsed_bitrate = 0;
    unsigned parsed_maxrate = 0;
    unsigned ignored_rate;
    size_t index;

    memset(translated, 0, sizeof(*translated));
    if ((bitrate != NULL && !parse_rate_value(bitrate, &parsed_bitrate)) ||
        (maxrate != NULL && !parse_rate_value(maxrate, &parsed_maxrate)) ||
        (bufsize != NULL && !parse_rate_value(bufsize, &ignored_rate)) ||
        (bframes != NULL &&
         (!parse_unsigned_value(bframes, 16, &parsed)))) {
        return false;
    }
    if (!translate_profile(encoder,
                           last_stream_option(argc, argv, "-profile",
                                              codec_option),
                           translated->profile,
                           sizeof(translated->profile)) ||
        !translate_level(last_stream_option(argc, argv, "-level",
                                            codec_option),
                         translated->level, sizeof(translated->level)) ||
        !translate_entropy(encoder, coder, translated->entropy,
                           sizeof(translated->entropy))) {
        return false;
    }
    if (pixel_format != NULL && strcmp(pixel_format, "nv12") != 0) {
        return false;
    }
    if (quality != NULL && strcmp(quality, "4") != 0) {
        return false;
    }
    if (rc_mode == NULL || strcasecmp(rc_mode, "auto") == 0 ||
        strcasecmp(rc_mode, "VBR") == 0) {
        if (qp != NULL) {
            return false;
        }
        if ((rc_mode == NULL || strcasecmp(rc_mode, "auto") == 0) &&
            bitrate != NULL && maxrate != NULL &&
            parsed_bitrate == parsed_maxrate) {
            translated->constant_bit_rate = true;
        }
    } else if (strcasecmp(rc_mode, "CBR") == 0) {
        if (qp != NULL) {
            return false;
        }
        translated->constant_bit_rate = true;
    } else if (strcasecmp(rc_mode, "CQP") == 0) {
        if (!parse_unsigned_value(qp, 51, &parsed)) {
            return false;
        }
        parsed = 1U + (51U - parsed) * 99U / 50U;
        (void)snprintf(translated->global_quality,
                       sizeof(translated->global_quality), "%u", parsed);
    } else {
        return false;
    }
    if (!translate_force_keyframes(force_keyframes, rate, translated->gop,
                                   sizeof(translated->gop))) {
        return false;
    }
    translated->closed_gop = force_keyframes != NULL;
    if (translated->gop[0] == '\0' && gop != NULL) {
        if (!parse_unsigned_value(gop, 100000, &parsed) || parsed == 0) {
            return false;
        }
        (void)snprintf(translated->gop, sizeof(translated->gop), "%u", parsed);
    } else if (translated->gop[0] != '\0' && gop != NULL &&
               strcmp(translated->gop, gop) != 0) {
        return false;
    }
    if (sei != NULL) {
        if (strcmp(encoder, "h264_vaapi") != 0 ||
            strcasecmp(sei, "a53_cc") != 0) {
            return false;
        }
        translated->a53_cc = true;
    }
    for (index = 0; index < sizeof(unsupported_names) /
                                sizeof(unsupported_names[0]); ++index) {
        if (last_stream_option(argc, argv, unsupported_names[index],
                               codec_option) != NULL) {
            return false;
        }
    }
    return true;
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
                                  const char *codec_option,
                                  const RemoteEncoderOptions *options)
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
        append_filter_option(argument, 1024, &used, "vt_remote_bufsize",
                             last_stream_option(argc, argv, "-bufsize",
                                                codec_option)) < 0 ||
        append_filter_option(argument, 1024, &used, "vt_remote_gop",
                             options->gop) < 0 ||
        append_filter_option(argument, 1024, &used, "vt_remote_max_b_frames",
                             last_stream_option(argc, argv, "-bf",
                                                codec_option)) < 0 ||
        append_filter_option(argument, 1024, &used, "vt_remote_profile",
                             options->profile) < 0 ||
        append_filter_option(argument, 1024, &used, "vt_remote_level",
                             options->level) < 0 ||
        append_filter_option(argument, 1024, &used, "vt_remote_entropy",
                             options->entropy) < 0 ||
        append_filter_option(argument, 1024, &used,
                             "vt_remote_global_quality",
                             options->global_quality) < 0 ||
        (options->constant_bit_rate &&
         append_filter_option(argument, 1024, &used,
                              "vt_remote_constant_bit_rate", "1") < 0) ||
        (options->a53_cc &&
         append_filter_option(argument, 1024, &used,
                              "vt_remote_a53_cc", "1") < 0) ||
        (options->closed_gop &&
         append_filter_option(argument, 1024, &used,
                              "vt_remote_flags", "2147483648") < 0)) {
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
    RemoteEncoderOptions encoder_options;
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

    encoder_index = find_unique_vaapi_encoder(argc, argv);
    input_codec_index = find_unique_supported_input_codec(argv, encoder_index);
    if (env_enabled("VTREMOTE_PLEX_REMOTE_TRANSCODE") &&
        has_environment_value("VTREMOTE_HOST") &&
        (test_mode || access(bsf_library, R_OK) == 0) &&
        plex_runtime_supported(test_mode) &&
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
        if (!unsupported_graph && graph.option_index >= 0 &&
            mapped_output_count(argc, argv, graph.output_map) == 1 &&
            translate_encoder_options(argc, argv, argv[encoder_index],
                                      argv[encoder_index - 1],
                                      &encoder_options)) {
            filter_argument = make_filter_argument(argc, argv, &graph,
                                                   argv[encoder_index],
                                                   argv[encoder_index - 1],
                                                   &encoder_options);
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
            if (rewritten_argv[input_index] == NULL) {
                fprintf(stderr,
                        "vtremote Plex wrapper: internal argument rewrite error\n");
                free_remote_graph(&graph);
                free(filter_argument);
                free(bsf_option);
                free(rewritten_argv);
                return 70;
            }
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
