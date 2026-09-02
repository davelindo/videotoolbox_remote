/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define _POSIX_C_SOURCE 200809L
#include "vtremote/client.h"

#include <va/va.h>
#include <va/va_backend.h>
#include <va/va_enc_h264.h>
#include <va/va_enc_hevc.h>

#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#ifndef VTREMOTE_VERSION
#define VTREMOTE_VERSION "dev"
#endif
#define VTRVA_VENDOR "VTRemote VA-API driver " VTREMOTE_VERSION " (remote VideoToolbox encode)"

#define VTRVA_MAX_CONFIGS 64
#define VTRVA_MAX_CONTEXTS 64
#define VTRVA_MAX_SURFACES 512
#define VTRVA_MAX_BUFFERS 2048
#define VTRVA_MAX_IMAGES 512
#define VTRVA_MAX_DIMENSION 8192U

#define VTRVA_CONFIG_BASE  0x01000000U
#define VTRVA_CONTEXT_BASE 0x02000000U
#define VTRVA_SURFACE_BASE 0x03000000U
#define VTRVA_BUFFER_BASE  0x04000000U
#define VTRVA_IMAGE_BASE   0x05000000U

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))

/* One driver instance is owned by one VADisplay.  Objects live in fixed-size
 * arrays so IDs remain stable while network calls release the global mutex. */
typedef struct VTRVAConfig {
    bool active;
    VAConfigID id;
    VAProfile profile;
    VAEntrypoint entrypoint;
    uint32_t rt_format;
    uint32_t rate_control;
} VTRVAConfig;

typedef struct VTRVASurface {
    bool active;
    VASurfaceID id;
    uint32_t width;
    uint32_t height;
    uint32_t fourcc;
    uint32_t rt_format;
    uint32_t stride_y;
    uint32_t stride_uv;
    uint32_t uv_height;
    size_t data_size;
    uint8_t *data;
    VASurfaceStatus status;
    VAStatus last_error;
} VTRVASurface;

typedef struct VTRVABuffer {
    bool active;
    VABufferID id;
    VAContextID context_id;
    VABufferType type;
    unsigned int element_size;
    unsigned int num_elements;
    size_t size;
    size_t capacity;
    uint8_t *data;
    bool owns_data;
    bool mapped;
    VACodedBufferSegment coded;
} VTRVABuffer;

typedef struct VTRVAImageObject {
    bool active;
    VAImageID id;
    VAImage image;
    bool derived;
    VASurfaceID surface_id;
} VTRVAImageObject;

typedef struct VTRVAContext {
    bool active;
    VAContextID id;
    VAConfigID config_id;
    int width;
    int height;
    int flags;
    VASurfaceID current_surface;
    VABufferID pending_coded_buffer;
    uint64_t frame_index;

    uint32_t bit_rate;
    uint32_t max_rate;
    uint32_t gop_size;
    uint32_t frame_rate_num;
    uint32_t frame_rate_den;
    uint32_t max_b_frames;
    int realtime;
    int constant_bit_rate;
    int timeout_ms;
    VTRWireCompression wire_compression;
    bool connection_dirty;
    bool force_keyframe;
    bool session_failed;

    pthread_mutex_t io_lock;
    bool io_lock_initialized;
    VTRClient client;
    bool client_initialized;
    VTRBuffer packet;
    bool packet_initialized;
} VTRVAContext;

typedef struct VTRVADriver {
    pthread_mutex_t lock;
    bool lock_initialized;
    VADriverContextP va_context;
    bool verbose;
    VTRVAConfig configs[VTRVA_MAX_CONFIGS];
    VTRVAContext contexts[VTRVA_MAX_CONTEXTS];
    VTRVASurface surfaces[VTRVA_MAX_SURFACES];
    VTRVABuffer buffers[VTRVA_MAX_BUFFERS];
    VTRVAImageObject images[VTRVA_MAX_IMAGES];
} VTRVADriver;

static VTRVADriver *driver_data(VADriverContextP ctx) {
    return ctx ? (VTRVADriver *)ctx->pDriverData : NULL;
}

static uint32_t align_up_u32(uint32_t value, uint32_t alignment) {
    return (value + alignment - 1U) & ~(alignment - 1U);
}

static uint32_t env_u32(const char *name, uint32_t fallback, uint32_t minimum,
                        uint32_t maximum) {
    const char *value = getenv(name);
    char *end = NULL;
    unsigned long parsed;
    if (!value || !*value) return fallback;
    errno = 0;
    parsed = strtoul(value, &end, 10);
    if (errno || !end || *end || parsed < minimum || parsed > maximum)
        return fallback;
    return (uint32_t)parsed;
}

static int env_bool(const char *name, int fallback) {
    const char *value = getenv(name);
    if (!value || !*value) return fallback;
    if (!strcasecmp(value, "1") || !strcasecmp(value, "yes") ||
        !strcasecmp(value, "true") || !strcasecmp(value, "on")) return 1;
    if (!strcasecmp(value, "0") || !strcasecmp(value, "no") ||
        !strcasecmp(value, "false") || !strcasecmp(value, "off")) return 0;
    return fallback;
}

static const char *env_string(const char *name, const char *fallback) {
    const char *value = getenv(name);
    return value && *value ? value : fallback;
}

static bool env_wire_compression(VTRWireCompression *compression) {
    const char *value = getenv("VTREMOTE_WIRE_COMPRESSION");
    if (!compression) return false;
    if (!value || !*value || !strcasecmp(value, "auto"))
        *compression = VTR_WIRE_COMPRESSION_AUTO;
    else if (!strcasecmp(value, "none") || !strcmp(value, "0"))
        *compression = VTR_WIRE_COMPRESSION_NONE;
    else if (!strcasecmp(value, "lz4") || !strcmp(value, "1"))
        *compression = VTR_WIRE_COMPRESSION_LZ4;
    else if (!strcasecmp(value, "zstd") || !strcmp(value, "2"))
        *compression = VTR_WIRE_COMPRESSION_ZSTD;
    else
        return false;
    return true;
}

static void vtrva_log(VTRVADriver *driver, bool error, const char *fmt, ...) {
    char message[1024];
    va_list ap;
    if (!driver || (!error && !driver->verbose)) return;
    va_start(ap, fmt);
    vsnprintf(message, sizeof(message), fmt, ap);
    va_end(ap);
    if (driver->va_context) {
        char callback_message[sizeof(message) + 2];
        snprintf(callback_message, sizeof(callback_message), "%s\n", message);
        if (error && driver->va_context->error_callback) {
            driver->va_context->error_callback(driver->va_context, callback_message);
            return;
        }
        if (!error && driver->va_context->info_callback) {
            driver->va_context->info_callback(driver->va_context, callback_message);
            return;
        }
    }
    fprintf(stderr, "vtremote-vaapi: %s\n", message);
}

static bool profile_supported(VAProfile profile) {
    switch (profile) {
        case VAProfileH264ConstrainedBaseline:
        case VAProfileH264Main:
        case VAProfileH264High:
        case VAProfileHEVCMain:
        case VAProfileHEVCMain10:
            return true;
        default:
            return false;
    }
}

static const char *codec_for_profile(VAProfile profile) {
    switch (profile) {
        case VAProfileHEVCMain:
        case VAProfileHEVCMain10:
            return "hevc";
        default:
            return "h264";
    }
}

static bool is_hevc_profile(VAProfile profile) {
    return profile == VAProfileHEVCMain || profile == VAProfileHEVCMain10;
}

static int ffmpeg_profile_for_va_profile(VAProfile profile) {
    switch (profile) {
        case VAProfileH264ConstrainedBaseline: return 66 | (1 << 9);
        case VAProfileH264Main: return 77;
        case VAProfileH264High: return 100;
        case VAProfileHEVCMain: return 1;
        case VAProfileHEVCMain10: return 2;
        default: return -1;
    }
}

static uint32_t formats_for_profile(VAProfile profile) {
    if (profile == VAProfileHEVCMain10)
        return VA_RT_FORMAT_YUV420 | VA_RT_FORMAT_YUV420_10;
    return VA_RT_FORMAT_YUV420;
}

static bool is_encode_buffer_type(VABufferType type) {
    return type >= VAEncCodedBufferType && type <= VAEncQPBufferType;
}

static void fill_image_format(uint32_t fourcc, VAImageFormat *format) {
    memset(format, 0, sizeof(*format));
    format->fourcc = fourcc;
    format->byte_order = VA_LSB_FIRST;
    if (fourcc == VA_FOURCC_P010) {
        format->bits_per_pixel = 24;
        format->depth = 10;
    } else {
        format->bits_per_pixel = 12;
        format->depth = 8;
    }
}

static void fill_image_descriptor(VAImage *image, VAImageID image_id,
                                  VABufferID buffer_id, uint32_t fourcc,
                                  uint32_t width, uint32_t height,
                                  uint32_t stride_y, uint32_t stride_uv,
                                  size_t data_size) {
    memset(image, 0, sizeof(*image));
    image->image_id = image_id;
    fill_image_format(fourcc, &image->format);
    image->buf = buffer_id;
    image->width = (uint16_t)width;
    image->height = (uint16_t)height;
    image->data_size = (uint32_t)data_size;
    image->num_planes = 2;
    image->pitches[0] = stride_y;
    image->pitches[1] = stride_uv;
    image->pitches[2] = stride_uv;
    image->offsets[0] = 0;
    image->offsets[1] = stride_y * height;
    image->offsets[2] = image->offsets[1];
}

static VTRVAConfig *lookup_config_locked(VTRVADriver *driver, VAConfigID id) {
    uint32_t slot;
    if (!driver || id <= VTRVA_CONFIG_BASE) return NULL;
    slot = id - VTRVA_CONFIG_BASE - 1U;
    if (slot >= VTRVA_MAX_CONFIGS || !driver->configs[slot].active ||
        driver->configs[slot].id != id) return NULL;
    return &driver->configs[slot];
}

static VTRVAContext *lookup_context_locked(VTRVADriver *driver, VAContextID id) {
    uint32_t slot;
    if (!driver || id <= VTRVA_CONTEXT_BASE) return NULL;
    slot = id - VTRVA_CONTEXT_BASE - 1U;
    if (slot >= VTRVA_MAX_CONTEXTS || !driver->contexts[slot].active ||
        driver->contexts[slot].id != id) return NULL;
    return &driver->contexts[slot];
}

static VTRVASurface *lookup_surface_locked(VTRVADriver *driver, VASurfaceID id) {
    uint32_t slot;
    if (!driver || id <= VTRVA_SURFACE_BASE) return NULL;
    slot = id - VTRVA_SURFACE_BASE - 1U;
    if (slot >= VTRVA_MAX_SURFACES || !driver->surfaces[slot].active ||
        driver->surfaces[slot].id != id) return NULL;
    return &driver->surfaces[slot];
}

static VTRVABuffer *lookup_buffer_locked(VTRVADriver *driver, VABufferID id) {
    uint32_t slot;
    if (!driver || id <= VTRVA_BUFFER_BASE) return NULL;
    slot = id - VTRVA_BUFFER_BASE - 1U;
    if (slot >= VTRVA_MAX_BUFFERS || !driver->buffers[slot].active ||
        driver->buffers[slot].id != id) return NULL;
    return &driver->buffers[slot];
}

static VTRVAImageObject *lookup_image_locked(VTRVADriver *driver, VAImageID id) {
    uint32_t slot;
    if (!driver || id <= VTRVA_IMAGE_BASE) return NULL;
    slot = id - VTRVA_IMAGE_BASE - 1U;
    if (slot >= VTRVA_MAX_IMAGES || !driver->images[slot].active ||
        driver->images[slot].id != id) return NULL;
    return &driver->images[slot];
}

static VTRVAConfig *alloc_config_locked(VTRVADriver *driver) {
    size_t i;
    for (i = 0; i < ARRAY_SIZE(driver->configs); ++i) {
        if (!driver->configs[i].active) {
            memset(&driver->configs[i], 0, sizeof(driver->configs[i]));
            driver->configs[i].active = true;
            driver->configs[i].id = VTRVA_CONFIG_BASE + (VAConfigID)i + 1U;
            return &driver->configs[i];
        }
    }
    return NULL;
}

static VTRVAContext *alloc_context_locked(VTRVADriver *driver) {
    size_t i;
    for (i = 0; i < ARRAY_SIZE(driver->contexts); ++i) {
        if (!driver->contexts[i].active) {
            memset(&driver->contexts[i], 0, sizeof(driver->contexts[i]));
            driver->contexts[i].active = true;
            driver->contexts[i].id = VTRVA_CONTEXT_BASE + (VAContextID)i + 1U;
            driver->contexts[i].current_surface = VA_INVALID_SURFACE;
            driver->contexts[i].pending_coded_buffer = VA_INVALID_ID;
            return &driver->contexts[i];
        }
    }
    return NULL;
}

static VTRVASurface *alloc_surface_locked(VTRVADriver *driver) {
    size_t i;
    for (i = 0; i < ARRAY_SIZE(driver->surfaces); ++i) {
        if (!driver->surfaces[i].active) {
            memset(&driver->surfaces[i], 0, sizeof(driver->surfaces[i]));
            driver->surfaces[i].active = true;
            driver->surfaces[i].id = VTRVA_SURFACE_BASE + (VASurfaceID)i + 1U;
            driver->surfaces[i].status = VASurfaceReady;
            driver->surfaces[i].last_error = VA_STATUS_SUCCESS;
            return &driver->surfaces[i];
        }
    }
    return NULL;
}

static VTRVABuffer *alloc_buffer_locked(VTRVADriver *driver) {
    size_t i;
    for (i = 0; i < ARRAY_SIZE(driver->buffers); ++i) {
        if (!driver->buffers[i].active) {
            memset(&driver->buffers[i], 0, sizeof(driver->buffers[i]));
            driver->buffers[i].active = true;
            driver->buffers[i].id = VTRVA_BUFFER_BASE + (VABufferID)i + 1U;
            driver->buffers[i].owns_data = true;
            return &driver->buffers[i];
        }
    }
    return NULL;
}

static VTRVAImageObject *alloc_image_locked(VTRVADriver *driver) {
    size_t i;
    for (i = 0; i < ARRAY_SIZE(driver->images); ++i) {
        if (!driver->images[i].active) {
            memset(&driver->images[i], 0, sizeof(driver->images[i]));
            driver->images[i].active = true;
            driver->images[i].id = VTRVA_IMAGE_BASE + (VAImageID)i + 1U;
            return &driver->images[i];
        }
    }
    return NULL;
}

static void release_buffer_locked(VTRVABuffer *buffer) {
    if (!buffer) return;
    if (buffer->owns_data) free(buffer->data);
    memset(buffer, 0, sizeof(*buffer));
}

static void release_surface_locked(VTRVASurface *surface) {
    if (!surface) return;
    free(surface->data);
    memset(surface, 0, sizeof(*surface));
}

static void disconnect_context(VTRVAContext *context) {
    char ignored[64];
    if (!context) return;
    if (context->client_initialized) {
        if (context->client.connected)
            (void)vtr_client_flush(&context->client, ignored, sizeof(ignored));
        vtr_client_destroy(&context->client);
        context->client_initialized = false;
    }
    if (context->packet_initialized) {
        vtr_buffer_free(&context->packet);
        context->packet_initialized = false;
    }
}

static void release_context_locked(VTRVAContext *context) {
    if (!context) return;
    disconnect_context(context);
    if (context->io_lock_initialized) {
        pthread_mutex_destroy(&context->io_lock);
        context->io_lock_initialized = false;
    }
    memset(context, 0, sizeof(*context));
}

static VAStatus get_config_attribute_value(VAProfile profile, VAEntrypoint entrypoint,
                                           VAConfigAttribType type, uint32_t *value) {
    if (!value) return VA_STATUS_ERROR_INVALID_PARAMETER;
    if (!profile_supported(profile)) return VA_STATUS_ERROR_UNSUPPORTED_PROFILE;
    if (entrypoint != VAEntrypointEncSlice)
        return VA_STATUS_ERROR_UNSUPPORTED_ENTRYPOINT;
    switch (type) {
        case VAConfigAttribRTFormat:
            *value = formats_for_profile(profile);
            break;
        case VAConfigAttribRateControl:
            *value = VA_RC_CBR | VA_RC_VBR;
            break;
        case VAConfigAttribEncPackedHeaders:
            *value = VA_ENC_PACKED_HEADER_NONE;
            break;
        case VAConfigAttribEncInterlaced:
            *value = VA_ENC_INTERLACED_NONE;
            break;
        case VAConfigAttribEncMaxRefFrames:
            *value = 1U; /* one L0 reference; no B-frame references */
            break;
        case VAConfigAttribEncMaxSlices:
            *value = 1U;
            break;
        case VAConfigAttribEncSliceStructure:
            *value = VA_ENC_SLICE_STRUCTURE_ARBITRARY_MACROBLOCKS |
                     VA_ENC_SLICE_STRUCTURE_EQUAL_ROWS |
                     VA_ENC_SLICE_STRUCTURE_ARBITRARY_ROWS;
            break;
        case VAConfigAttribMaxPictureWidth:
        case VAConfigAttribMaxPictureHeight:
            *value = VTRVA_MAX_DIMENSION;
            break;
        case VAConfigAttribEncQualityRange:
            *value = 1U;
            break;
        case VAConfigAttribEncSkipFrame:
            *value = 0U;
            break;
        default:
            *value = VA_ATTRIB_NOT_SUPPORTED;
            break;
    }
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_terminate(VADriverContextP ctx) {
    VTRVADriver *driver = driver_data(ctx);
    size_t i;
    if (!driver) return VA_STATUS_ERROR_INVALID_DISPLAY;
    if (driver->lock_initialized) pthread_mutex_lock(&driver->lock);
    for (i = 0; i < ARRAY_SIZE(driver->contexts); ++i)
        if (driver->contexts[i].active) release_context_locked(&driver->contexts[i]);
    for (i = 0; i < ARRAY_SIZE(driver->buffers); ++i)
        if (driver->buffers[i].active) release_buffer_locked(&driver->buffers[i]);
    for (i = 0; i < ARRAY_SIZE(driver->surfaces); ++i)
        if (driver->surfaces[i].active) release_surface_locked(&driver->surfaces[i]);
    if (driver->lock_initialized) {
        pthread_mutex_unlock(&driver->lock);
        pthread_mutex_destroy(&driver->lock);
    }
    free(driver);
    ctx->pDriverData = NULL;
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_query_config_profiles(VADriverContextP ctx,
                                             VAProfile *profiles,
                                             int *num_profiles) {
    static const VAProfile supported[] = {
        VAProfileH264ConstrainedBaseline,
        VAProfileH264Main,
        VAProfileH264High,
        VAProfileHEVCMain,
        VAProfileHEVCMain10,
    };
    (void)ctx;
    if (!num_profiles) return VA_STATUS_ERROR_INVALID_PARAMETER;
    if (profiles) memcpy(profiles, supported, sizeof(supported));
    *num_profiles = (int)ARRAY_SIZE(supported);
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_query_config_entrypoints(VADriverContextP ctx,
                                                VAProfile profile,
                                                VAEntrypoint *entrypoints,
                                                int *num_entrypoints) {
    (void)ctx;
    if (!num_entrypoints) return VA_STATUS_ERROR_INVALID_PARAMETER;
    if (!profile_supported(profile)) return VA_STATUS_ERROR_UNSUPPORTED_PROFILE;
    if (entrypoints) entrypoints[0] = VAEntrypointEncSlice;
    *num_entrypoints = 1;
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_get_config_attributes(VADriverContextP ctx,
                                             VAProfile profile,
                                             VAEntrypoint entrypoint,
                                             VAConfigAttrib *attributes,
                                             int num_attributes) {
    int i;
    VAStatus status;
    (void)ctx;
    if (num_attributes < 0 || (num_attributes && !attributes))
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    for (i = 0; i < num_attributes; ++i) {
        status = get_config_attribute_value(profile, entrypoint,
                                            attributes[i].type,
                                            &attributes[i].value);
        if (status != VA_STATUS_SUCCESS) return status;
    }
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_create_config(VADriverContextP ctx, VAProfile profile,
                                     VAEntrypoint entrypoint,
                                     VAConfigAttrib *attributes,
                                     int num_attributes,
                                     VAConfigID *config_id) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVAConfig *config;
    uint32_t supported_formats;
    int i;
    if (!driver || !config_id || num_attributes < 0 ||
        (num_attributes && !attributes)) return VA_STATUS_ERROR_INVALID_PARAMETER;
    if (!profile_supported(profile)) return VA_STATUS_ERROR_UNSUPPORTED_PROFILE;
    if (entrypoint != VAEntrypointEncSlice)
        return VA_STATUS_ERROR_UNSUPPORTED_ENTRYPOINT;
    supported_formats = formats_for_profile(profile);

    pthread_mutex_lock(&driver->lock);
    config = alloc_config_locked(driver);
    if (!config) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_MAX_NUM_EXCEEDED;
    }
    config->profile = profile;
    config->entrypoint = entrypoint;
    config->rt_format = supported_formats;
    config->rate_control = VA_RC_VBR;
    for (i = 0; i < num_attributes; ++i) {
        if (attributes[i].value == VA_ATTRIB_NOT_SUPPORTED) continue;
        switch (attributes[i].type) {
            case VAConfigAttribRTFormat:
                if (!attributes[i].value ||
                    (attributes[i].value & ~supported_formats)) {
                    config->active = false;
                    pthread_mutex_unlock(&driver->lock);
                    return VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT;
                }
                config->rt_format = attributes[i].value;
                break;
            case VAConfigAttribRateControl:
                if (attributes[i].value != VA_RC_CBR &&
                    attributes[i].value != VA_RC_VBR) {
                    config->active = false;
                    pthread_mutex_unlock(&driver->lock);
                    return VA_STATUS_ERROR_ATTR_NOT_SUPPORTED;
                }
                config->rate_control = attributes[i].value;
                break;
            default:
                break;
        }
    }
    *config_id = config->id;
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_destroy_config(VADriverContextP ctx, VAConfigID config_id) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVAConfig *config;
    if (!driver) return VA_STATUS_ERROR_INVALID_DISPLAY;
    pthread_mutex_lock(&driver->lock);
    config = lookup_config_locked(driver, config_id);
    if (!config) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_CONFIG;
    }
    memset(config, 0, sizeof(*config));
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_query_config_attributes(VADriverContextP ctx,
                                               VAConfigID config_id,
                                               VAProfile *profile,
                                               VAEntrypoint *entrypoint,
                                               VAConfigAttrib *attributes,
                                               int *num_attributes) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVAConfig *config;
    int capacity;
    if (!driver || !num_attributes) return VA_STATUS_ERROR_INVALID_PARAMETER;
    capacity = *num_attributes;
    pthread_mutex_lock(&driver->lock);
    config = lookup_config_locked(driver, config_id);
    if (!config) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_CONFIG;
    }
    if (profile) *profile = config->profile;
    if (entrypoint) *entrypoint = config->entrypoint;
    if (attributes && capacity > 0) {
        attributes[0].type = VAConfigAttribRTFormat;
        attributes[0].value = config->rt_format;
    }
    if (attributes && capacity > 1) {
        attributes[1].type = VAConfigAttribRateControl;
        attributes[1].value = config->rate_control;
    }
    *num_attributes = 2;
    pthread_mutex_unlock(&driver->lock);
    return capacity < 2 && attributes ? VA_STATUS_ERROR_MAX_NUM_EXCEEDED
                                      : VA_STATUS_SUCCESS;
}

static VAStatus create_one_surface_locked(VTRVADriver *driver, uint32_t format,
                                           uint32_t width, uint32_t height,
                                           uint32_t requested_fourcc,
                                           VASurfaceID *surface_id) {
    VTRVASurface *surface;
    uint32_t bytes_per_sample;
    uint64_t size;
    if (!width || !height || width > VTRVA_MAX_DIMENSION ||
        height > VTRVA_MAX_DIMENSION)
        return VA_STATUS_ERROR_RESOLUTION_NOT_SUPPORTED;
    if (requested_fourcc != VA_FOURCC_NV12 && requested_fourcc != VA_FOURCC_P010)
        return VA_STATUS_ERROR_INVALID_IMAGE_FORMAT;
    if (requested_fourcc == VA_FOURCC_P010 && !(format & VA_RT_FORMAT_YUV420_10))
        return VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT;
    if (requested_fourcc == VA_FOURCC_NV12 && !(format & VA_RT_FORMAT_YUV420))
        return VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT;

    surface = alloc_surface_locked(driver);
    if (!surface) return VA_STATUS_ERROR_MAX_NUM_EXCEEDED;
    bytes_per_sample = requested_fourcc == VA_FOURCC_P010 ? 2U : 1U;
    surface->width = width;
    surface->height = height;
    surface->fourcc = requested_fourcc;
    surface->rt_format = requested_fourcc == VA_FOURCC_P010
                           ? VA_RT_FORMAT_YUV420_10 : VA_RT_FORMAT_YUV420;
    surface->stride_y = align_up_u32(width * bytes_per_sample, 64U);
    surface->stride_uv = surface->stride_y;
    surface->uv_height = (height + 1U) / 2U;
    size = (uint64_t)surface->stride_y * height +
           (uint64_t)surface->stride_uv * surface->uv_height;
    if (size > SIZE_MAX || size > UINT32_MAX) {
        surface->active = false;
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    }
    surface->data_size = (size_t)size;
    surface->data = (uint8_t *)calloc(1, surface->data_size);
    if (!surface->data) {
        surface->active = false;
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    }
    *surface_id = surface->id;
    vtrva_log(driver, false, "created surface %#x %ux%u fourcc=%#x stride=%u",
              surface->id, width, height, requested_fourcc, surface->stride_y);
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_create_surfaces2(VADriverContextP ctx, unsigned int format,
                                        unsigned int width, unsigned int height,
                                        VASurfaceID *surfaces,
                                        unsigned int num_surfaces,
                                        VASurfaceAttrib *attributes,
                                        unsigned int num_attributes) {
    VTRVADriver *driver = driver_data(ctx);
    uint32_t fourcc;
    unsigned int i;
    VAStatus status = VA_STATUS_SUCCESS;
    if (!driver || !surfaces || !num_surfaces)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    if (!(format & (VA_RT_FORMAT_YUV420 | VA_RT_FORMAT_YUV420_10)))
        return VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT;
    fourcc = (format & VA_RT_FORMAT_YUV420_10) && !(format & VA_RT_FORMAT_YUV420)
               ? VA_FOURCC_P010 : VA_FOURCC_NV12;
    for (i = 0; i < num_attributes; ++i) {
        if (attributes[i].type == VASurfaceAttribPixelFormat &&
            attributes[i].value.type == VAGenericValueTypeInteger) {
            fourcc = (uint32_t)attributes[i].value.value.i;
        } else if (attributes[i].type == VASurfaceAttribMemoryType &&
                   attributes[i].value.type == VAGenericValueTypeInteger &&
                   attributes[i].value.value.i != (int32_t)VA_SURFACE_ATTRIB_MEM_TYPE_VA) {
            return VA_STATUS_ERROR_UNSUPPORTED_MEMORY_TYPE;
        } else if (attributes[i].type == VASurfaceAttribExternalBufferDescriptor) {
            return VA_STATUS_ERROR_UNSUPPORTED_MEMORY_TYPE;
        }
    }

    pthread_mutex_lock(&driver->lock);
    for (i = 0; i < num_surfaces; ++i) {
        status = create_one_surface_locked(driver, format, width, height, fourcc,
                                           &surfaces[i]);
        if (status != VA_STATUS_SUCCESS) break;
    }
    if (status != VA_STATUS_SUCCESS) {
        while (i > 0) {
            VTRVASurface *surface = lookup_surface_locked(driver, surfaces[--i]);
            release_surface_locked(surface);
        }
    }
    pthread_mutex_unlock(&driver->lock);
    return status;
}

static VAStatus vtrva_create_surfaces(VADriverContextP ctx, int width, int height,
                                       int format, int num_surfaces,
                                       VASurfaceID *surfaces) {
    if (width < 0 || height < 0 || num_surfaces < 0)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    return vtrva_create_surfaces2(ctx, (unsigned int)format, (unsigned int)width,
                                  (unsigned int)height, surfaces,
                                  (unsigned int)num_surfaces, NULL, 0);
}

static VAStatus vtrva_destroy_surfaces(VADriverContextP ctx,
                                        VASurfaceID *surface_list,
                                        int num_surfaces) {
    VTRVADriver *driver = driver_data(ctx);
    int i;
    if (!driver || num_surfaces < 0 || (num_surfaces && !surface_list))
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    pthread_mutex_lock(&driver->lock);
    for (i = 0; i < num_surfaces; ++i) {
        VTRVASurface *surface = lookup_surface_locked(driver, surface_list[i]);
        if (!surface) {
            pthread_mutex_unlock(&driver->lock);
            return VA_STATUS_ERROR_INVALID_SURFACE;
        }
        release_surface_locked(surface);
    }
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_query_surface_attributes(VADriverContextP ctx,
                                                VAConfigID config_id,
                                                VASurfaceAttrib *attributes,
                                                unsigned int *num_attributes) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVAConfig *config;
    VASurfaceAttrib values[7];
    unsigned int count = 0;
    unsigned int capacity;
#define ADD_INT(t, f, v) do { \
    memset(&values[count], 0, sizeof(values[count])); \
    values[count].type = (t); values[count].flags = (f); \
    values[count].value.type = VAGenericValueTypeInteger; \
    values[count].value.value.i = (int32_t)(v); ++count; \
} while (0)
    if (!driver || !num_attributes) return VA_STATUS_ERROR_INVALID_PARAMETER;
    capacity = *num_attributes;
    pthread_mutex_lock(&driver->lock);
    config = lookup_config_locked(driver, config_id);
    if (!config) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_CONFIG;
    }
    ADD_INT(VASurfaceAttribPixelFormat,
            VA_SURFACE_ATTRIB_GETTABLE | VA_SURFACE_ATTRIB_SETTABLE,
            VA_FOURCC_NV12);
    if (config->profile == VAProfileHEVCMain10)
        ADD_INT(VASurfaceAttribPixelFormat,
                VA_SURFACE_ATTRIB_GETTABLE | VA_SURFACE_ATTRIB_SETTABLE,
                VA_FOURCC_P010);
    ADD_INT(VASurfaceAttribMinWidth, VA_SURFACE_ATTRIB_GETTABLE, 16);
    ADD_INT(VASurfaceAttribMaxWidth, VA_SURFACE_ATTRIB_GETTABLE, VTRVA_MAX_DIMENSION);
    ADD_INT(VASurfaceAttribMinHeight, VA_SURFACE_ATTRIB_GETTABLE, 16);
    ADD_INT(VASurfaceAttribMaxHeight, VA_SURFACE_ATTRIB_GETTABLE, VTRVA_MAX_DIMENSION);
    ADD_INT(VASurfaceAttribMemoryType,
            VA_SURFACE_ATTRIB_GETTABLE | VA_SURFACE_ATTRIB_SETTABLE,
            VA_SURFACE_ATTRIB_MEM_TYPE_VA);
    if (!attributes) {
        *num_attributes = count;
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_SUCCESS;
    }
    if (capacity < count) {
        *num_attributes = count;
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_MAX_NUM_EXCEEDED;
    }
    memcpy(attributes, values, count * sizeof(values[0]));
    *num_attributes = count;
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
#undef ADD_INT
}

static VAStatus vtrva_get_surface_attributes(VADriverContextP ctx,
                                              VAConfigID config_id,
                                              VASurfaceAttrib *attributes,
                                              unsigned int num_attributes) {
    unsigned int count = num_attributes;
    return vtrva_query_surface_attributes(ctx, config_id, attributes, &count);
}

static VAStatus vtrva_create_context(VADriverContextP ctx, VAConfigID config_id,
                                      int picture_width, int picture_height,
                                      int flag, VASurfaceID *render_targets,
                                      int num_render_targets,
                                      VAContextID *context_id) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVAConfig *config;
    VTRVAContext *context;
    int i;
    if (!driver || !context_id || picture_width <= 0 || picture_height <= 0 ||
        picture_width > (int)VTRVA_MAX_DIMENSION ||
        picture_height > (int)VTRVA_MAX_DIMENSION || num_render_targets < 0 ||
        (num_render_targets && !render_targets))
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    pthread_mutex_lock(&driver->lock);
    config = lookup_config_locked(driver, config_id);
    if (!config) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_CONFIG;
    }
    for (i = 0; i < num_render_targets; ++i) {
        if (!lookup_surface_locked(driver, render_targets[i])) {
            pthread_mutex_unlock(&driver->lock);
            return VA_STATUS_ERROR_INVALID_SURFACE;
        }
    }
    context = alloc_context_locked(driver);
    if (!context) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_MAX_NUM_EXCEEDED;
    }
    context->config_id = config_id;
    context->width = picture_width;
    context->height = picture_height;
    context->flags = flag;
    context->bit_rate = env_u32("VTREMOTE_BITRATE", 8000000U, 1U, UINT32_MAX);
    context->max_rate = env_u32("VTREMOTE_MAXRATE", context->bit_rate, 1U, UINT32_MAX);
    context->gop_size = env_u32("VTREMOTE_GOP", 60U, 1U, 100000U);
    context->frame_rate_num = env_u32("VTREMOTE_FPS_NUM", 30U, 1U, 100000U);
    context->frame_rate_den = env_u32("VTREMOTE_FPS_DEN", 1U, 1U, 100000U);
    context->max_b_frames = 0; /* synchronous v1; preserve monotonic DTS */
    context->realtime = env_bool("VTREMOTE_REALTIME", 1);
    context->constant_bit_rate = config->rate_control == VA_RC_CBR;
    context->timeout_ms = (int)env_u32("VTREMOTE_TIMEOUT_MS", 10000U, 100U, 600000U);
    if (!env_wire_compression(&context->wire_compression)) {
        vtrva_log(driver, true,
                  "invalid VTREMOTE_WIRE_COMPRESSION; use auto, none, lz4, or zstd");
        memset(context, 0, sizeof(*context));
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    }
    context->connection_dirty = true;
    if (pthread_mutex_init(&context->io_lock, NULL) != 0) {
        memset(context, 0, sizeof(*context));
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    }
    context->io_lock_initialized = true;
    vtr_client_init(&context->client);
    context->client_initialized = true;
    vtr_buffer_init(&context->packet);
    context->packet_initialized = true;
    *context_id = context->id;
    vtrva_log(driver, false, "created context %#x config=%#x %dx%d targets=%d",
              context->id, config_id, picture_width, picture_height, num_render_targets);
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_destroy_context(VADriverContextP ctx,
                                       VAContextID context_id) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVAContext *context;
    if (!driver) return VA_STATUS_ERROR_INVALID_DISPLAY;
    pthread_mutex_lock(&driver->lock);
    context = lookup_context_locked(driver, context_id);
    if (!context) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_CONTEXT;
    }
    /* VA applications do not destroy an active context concurrently with
       vaEndPicture.  Keep teardown simple and deterministic for v1. */
    release_context_locked(context);
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
}

static VAStatus create_buffer_locked(VTRVADriver *driver, VAContextID context_id,
                                      VABufferType type, unsigned int size,
                                      unsigned int num_elements, void *data,
                                      VABufferID *buffer_id) {
    VTRVABuffer *buffer;
    size_t total;
    if (!driver || !buffer_id || !size || !num_elements ||
        size > SIZE_MAX / num_elements)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    total = (size_t)size * num_elements;
    if (context_id != VA_INVALID_ID &&
        !lookup_context_locked(driver, context_id))
        return VA_STATUS_ERROR_INVALID_CONTEXT;
    if (context_id != VA_INVALID_ID && !is_encode_buffer_type(type))
        return VA_STATUS_ERROR_UNSUPPORTED_BUFFERTYPE;
    buffer = alloc_buffer_locked(driver);
    if (!buffer) return VA_STATUS_ERROR_MAX_NUM_EXCEEDED;
    buffer->context_id = context_id;
    buffer->type = type;
    buffer->element_size = size;
    buffer->num_elements = num_elements;
    buffer->capacity = total;
    buffer->size = data ? total : 0;
    buffer->data = (uint8_t *)calloc(1, total);
    if (!buffer->data) {
        memset(buffer, 0, sizeof(*buffer));
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    }
    if (data) memcpy(buffer->data, data, total);
    if (type == VAEncCodedBufferType) {
        buffer->size = 0;
        memset(&buffer->coded, 0, sizeof(buffer->coded));
        buffer->coded.buf = buffer->data;
        buffer->coded.next = NULL;
    }
    *buffer_id = buffer->id;
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_create_buffer(VADriverContextP ctx, VAContextID context_id,
                                     VABufferType type, unsigned int size,
                                     unsigned int num_elements, void *data,
                                     VABufferID *buffer_id) {
    VTRVADriver *driver = driver_data(ctx);
    VAStatus status;
    if (!driver) return VA_STATUS_ERROR_INVALID_DISPLAY;
    pthread_mutex_lock(&driver->lock);
    status = create_buffer_locked(driver, context_id, type, size, num_elements,
                                  data, buffer_id);
    pthread_mutex_unlock(&driver->lock);
    return status;
}

static VAStatus vtrva_buffer_set_num_elements(VADriverContextP ctx,
                                               VABufferID buffer_id,
                                               unsigned int num_elements) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVABuffer *buffer;
    size_t total;
    uint8_t *next;
    if (!driver || !num_elements) return VA_STATUS_ERROR_INVALID_PARAMETER;
    pthread_mutex_lock(&driver->lock);
    buffer = lookup_buffer_locked(driver, buffer_id);
    if (!buffer) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_BUFFER;
    }
    if (!buffer->owns_data || buffer->element_size > SIZE_MAX / num_elements) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    }
    total = (size_t)buffer->element_size * num_elements;
    next = (uint8_t *)realloc(buffer->data, total);
    if (!next) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    }
    if (total > buffer->capacity)
        memset(next + buffer->capacity, 0, total - buffer->capacity);
    buffer->data = next;
    buffer->capacity = total;
    buffer->num_elements = num_elements;
    if (buffer->size > total) buffer->size = total;
    if (buffer->type == VAEncCodedBufferType) buffer->coded.buf = next;
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_map_buffer(VADriverContextP ctx, VABufferID buffer_id,
                                  void **mapped) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVABuffer *buffer;
    if (!driver || !mapped) return VA_STATUS_ERROR_INVALID_PARAMETER;
    pthread_mutex_lock(&driver->lock);
    buffer = lookup_buffer_locked(driver, buffer_id);
    if (!buffer) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_BUFFER;
    }
    buffer->mapped = true;
    if (buffer->type == VAEncCodedBufferType) {
        buffer->coded.size = (uint32_t)buffer->size;
        buffer->coded.bit_offset = 0;
        buffer->coded.status = 0;
        buffer->coded.buf = buffer->data;
        buffer->coded.next = NULL;
        *mapped = &buffer->coded;
    } else {
        *mapped = buffer->data;
    }
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_map_buffer2(VADriverContextP ctx, VABufferID buffer_id,
                                   void **mapped, uint32_t flags) {
    (void)flags;
    return vtrva_map_buffer(ctx, buffer_id, mapped);
}

static VAStatus vtrva_unmap_buffer(VADriverContextP ctx, VABufferID buffer_id) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVABuffer *buffer;
    if (!driver) return VA_STATUS_ERROR_INVALID_DISPLAY;
    pthread_mutex_lock(&driver->lock);
    buffer = lookup_buffer_locked(driver, buffer_id);
    if (!buffer) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_BUFFER;
    }
    buffer->mapped = false;
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_destroy_buffer(VADriverContextP ctx,
                                      VABufferID buffer_id) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVABuffer *buffer;
    if (!driver) return VA_STATUS_ERROR_INVALID_DISPLAY;
    pthread_mutex_lock(&driver->lock);
    buffer = lookup_buffer_locked(driver, buffer_id);
    if (!buffer) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_BUFFER;
    }
    release_buffer_locked(buffer);
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_buffer_info(VADriverContextP ctx, VABufferID buffer_id,
                                   VABufferType *type, unsigned int *size,
                                   unsigned int *num_elements) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVABuffer *buffer;
    if (!driver) return VA_STATUS_ERROR_INVALID_DISPLAY;
    pthread_mutex_lock(&driver->lock);
    buffer = lookup_buffer_locked(driver, buffer_id);
    if (!buffer) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_BUFFER;
    }
    if (type) *type = buffer->type;
    if (size) *size = buffer->element_size;
    if (num_elements) *num_elements = buffer->num_elements;
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
}

static VAStatus set_stream_u32(VTRVAContext *context, uint32_t *target,
                               uint32_t value) {
    if (!value || *target == value) return VA_STATUS_SUCCESS;
    if (context->client.connected) return VA_STATUS_ERROR_INVALID_PARAMETER;
    *target = value;
    context->connection_dirty = true;
    return VA_STATUS_SUCCESS;
}

static VAStatus handle_sequence_parameter_locked(VTRVAContext *context,
                                                  const VTRVAConfig *config,
                                                  const VTRVABuffer *buffer) {
    uint32_t intra_period;
    uint32_t intra_idr_period;
    uint32_t ip_period;
    uint32_t bit_rate;
    VAStatus status;
    if (!context || !config || !buffer || !buffer->data)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    if (!is_hevc_profile(config->profile)) {
        const VAEncSequenceParameterBufferH264 *sequence;
        if (buffer->size < sizeof(*sequence)) return VA_STATUS_ERROR_INVALID_BUFFER;
        sequence = (const VAEncSequenceParameterBufferH264 *)buffer->data;
        intra_period = sequence->intra_period;
        intra_idr_period = sequence->intra_idr_period;
        ip_period = sequence->ip_period;
        bit_rate = sequence->bits_per_second;
    } else {
        const VAEncSequenceParameterBufferHEVC *sequence;
        if (buffer->size < sizeof(*sequence)) return VA_STATUS_ERROR_INVALID_BUFFER;
        sequence = (const VAEncSequenceParameterBufferHEVC *)buffer->data;
        intra_period = sequence->intra_period;
        intra_idr_period = sequence->intra_idr_period;
        ip_period = sequence->ip_period;
        bit_rate = sequence->bits_per_second;
    }
    if (ip_period > 1) return VA_STATUS_ERROR_INVALID_PARAMETER;
    status = set_stream_u32(context, &context->gop_size,
                            intra_idr_period ? intra_idr_period : intra_period);
    if (status != VA_STATUS_SUCCESS) return status;
    status = set_stream_u32(context, &context->bit_rate, bit_rate);
    if (status != VA_STATUS_SUCCESS) return status;
    return set_stream_u32(context, &context->max_rate, bit_rate);
}

static VAStatus handle_picture_parameter_locked(VTRVADriver *driver,
                                                 VTRVAContext *context,
                                                 const VTRVAConfig *config,
                                                 const VTRVABuffer *buffer) {
    VABufferID coded_id;
    VTRVABuffer *coded;
    bool force_keyframe;
    if (!driver || !context || !config || !buffer || !buffer->data)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    if (!is_hevc_profile(config->profile)) {
        const VAEncPictureParameterBufferH264 *picture;
        if (buffer->size < sizeof(*picture)) return VA_STATUS_ERROR_INVALID_BUFFER;
        picture = (const VAEncPictureParameterBufferH264 *)buffer->data;
        coded_id = picture->coded_buf;
        force_keyframe = picture->pic_fields.bits.idr_pic_flag != 0;
    } else {
        const VAEncPictureParameterBufferHEVC *picture;
        if (buffer->size < sizeof(*picture)) return VA_STATUS_ERROR_INVALID_BUFFER;
        picture = (const VAEncPictureParameterBufferHEVC *)buffer->data;
        coded_id = picture->coded_buf;
        force_keyframe = picture->pic_fields.bits.idr_pic_flag != 0;
    }
    coded = lookup_buffer_locked(driver, coded_id);
    if (!coded || coded->type != VAEncCodedBufferType ||
        coded->context_id != context->id) return VA_STATUS_ERROR_INVALID_BUFFER;
    context->pending_coded_buffer = coded_id;
    context->force_keyframe = force_keyframe;
    return VA_STATUS_SUCCESS;
}

static VAStatus handle_misc_parameter_locked(VTRVAContext *context,
                                              const VTRVABuffer *buffer) {
    const VAEncMiscParameterBuffer *header;
    const uint8_t *payload;
    size_t payload_size;
    VAStatus status;
    if (!context || !buffer || buffer->size < sizeof(VAEncMiscParameterType))
        return VA_STATUS_ERROR_INVALID_BUFFER;
    header = (const VAEncMiscParameterBuffer *)buffer->data;
    payload = buffer->data + sizeof(VAEncMiscParameterType);
    payload_size = buffer->size - sizeof(VAEncMiscParameterType);
    if (header->type == VAEncMiscParameterTypeRateControl) {
        const VAEncMiscParameterRateControl *rate;
        uint64_t target;
        if (payload_size < sizeof(*rate)) return VA_STATUS_ERROR_INVALID_BUFFER;
        rate = (const VAEncMiscParameterRateControl *)payload;
        target = rate->bits_per_second;
        if (!context->constant_bit_rate && rate->target_percentage > 0 &&
            rate->target_percentage <= 100)
            target = target * rate->target_percentage / 100U;
        status = set_stream_u32(context, &context->max_rate,
                                rate->bits_per_second);
        if (status != VA_STATUS_SUCCESS) return status;
        return set_stream_u32(context, &context->bit_rate, (uint32_t)target);
    } else if (header->type == VAEncMiscParameterTypeFrameRate) {
        const VAEncMiscParameterFrameRate *rate;
        uint32_t numerator;
        uint32_t denominator;
        if (payload_size < sizeof(*rate)) return VA_STATUS_ERROR_INVALID_BUFFER;
        rate = (const VAEncMiscParameterFrameRate *)payload;
        numerator = rate->framerate & 0xffffU;
        denominator = rate->framerate >> 16;
        if (!denominator) {
            denominator = 1;
        }
        if (numerator && denominator) {
            status = set_stream_u32(context, &context->frame_rate_num, numerator);
            if (status != VA_STATUS_SUCCESS) return status;
            return set_stream_u32(context, &context->frame_rate_den, denominator);
        }
    }
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_begin_picture(VADriverContextP ctx, VAContextID context_id,
                                     VASurfaceID render_target) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVAContext *context;
    VTRVASurface *surface;
    if (!driver) return VA_STATUS_ERROR_INVALID_DISPLAY;
    pthread_mutex_lock(&driver->lock);
    context = lookup_context_locked(driver, context_id);
    surface = lookup_surface_locked(driver, render_target);
    if (!context) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_CONTEXT;
    }
    if (!surface) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_SURFACE;
    }
    if (context->current_surface != VA_INVALID_SURFACE) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_CONTEXT;
    }
    /* FFmpeg aligns the VA encode context (and reconstruction surfaces) to
       codec block boundaries, while the input upload surface retains visible
       dimensions.  A smaller input surface is therefore valid. */
    if ((int)surface->width > context->width ||
        (int)surface->height > context->height) {
        vtrva_log(driver, true,
                  "begin-picture surface exceeds context: context %#x=%dx%d surface %#x=%ux%u",
                  context_id, context->width, context->height, render_target,
                  surface->width, surface->height);
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    }
    context->current_surface = render_target;
    surface->status = VASurfaceRendering;
    surface->last_error = VA_STATUS_SUCCESS;
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_render_picture(VADriverContextP ctx, VAContextID context_id,
                                      VABufferID *buffers, int num_buffers) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVAContext *context;
    VTRVAConfig *config;
    VAStatus status = VA_STATUS_SUCCESS;
    int i;
    if (!driver || num_buffers < 0 || (num_buffers && !buffers))
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    pthread_mutex_lock(&driver->lock);
    context = lookup_context_locked(driver, context_id);
    if (!context) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_CONTEXT;
    }
    if (context->current_surface == VA_INVALID_SURFACE) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_CONTEXT;
    }
    config = lookup_config_locked(driver, context->config_id);
    if (!config) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_CONFIG;
    }
    for (i = 0; i < num_buffers; ++i) {
        VTRVABuffer *buffer = lookup_buffer_locked(driver, buffers[i]);
        if (!buffer || buffer->context_id != context_id) {
            pthread_mutex_unlock(&driver->lock);
            return VA_STATUS_ERROR_INVALID_BUFFER;
        }
        if (buffer->type == VAEncSequenceParameterBufferType)
            status = handle_sequence_parameter_locked(context, config, buffer);
        else if (buffer->type == VAEncPictureParameterBufferType)
            status = handle_picture_parameter_locked(driver, context, config, buffer);
        else if (buffer->type == VAEncMiscParameterBufferType)
            status = handle_misc_parameter_locked(context, buffer);
        if (status != VA_STATUS_SUCCESS) {
            pthread_mutex_unlock(&driver->lock);
            return status;
        }
    }
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
}

static int ensure_remote_connection(VTRVADriver *driver, VTRVAContext *context,
                                     VTRVAConfig *config, VTRVASurface *surface,
                                     char *error, size_t error_size) {
    VTRClientConfig client_config;
    VTRPixelFormat pixel_format;
    int rc;
    if (!driver || !context || !config || !surface) return -EINVAL;
    if (context->session_failed) return -EPIPE;
    pixel_format = surface->fourcc == VA_FOURCC_P010 ? VTR_PIXFMT_P010
                                                      : VTR_PIXFMT_NV12;
    if (context->client.connected && !context->connection_dirty)
        return 0;
    if (context->client_initialized) vtr_client_destroy(&context->client);
    vtr_client_init(&context->client);
    context->client_initialized = true;
    memset(&client_config, 0, sizeof(client_config));
    client_config.endpoint = env_string("VTREMOTE_HOST", NULL);
    if (!client_config.endpoint) {
        snprintf(error, error_size, "VTREMOTE_HOST is required");
        return -EINVAL;
    }
    client_config.token = env_string("VTREMOTE_TOKEN", "");
    client_config.codec = codec_for_profile(config->profile);
    client_config.width = surface->width;
    client_config.height = surface->height;
    client_config.pixel_format = pixel_format;
    client_config.frame_rate_num = context->frame_rate_num;
    client_config.frame_rate_den = context->frame_rate_den;
    client_config.bit_rate = context->bit_rate;
    client_config.max_rate = context->max_rate;
    client_config.gop_size = context->gop_size;
    client_config.max_b_frames = 0;
    client_config.profile = ffmpeg_profile_for_va_profile(config->profile);
    client_config.realtime = context->realtime;
    client_config.constant_bit_rate = context->constant_bit_rate;
    client_config.timeout_ms = context->timeout_ms;
    client_config.wire_compression = context->wire_compression;
    rc = vtr_client_connect(&context->client, &client_config, error, error_size);
    if (rc == 0) {
        context->connection_dirty = false;
        vtrva_log(driver, false,
                  "connected context %#x to %s (%s %ux%u %s)", context->id,
                  client_config.endpoint, client_config.codec, surface->width,
                  surface->height,
                  pixel_format == VTR_PIXFMT_P010 ? "p010" : "nv12");
    }
    return rc;
}

static VAStatus vtrva_end_picture(VADriverContextP ctx, VAContextID context_id) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVAContext *context;
    VTRVAConfig *config;
    VTRVASurface *surface;
    VTRVABuffer *coded;
    VTRFrame frame;
    char error[512] = {0};
    int64_t packet_pts = 0;
    int64_t packet_dts = 0;
    uint32_t packet_flags = 0;
    VAStatus result = VA_STATUS_SUCCESS;
    int rc;

    if (!driver) return VA_STATUS_ERROR_INVALID_DISPLAY;
    pthread_mutex_lock(&driver->lock);
    context = lookup_context_locked(driver, context_id);
    if (!context) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_CONTEXT;
    }
    config = lookup_config_locked(driver, context->config_id);
    surface = lookup_surface_locked(driver, context->current_surface);
    coded = lookup_buffer_locked(driver, context->pending_coded_buffer);
    if (!config) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_CONFIG;
    }
    if (!surface) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_SURFACE;
    }
    if (!coded || coded->type != VAEncCodedBufferType ||
        coded->context_id != context_id) {
        surface->status = VASurfaceReady;
        surface->last_error = VA_STATUS_ERROR_INVALID_BUFFER;
        context->current_surface = VA_INVALID_SURFACE;
        context->pending_coded_buffer = VA_INVALID_ID;
        context->force_keyframe = false;
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_BUFFER;
    }
    surface->status = VASurfaceRendering;
    pthread_mutex_unlock(&driver->lock);

    pthread_mutex_lock(&context->io_lock);
    rc = ensure_remote_connection(driver, context, config, surface,
                                  error, sizeof(error));
    if (rc == 0) {
        memset(&frame, 0, sizeof(frame));
        frame.pts = (int64_t)context->frame_index;
        frame.duration = 1;
        frame.flags = (context->force_keyframe ||
                       context->frame_index % context->gop_size == 0) ? 1U : 0U;
        frame.plane_count = 2;
        frame.planes[0].data = surface->data;
        frame.planes[0].stride = surface->stride_y;
        frame.planes[0].height = surface->height;
        frame.planes[0].size = surface->stride_y * surface->height;
        frame.planes[1].data = surface->data + frame.planes[0].size;
        frame.planes[1].stride = surface->stride_uv;
        frame.planes[1].height = surface->uv_height;
        frame.planes[1].size = surface->stride_uv * surface->uv_height;
        rc = vtr_client_encode(&context->client, &frame, &context->packet,
                               &packet_pts, &packet_dts, &packet_flags,
                               error, sizeof(error));
    }
    if (rc < 0) {
        result = VA_STATUS_ERROR_ENCODING_ERROR;
        if (context->client_initialized) {
            vtr_client_destroy(&context->client);
            vtr_client_init(&context->client);
        }
        context->connection_dirty = false;
        context->session_failed = true;
        vtrva_log(driver, true, "remote encode failed for context %#x: %s (%d)",
                  context_id, error[0] ? error : strerror(-rc), rc);
    }

    pthread_mutex_lock(&driver->lock);
    /* Fixed arrays keep addresses stable.  Revalidate IDs before publishing. */
    surface = lookup_surface_locked(driver, context->current_surface);
    coded = lookup_buffer_locked(driver, context->pending_coded_buffer);
    if (result == VA_STATUS_SUCCESS && surface && coded) {
        uint8_t *next;
        if (context->packet.size > coded->capacity) {
            next = (uint8_t *)realloc(coded->data, context->packet.size);
            if (!next) {
                result = VA_STATUS_ERROR_ALLOCATION_FAILED;
            } else {
                coded->data = next;
                coded->capacity = context->packet.size;
            }
        }
        if (result == VA_STATUS_SUCCESS) {
            memcpy(coded->data, context->packet.data, context->packet.size);
            coded->size = context->packet.size;
            memset(&coded->coded, 0, sizeof(coded->coded));
            coded->coded.size = (uint32_t)coded->size;
            coded->coded.bit_offset = 0;
            coded->coded.status = 0;
            coded->coded.buf = coded->data;
            coded->coded.next = NULL;
            context->frame_index++;
            vtrva_log(driver, false,
                      "encoded surface %#x -> buffer %#x (%zu bytes, pts=%" PRId64
                      ", dts=%" PRId64 ", flags=%#x)",
                      surface->id, coded->id, coded->size,
                      packet_pts, packet_dts, packet_flags);
        }
    }
    if (surface) {
        surface->status = VASurfaceReady;
        surface->last_error = result;
    }
    context->current_surface = VA_INVALID_SURFACE;
    context->pending_coded_buffer = VA_INVALID_ID;
    context->force_keyframe = false;
    pthread_mutex_unlock(&driver->lock);
    pthread_mutex_unlock(&context->io_lock);
    return result;
}

static VAStatus vtrva_sync_surface(VADriverContextP ctx,
                                    VASurfaceID surface_id) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVASurface *surface;
    VAStatus status;
    if (!driver) return VA_STATUS_ERROR_INVALID_DISPLAY;
    pthread_mutex_lock(&driver->lock);
    surface = lookup_surface_locked(driver, surface_id);
    if (!surface) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_SURFACE;
    }
    status = surface->last_error;
    pthread_mutex_unlock(&driver->lock);
    return status;
}

static VAStatus vtrva_sync_surface2(VADriverContextP ctx,
                                     VASurfaceID surface_id,
                                     uint64_t timeout_ns) {
    (void)timeout_ns;
    return vtrva_sync_surface(ctx, surface_id);
}

static VAStatus vtrva_query_surface_status(VADriverContextP ctx,
                                            VASurfaceID surface_id,
                                            VASurfaceStatus *status) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVASurface *surface;
    if (!driver || !status) return VA_STATUS_ERROR_INVALID_PARAMETER;
    pthread_mutex_lock(&driver->lock);
    surface = lookup_surface_locked(driver, surface_id);
    if (!surface) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_SURFACE;
    }
    *status = surface->status;
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_query_surface_error(VADriverContextP ctx,
                                           VASurfaceID surface_id,
                                           VAStatus error_status,
                                           void **error_info) {
    VTRVADriver *driver = driver_data(ctx);
    (void)error_status;
    if (!driver || !error_info) return VA_STATUS_ERROR_INVALID_PARAMETER;
    pthread_mutex_lock(&driver->lock);
    if (!lookup_surface_locked(driver, surface_id)) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_SURFACE;
    }
    *error_info = NULL;
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_sync_buffer(VADriverContextP ctx, VABufferID buffer_id,
                                   uint64_t timeout_ns) {
    VTRVADriver *driver = driver_data(ctx);
    (void)timeout_ns;
    if (!driver) return VA_STATUS_ERROR_INVALID_DISPLAY;
    pthread_mutex_lock(&driver->lock);
    if (!lookup_buffer_locked(driver, buffer_id)) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_BUFFER;
    }
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_query_image_formats(VADriverContextP ctx,
                                           VAImageFormat *formats,
                                           int *num_formats) {
    (void)ctx;
    if (!num_formats) return VA_STATUS_ERROR_INVALID_PARAMETER;
    if (formats) {
        fill_image_format(VA_FOURCC_NV12, &formats[0]);
        fill_image_format(VA_FOURCC_P010, &formats[1]);
    }
    *num_formats = 2;
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_create_image(VADriverContextP ctx, VAImageFormat *format,
                                    int width, int height, VAImage *image) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVAImageObject *object;
    VTRVABuffer *buffer;
    uint32_t bytes_per_sample;
    uint32_t stride;
    uint32_t uv_height;
    uint64_t data_size;
    if (!driver || !format || !image || width <= 0 || height <= 0 ||
        width > (int)VTRVA_MAX_DIMENSION || height > (int)VTRVA_MAX_DIMENSION)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    if (format->fourcc != VA_FOURCC_NV12 && format->fourcc != VA_FOURCC_P010)
        return VA_STATUS_ERROR_INVALID_IMAGE_FORMAT;
    bytes_per_sample = format->fourcc == VA_FOURCC_P010 ? 2U : 1U;
    stride = align_up_u32((uint32_t)width * bytes_per_sample, 64U);
    uv_height = ((uint32_t)height + 1U) / 2U;
    data_size = (uint64_t)stride * (uint32_t)height + (uint64_t)stride * uv_height;
    if (data_size > UINT32_MAX) return VA_STATUS_ERROR_ALLOCATION_FAILED;

    pthread_mutex_lock(&driver->lock);
    object = alloc_image_locked(driver);
    buffer = alloc_buffer_locked(driver);
    if (!object || !buffer) {
        if (object) memset(object, 0, sizeof(*object));
        if (buffer) memset(buffer, 0, sizeof(*buffer));
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_MAX_NUM_EXCEEDED;
    }
    buffer->context_id = VA_INVALID_ID;
    buffer->type = VAImageBufferType;
    buffer->element_size = 1;
    buffer->num_elements = (unsigned int)data_size;
    buffer->size = (size_t)data_size;
    buffer->capacity = (size_t)data_size;
    buffer->data = (uint8_t *)calloc(1, (size_t)data_size);
    if (!buffer->data) {
        memset(object, 0, sizeof(*object));
        memset(buffer, 0, sizeof(*buffer));
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    }
    fill_image_descriptor(&object->image, object->id, buffer->id,
                          format->fourcc, (uint32_t)width, (uint32_t)height,
                          stride, stride, (size_t)data_size);
    *image = object->image;
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_derive_image(VADriverContextP ctx, VASurfaceID surface_id,
                                    VAImage *image) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVASurface *surface;
    VTRVAImageObject *object;
    VTRVABuffer *buffer;
    if (!driver || !image) return VA_STATUS_ERROR_INVALID_PARAMETER;
    pthread_mutex_lock(&driver->lock);
    surface = lookup_surface_locked(driver, surface_id);
    if (!surface) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_SURFACE;
    }
    object = alloc_image_locked(driver);
    buffer = alloc_buffer_locked(driver);
    if (!object || !buffer) {
        if (object) memset(object, 0, sizeof(*object));
        if (buffer) memset(buffer, 0, sizeof(*buffer));
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_MAX_NUM_EXCEEDED;
    }
    buffer->context_id = VA_INVALID_ID;
    buffer->type = VAImageBufferType;
    buffer->element_size = 1;
    buffer->num_elements = (unsigned int)surface->data_size;
    buffer->size = surface->data_size;
    buffer->capacity = surface->data_size;
    buffer->data = surface->data;
    buffer->owns_data = false;
    object->derived = true;
    object->surface_id = surface_id;
    fill_image_descriptor(&object->image, object->id, buffer->id,
                          surface->fourcc, surface->width, surface->height,
                          surface->stride_y, surface->stride_uv,
                          surface->data_size);
    *image = object->image;
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_destroy_image(VADriverContextP ctx, VAImageID image_id) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVAImageObject *image;
    VTRVABuffer *buffer;
    if (!driver) return VA_STATUS_ERROR_INVALID_DISPLAY;
    pthread_mutex_lock(&driver->lock);
    image = lookup_image_locked(driver, image_id);
    if (!image) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_IMAGE;
    }
    buffer = lookup_buffer_locked(driver, image->image.buf);
    if (buffer) release_buffer_locked(buffer);
    memset(image, 0, sizeof(*image));
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
}

static VAStatus copy_between_surface_and_image_locked(VTRVADriver *driver,
                                                       VTRVASurface *surface,
                                                       VTRVAImageObject *image,
                                                       bool image_to_surface) {
    VTRVABuffer *buffer = lookup_buffer_locked(driver, image->image.buf);
    uint8_t *surface_y;
    uint8_t *surface_uv;
    uint8_t *image_y;
    uint8_t *image_uv;
    uint32_t row_bytes;
    uint32_t y;
    if (!buffer || !buffer->data) return VA_STATUS_ERROR_INVALID_BUFFER;
    if (surface->fourcc != image->image.format.fourcc ||
        surface->width != image->image.width || surface->height != image->image.height)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    surface_y = surface->data;
    surface_uv = surface->data + surface->stride_y * surface->height;
    image_y = buffer->data + image->image.offsets[0];
    image_uv = buffer->data + image->image.offsets[1];
    row_bytes = surface->width * (surface->fourcc == VA_FOURCC_P010 ? 2U : 1U);
    for (y = 0; y < surface->height; ++y) {
        if (image_to_surface)
            memcpy(surface_y + y * surface->stride_y,
                   image_y + y * image->image.pitches[0], row_bytes);
        else
            memcpy(image_y + y * image->image.pitches[0],
                   surface_y + y * surface->stride_y, row_bytes);
    }
    for (y = 0; y < surface->uv_height; ++y) {
        if (image_to_surface)
            memcpy(surface_uv + y * surface->stride_uv,
                   image_uv + y * image->image.pitches[1], row_bytes);
        else
            memcpy(image_uv + y * image->image.pitches[1],
                   surface_uv + y * surface->stride_uv, row_bytes);
    }
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_get_image(VADriverContextP ctx, VASurfaceID surface_id,
                                 int x, int y, unsigned int width,
                                 unsigned int height, VAImageID image_id) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVASurface *surface;
    VTRVAImageObject *image;
    VAStatus status;
    if (!driver || x != 0 || y != 0) return VA_STATUS_ERROR_INVALID_PARAMETER;
    pthread_mutex_lock(&driver->lock);
    surface = lookup_surface_locked(driver, surface_id);
    image = lookup_image_locked(driver, image_id);
    if (!surface) status = VA_STATUS_ERROR_INVALID_SURFACE;
    else if (!image) status = VA_STATUS_ERROR_INVALID_IMAGE;
    else if (width != surface->width || height != surface->height)
        status = VA_STATUS_ERROR_INVALID_PARAMETER;
    else status = copy_between_surface_and_image_locked(driver, surface, image, false);
    pthread_mutex_unlock(&driver->lock);
    return status;
}

static VAStatus vtrva_put_image(VADriverContextP ctx, VASurfaceID surface_id,
                                 VAImageID image_id, int src_x, int src_y,
                                 unsigned int src_width, unsigned int src_height,
                                 int dest_x, int dest_y, unsigned int dest_width,
                                 unsigned int dest_height) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVASurface *surface;
    VTRVAImageObject *image;
    VAStatus status;
    if (!driver || src_x != 0 || src_y != 0 || dest_x != 0 || dest_y != 0)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    pthread_mutex_lock(&driver->lock);
    surface = lookup_surface_locked(driver, surface_id);
    image = lookup_image_locked(driver, image_id);
    if (!surface) status = VA_STATUS_ERROR_INVALID_SURFACE;
    else if (!image) status = VA_STATUS_ERROR_INVALID_IMAGE;
    else if (src_width != surface->width || src_height != surface->height ||
             dest_width != surface->width || dest_height != surface->height)
        status = VA_STATUS_ERROR_INVALID_PARAMETER;
    else status = copy_between_surface_and_image_locked(driver, surface, image, true);
    pthread_mutex_unlock(&driver->lock);
    return status;
}

static VAStatus vtrva_lock_surface(VADriverContextP ctx, VASurfaceID surface_id,
                                    unsigned int *fourcc,
                                    unsigned int *luma_stride,
                                    unsigned int *chroma_u_stride,
                                    unsigned int *chroma_v_stride,
                                    unsigned int *luma_offset,
                                    unsigned int *chroma_u_offset,
                                    unsigned int *chroma_v_offset,
                                    unsigned int *buffer_name,
                                    void **buffer) {
    VTRVADriver *driver = driver_data(ctx);
    VTRVASurface *surface;
    if (!driver) return VA_STATUS_ERROR_INVALID_DISPLAY;
    pthread_mutex_lock(&driver->lock);
    surface = lookup_surface_locked(driver, surface_id);
    if (!surface) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_SURFACE;
    }
    if (fourcc) *fourcc = surface->fourcc;
    if (luma_stride) *luma_stride = surface->stride_y;
    if (chroma_u_stride) *chroma_u_stride = surface->stride_uv;
    if (chroma_v_stride) *chroma_v_stride = surface->stride_uv;
    if (luma_offset) *luma_offset = 0;
    if (chroma_u_offset) *chroma_u_offset = surface->stride_y * surface->height;
    if (chroma_v_offset) *chroma_v_offset = surface->stride_y * surface->height;
    if (buffer_name) *buffer_name = 0;
    if (buffer) *buffer = surface->data;
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_unlock_surface(VADriverContextP ctx,
                                      VASurfaceID surface_id) {
    VTRVADriver *driver = driver_data(ctx);
    if (!driver) return VA_STATUS_ERROR_INVALID_DISPLAY;
    pthread_mutex_lock(&driver->lock);
    if (!lookup_surface_locked(driver, surface_id)) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_INVALID_SURFACE;
    }
    pthread_mutex_unlock(&driver->lock);
    return VA_STATUS_SUCCESS;
}

/* Required but intentionally unsupported presentation/subpicture/display APIs. */
static VAStatus vtrva_put_surface(VADriverContextP ctx, VASurfaceID surface,
                                   void *draw, short srcx, short srcy,
                                   unsigned short srcw, unsigned short srch,
                                   short destx, short desty,
                                   unsigned short destw, unsigned short desth,
                                   VARectangle *cliprects,
                                   unsigned int number_cliprects,
                                   unsigned int flags) {
    (void)ctx; (void)surface; (void)draw; (void)srcx; (void)srcy; (void)srcw;
    (void)srch; (void)destx; (void)desty; (void)destw; (void)desth;
    (void)cliprects; (void)number_cliprects; (void)flags;
    return VA_STATUS_ERROR_UNIMPLEMENTED;
}

static VAStatus vtrva_set_image_palette(VADriverContextP ctx, VAImageID image,
                                         unsigned char *palette) {
    (void)ctx; (void)image; (void)palette;
    return VA_STATUS_ERROR_UNIMPLEMENTED;
}

static VAStatus vtrva_query_subpicture_formats(VADriverContextP ctx,
                                                VAImageFormat *formats,
                                                unsigned int *flags,
                                                unsigned int *num_formats) {
    (void)ctx; (void)formats; (void)flags;
    if (!num_formats) return VA_STATUS_ERROR_INVALID_PARAMETER;
    *num_formats = 0;
    return VA_STATUS_SUCCESS;
}

#define STUB_SUBPICTURE(name, signature, args) \
    static VAStatus name signature { args; return VA_STATUS_ERROR_UNIMPLEMENTED; }
STUB_SUBPICTURE(vtrva_create_subpicture,
    (VADriverContextP ctx, VAImageID image, VASubpictureID *subpicture),
    (void)ctx; (void)image; (void)subpicture)
STUB_SUBPICTURE(vtrva_destroy_subpicture,
    (VADriverContextP ctx, VASubpictureID subpicture),
    (void)ctx; (void)subpicture)
STUB_SUBPICTURE(vtrva_set_subpicture_image,
    (VADriverContextP ctx, VASubpictureID subpicture, VAImageID image),
    (void)ctx; (void)subpicture; (void)image)
STUB_SUBPICTURE(vtrva_set_subpicture_chromakey,
    (VADriverContextP ctx, VASubpictureID subpicture, unsigned int min,
     unsigned int max, unsigned int mask),
    (void)ctx; (void)subpicture; (void)min; (void)max; (void)mask)
STUB_SUBPICTURE(vtrva_set_subpicture_global_alpha,
    (VADriverContextP ctx, VASubpictureID subpicture, float alpha),
    (void)ctx; (void)subpicture; (void)alpha)
STUB_SUBPICTURE(vtrva_associate_subpicture,
    (VADriverContextP ctx, VASubpictureID subpicture, VASurfaceID *surfaces,
     int count, short sx, short sy, unsigned short sw, unsigned short sh,
     short dx, short dy, unsigned short dw, unsigned short dh, unsigned int flags),
    (void)ctx; (void)subpicture; (void)surfaces; (void)count; (void)sx;
    (void)sy; (void)sw; (void)sh; (void)dx; (void)dy; (void)dw; (void)dh;
    (void)flags)
STUB_SUBPICTURE(vtrva_deassociate_subpicture,
    (VADriverContextP ctx, VASubpictureID subpicture, VASurfaceID *surfaces,
     int count),
    (void)ctx; (void)subpicture; (void)surfaces; (void)count)
#undef STUB_SUBPICTURE

static VAStatus vtrva_query_display_attributes(VADriverContextP ctx,
                                                VADisplayAttribute *attributes,
                                                int *num_attributes) {
    (void)ctx; (void)attributes;
    if (!num_attributes) return VA_STATUS_ERROR_INVALID_PARAMETER;
    *num_attributes = 0;
    return VA_STATUS_SUCCESS;
}

static VAStatus vtrva_get_display_attributes(VADriverContextP ctx,
                                              VADisplayAttribute *attributes,
                                              int num_attributes) {
    (void)ctx; (void)attributes;
    return num_attributes == 0 ? VA_STATUS_SUCCESS : VA_STATUS_ERROR_UNIMPLEMENTED;
}

static VAStatus vtrva_set_display_attributes(VADriverContextP ctx,
                                              VADisplayAttribute *attributes,
                                              int num_attributes) {
    (void)ctx; (void)attributes;
    return num_attributes == 0 ? VA_STATUS_SUCCESS : VA_STATUS_ERROR_UNIMPLEMENTED;
}

static VAStatus vtrva_acquire_buffer_handle(VADriverContextP ctx,
                                             VABufferID buffer_id,
                                             VABufferInfo *info) {
    (void)ctx; (void)buffer_id; (void)info;
    return VA_STATUS_ERROR_UNSUPPORTED_MEMORY_TYPE;
}
static VAStatus vtrva_release_buffer_handle(VADriverContextP ctx,
                                             VABufferID buffer_id) {
    (void)ctx; (void)buffer_id;
    return VA_STATUS_ERROR_UNSUPPORTED_MEMORY_TYPE;
}
static VAStatus vtrva_create_mf_context(VADriverContextP ctx,
                                         VAMFContextID *id) {
    (void)ctx; (void)id; return VA_STATUS_ERROR_UNIMPLEMENTED;
}
static VAStatus vtrva_mf_add_context(VADriverContextP ctx, VAMFContextID mf,
                                      VAContextID context) {
    (void)ctx; (void)mf; (void)context; return VA_STATUS_ERROR_UNIMPLEMENTED;
}
static VAStatus vtrva_mf_release_context(VADriverContextP ctx, VAMFContextID mf,
                                          VAContextID context) {
    (void)ctx; (void)mf; (void)context; return VA_STATUS_ERROR_UNIMPLEMENTED;
}
static VAStatus vtrva_mf_submit(VADriverContextP ctx, VAMFContextID mf,
                                 VAContextID *contexts, int count) {
    (void)ctx; (void)mf; (void)contexts; (void)count;
    return VA_STATUS_ERROR_UNIMPLEMENTED;
}
static VAStatus vtrva_create_buffer2(VADriverContextP ctx, VAContextID context,
                                      VABufferType type, unsigned int width,
                                      unsigned int height,
                                      unsigned int *unit_size,
                                      unsigned int *pitch,
                                      VABufferID *buffer_id) {
    (void)ctx; (void)context; (void)type; (void)width; (void)height;
    (void)unit_size; (void)pitch; (void)buffer_id;
    return VA_STATUS_ERROR_UNIMPLEMENTED;
}
static VAStatus vtrva_query_processing_rate(VADriverContextP ctx,
                                             VAConfigID config,
                                             VAProcessingRateParameter *parameter,
                                             unsigned int *rate) {
    (void)ctx; (void)config; (void)parameter; (void)rate;
    return VA_STATUS_ERROR_UNIMPLEMENTED;
}
static VAStatus vtrva_export_surface_handle(VADriverContextP ctx,
                                             VASurfaceID surface,
                                             uint32_t memory_type,
                                             uint32_t flags,
                                             void *descriptor) {
    (void)ctx; (void)surface; (void)memory_type; (void)flags; (void)descriptor;
    return VA_STATUS_ERROR_UNSUPPORTED_MEMORY_TYPE;
}
static VAStatus vtrva_copy(VADriverContextP ctx, VACopyObject *dst,
                            VACopyObject *src, VACopyOption option) {
    (void)ctx; (void)dst; (void)src; (void)option;
    return VA_STATUS_ERROR_UNIMPLEMENTED;
}

static void populate_vtable(struct VADriverVTable *vtable) {
    memset(vtable, 0, sizeof(*vtable));
    vtable->vaTerminate = vtrva_terminate;
    vtable->vaQueryConfigProfiles = vtrva_query_config_profiles;
    vtable->vaQueryConfigEntrypoints = vtrva_query_config_entrypoints;
    vtable->vaGetConfigAttributes = vtrva_get_config_attributes;
    vtable->vaCreateConfig = vtrva_create_config;
    vtable->vaDestroyConfig = vtrva_destroy_config;
    vtable->vaQueryConfigAttributes = vtrva_query_config_attributes;
    vtable->vaCreateSurfaces = vtrva_create_surfaces;
    vtable->vaDestroySurfaces = vtrva_destroy_surfaces;
    vtable->vaCreateContext = vtrva_create_context;
    vtable->vaDestroyContext = vtrva_destroy_context;
    vtable->vaCreateBuffer = vtrva_create_buffer;
    vtable->vaBufferSetNumElements = vtrva_buffer_set_num_elements;
    vtable->vaMapBuffer = vtrva_map_buffer;
    vtable->vaUnmapBuffer = vtrva_unmap_buffer;
    vtable->vaDestroyBuffer = vtrva_destroy_buffer;
    vtable->vaBeginPicture = vtrva_begin_picture;
    vtable->vaRenderPicture = vtrva_render_picture;
    vtable->vaEndPicture = vtrva_end_picture;
    vtable->vaSyncSurface = vtrva_sync_surface;
    vtable->vaQuerySurfaceStatus = vtrva_query_surface_status;
    vtable->vaQuerySurfaceError = vtrva_query_surface_error;
    vtable->vaPutSurface = vtrva_put_surface;
    vtable->vaQueryImageFormats = vtrva_query_image_formats;
    vtable->vaCreateImage = vtrva_create_image;
    vtable->vaDeriveImage = vtrva_derive_image;
    vtable->vaDestroyImage = vtrva_destroy_image;
    vtable->vaSetImagePalette = vtrva_set_image_palette;
    vtable->vaGetImage = vtrva_get_image;
    vtable->vaPutImage = vtrva_put_image;
    vtable->vaQuerySubpictureFormats = vtrva_query_subpicture_formats;
    vtable->vaCreateSubpicture = vtrva_create_subpicture;
    vtable->vaDestroySubpicture = vtrva_destroy_subpicture;
    vtable->vaSetSubpictureImage = vtrva_set_subpicture_image;
    vtable->vaSetSubpictureChromakey = vtrva_set_subpicture_chromakey;
    vtable->vaSetSubpictureGlobalAlpha = vtrva_set_subpicture_global_alpha;
    vtable->vaAssociateSubpicture = vtrva_associate_subpicture;
    vtable->vaDeassociateSubpicture = vtrva_deassociate_subpicture;
    vtable->vaQueryDisplayAttributes = vtrva_query_display_attributes;
    vtable->vaGetDisplayAttributes = vtrva_get_display_attributes;
    vtable->vaSetDisplayAttributes = vtrva_set_display_attributes;
    vtable->vaBufferInfo = vtrva_buffer_info;
    vtable->vaLockSurface = vtrva_lock_surface;
    vtable->vaUnlockSurface = vtrva_unlock_surface;
    vtable->vaGetSurfaceAttributes = vtrva_get_surface_attributes;
    vtable->vaCreateSurfaces2 = vtrva_create_surfaces2;
    vtable->vaQuerySurfaceAttributes = vtrva_query_surface_attributes;
    vtable->vaAcquireBufferHandle = vtrva_acquire_buffer_handle;
    vtable->vaReleaseBufferHandle = vtrva_release_buffer_handle;
    vtable->vaCreateMFContext = vtrva_create_mf_context;
    vtable->vaMFAddContext = vtrva_mf_add_context;
    vtable->vaMFReleaseContext = vtrva_mf_release_context;
    vtable->vaMFSubmit = vtrva_mf_submit;
    vtable->vaCreateBuffer2 = vtrva_create_buffer2;
    vtable->vaQueryProcessingRate = vtrva_query_processing_rate;
    vtable->vaExportSurfaceHandle = vtrva_export_surface_handle;
    vtable->vaSyncSurface2 = vtrva_sync_surface2;
    vtable->vaSyncBuffer = vtrva_sync_buffer;
    vtable->vaCopy = vtrva_copy;
    vtable->vaMapBuffer2 = vtrva_map_buffer2;
}

#if defined(__GNUC__)
#define VTRVA_EXPORT __attribute__((visibility("default")))
#else
#define VTRVA_EXPORT
#endif

/* libva 2.22 (VA-API 1.22) entrypoint.  Newer libva releases probe older
 * compatible minor versions in descending order, so this remains loadable. */
VTRVA_EXPORT VAStatus __vaDriverInit_1_22(VADriverContextP ctx) {
    VTRVADriver *driver;
    if (!ctx || !ctx->vtable) return VA_STATUS_ERROR_INVALID_DISPLAY;
    driver = (VTRVADriver *)calloc(1, sizeof(*driver));
    if (!driver) return VA_STATUS_ERROR_ALLOCATION_FAILED;
    if (pthread_mutex_init(&driver->lock, NULL) != 0) {
        free(driver);
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    }
    driver->lock_initialized = true;
    driver->va_context = ctx;
    driver->verbose = env_bool("VTREMOTE_LOG", 0) != 0;
    ctx->pDriverData = driver;
    ctx->version_major = 1;
    ctx->version_minor = 22;
    ctx->max_profiles = 5;
    ctx->max_entrypoints = 1;
    ctx->max_attributes = 64;
    ctx->max_image_formats = 2;
    ctx->max_subpic_formats = 1; /* libva requires a positive maximum */
    ctx->max_display_attributes = 1;
    ctx->str_vendor = VTRVA_VENDOR;
    populate_vtable(ctx->vtable);
    vtrva_log(driver, false, "initialized %s", VTRVA_VENDOR);
    return VA_STATUS_SUCCESS;
}
