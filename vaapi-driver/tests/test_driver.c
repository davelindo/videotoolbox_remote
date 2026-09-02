/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define _POSIX_C_SOURCE 200809L
#include <va/va.h>
#include <va/va_backend.h>
#include <va/va_enc_h264.h>
#include <va/va_enc_hevc.h>

#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK_STATUS(call) do { \
    VAStatus _status = (call); \
    if (_status != VA_STATUS_SUCCESS) { \
        fprintf(stderr, "%s failed: %#x\n", #call, (unsigned)_status); \
        goto fail; \
    } \
} while (0)

static void error_callback(VADriverContextP ctx, const char *message) {
    (void)ctx;
    fprintf(stderr, "driver error: %s", message ? message : "(null)\n");
}

static void info_callback(VADriverContextP ctx, const char *message) {
    (void)ctx;
    fprintf(stderr, "driver info: %s", message ? message : "(null)\n");
}

static int has_start_code(const uint8_t *data, size_t size) {
    return data && size >= 4 && data[0] == 0 && data[1] == 0 &&
           ((data[2] == 1) || (data[2] == 0 && data[3] == 1));
}

int main(int argc, char **argv) {
    void *module = NULL;
    VADriverInit init = NULL;
    struct VADriverContext context;
    struct VADriverVTable vtable;
    VAProfile profiles[16];
    int profile_count = 0;
    VAConfigAttrib config_attributes[2];
    VAConfigID config_id = VA_INVALID_ID;
    VASurfaceID surface_id = VA_INVALID_SURFACE;
    VAContextID encode_context = VA_INVALID_ID;
    VABufferID coded_buffer = VA_INVALID_ID;
    VABufferID picture_buffer = VA_INVALID_ID;
    VABufferID sequence_buffer = VA_INVALID_ID;
    VAImage image;
    void *image_data = NULL;
    VACodedBufferSegment *segment = NULL;
    union {
        VAEncSequenceParameterBufferH264 h264;
        VAEncSequenceParameterBufferHEVC hevc;
    } sequence;
    union {
        VAEncPictureParameterBufferH264 h264;
        VAEncPictureParameterBufferHEVC hevc;
    } picture;
    VASurfaceAttrib surface_attributes[2];
    VABufferID render_buffers[2];
    const char *codec = "h264";
    VAProfile profile = VAProfileH264High;
    uint32_t rt_format = VA_RT_FORMAT_YUV420;
    uint32_t fourcc = VA_FOURCC_NV12;
    size_t sequence_size = sizeof(sequence.h264);
    size_t picture_size = sizeof(picture.h264);
    unsigned int visible_row_bytes = 320;
    unsigned int y;
    int rc = 1;

    if (argc < 2 || argc > 3) {
        fprintf(stderr, "usage: %s /path/to/vtremote_drv_video.so "
                        "[h264|hevc|hevc10]\n", argv[0]);
        return 2;
    }
    if (argc == 3) codec = argv[2];
    if (!strcmp(codec, "hevc")) {
        profile = VAProfileHEVCMain;
        sequence_size = sizeof(sequence.hevc);
        picture_size = sizeof(picture.hevc);
    } else if (!strcmp(codec, "hevc10")) {
        profile = VAProfileHEVCMain10;
        rt_format = VA_RT_FORMAT_YUV420_10;
        fourcc = VA_FOURCC_P010;
        sequence_size = sizeof(sequence.hevc);
        picture_size = sizeof(picture.hevc);
        visible_row_bytes = 640;
    } else if (strcmp(codec, "h264")) {
        fprintf(stderr, "unsupported codec mode: %s\n", codec);
        return 2;
    }

    memset(&context, 0, sizeof(context));
    memset(&vtable, 0, sizeof(vtable));
    context.vtable = &vtable;
    context.error_callback = error_callback;
    context.info_callback = info_callback;

    module = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!module) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 2;
    }
    *(void **)(&init) = dlsym(module, "__vaDriverInit_1_22");
    if (!init) {
        fprintf(stderr, "dlsym failed: %s\n", dlerror());
        goto out;
    }
    CHECK_STATUS(init(&context));
    CHECK_STATUS(vtable.vaQueryConfigProfiles(&context, profiles, &profile_count));
    if (profile_count < 5) {
        fprintf(stderr, "expected at least five advertised profiles\n");
        goto fail;
    }

    config_attributes[0].type = VAConfigAttribRTFormat;
    config_attributes[0].value = rt_format;
    config_attributes[1].type = VAConfigAttribRateControl;
    config_attributes[1].value = VA_RC_VBR;
    CHECK_STATUS(vtable.vaCreateConfig(&context, profile,
                                       VAEntrypointEncSlice,
                                       config_attributes, 2, &config_id));

    memset(surface_attributes, 0, sizeof(surface_attributes));
    surface_attributes[0].type = VASurfaceAttribPixelFormat;
    surface_attributes[0].flags = VA_SURFACE_ATTRIB_SETTABLE;
    surface_attributes[0].value.type = VAGenericValueTypeInteger;
    surface_attributes[0].value.value.i = (int32_t)fourcc;
    surface_attributes[1].type = VASurfaceAttribMemoryType;
    surface_attributes[1].flags = VA_SURFACE_ATTRIB_SETTABLE;
    surface_attributes[1].value.type = VAGenericValueTypeInteger;
    surface_attributes[1].value.value.i = VA_SURFACE_ATTRIB_MEM_TYPE_VA;
    CHECK_STATUS(vtable.vaCreateSurfaces2(&context, rt_format,
                                          320, 180, &surface_id, 1,
                                          surface_attributes, 2));
    CHECK_STATUS(vtable.vaCreateContext(&context, config_id, 320, 180,
                                        VA_PROGRESSIVE, &surface_id, 1,
                                        &encode_context));

    memset(&image, 0, sizeof(image));
    CHECK_STATUS(vtable.vaDeriveImage(&context, surface_id, &image));
    if (image.format.fourcc != fourcc || image.num_planes != 2) {
        fprintf(stderr, "unexpected derived image layout\n");
        goto fail;
    }
    CHECK_STATUS(vtable.vaMapBuffer(&context, image.buf, &image_data));
    for (y = 0; y < image.height; ++y)
        memset((uint8_t *)image_data + image.offsets[0] + y * image.pitches[0],
               (int)(16U + y % 200U), visible_row_bytes);
    for (y = 0; y < (image.height + 1U) / 2U; ++y)
        memset((uint8_t *)image_data + image.offsets[1] + y * image.pitches[1],
               128, visible_row_bytes);
    CHECK_STATUS(vtable.vaUnmapBuffer(&context, image.buf));
    CHECK_STATUS(vtable.vaDestroyImage(&context, image.image_id));
    image.image_id = VA_INVALID_ID;

    CHECK_STATUS(vtable.vaCreateBuffer(&context, encode_context,
                                       VAEncCodedBufferType,
                                       1024 * 1024, 1, NULL,
                                       &coded_buffer));
    memset(&sequence, 0, sizeof(sequence));
    if (profile == VAProfileH264High) {
        sequence.h264.intra_period = 30;
        sequence.h264.intra_idr_period = 30;
        sequence.h264.ip_period = 1;
        sequence.h264.bits_per_second = 3000000;
    } else {
        sequence.hevc.intra_period = 30;
        sequence.hevc.intra_idr_period = 30;
        sequence.hevc.ip_period = 1;
        sequence.hevc.bits_per_second = 3000000;
    }
    CHECK_STATUS(vtable.vaCreateBuffer(&context, encode_context,
                                       VAEncSequenceParameterBufferType,
                                       (unsigned int)sequence_size, 1,
                                       &sequence, &sequence_buffer));
    memset(&picture, 0, sizeof(picture));
    if (profile == VAProfileH264High) {
        picture.h264.CurrPic.picture_id = surface_id;
        picture.h264.coded_buf = coded_buffer;
        picture.h264.pic_fields.bits.idr_pic_flag = 1;
    } else {
        picture.hevc.decoded_curr_pic.picture_id = surface_id;
        picture.hevc.coded_buf = coded_buffer;
        picture.hevc.pic_fields.bits.idr_pic_flag = 1;
    }
    CHECK_STATUS(vtable.vaCreateBuffer(&context, encode_context,
                                       VAEncPictureParameterBufferType,
                                       (unsigned int)picture_size, 1,
                                       &picture, &picture_buffer));

    CHECK_STATUS(vtable.vaBeginPicture(&context, encode_context, surface_id));
    render_buffers[0] = sequence_buffer;
    render_buffers[1] = picture_buffer;
    CHECK_STATUS(vtable.vaRenderPicture(&context, encode_context,
                                        render_buffers, 2));
    CHECK_STATUS(vtable.vaEndPicture(&context, encode_context));
    CHECK_STATUS(vtable.vaSyncSurface(&context, surface_id));
    CHECK_STATUS(vtable.vaMapBuffer(&context, coded_buffer, (void **)&segment));
    if (!segment || !segment->buf || segment->size == 0 ||
        !has_start_code((const uint8_t *)segment->buf, segment->size)) {
        fprintf(stderr, "invalid coded buffer returned by driver\n");
        goto fail;
    }
    printf("ok: codec=%s profiles=%d packet_bytes=%u first_nal=%02x\n",
           codec, profile_count, segment->size,
           ((const uint8_t *)segment->buf)[3]);
    CHECK_STATUS(vtable.vaUnmapBuffer(&context, coded_buffer));

    rc = 0;
fail:
    if (sequence_buffer != VA_INVALID_ID && context.pDriverData)
        (void)vtable.vaDestroyBuffer(&context, sequence_buffer);
    if (picture_buffer != VA_INVALID_ID && context.pDriverData)
        (void)vtable.vaDestroyBuffer(&context, picture_buffer);
    if (coded_buffer != VA_INVALID_ID && context.pDriverData)
        (void)vtable.vaDestroyBuffer(&context, coded_buffer);
    if (encode_context != VA_INVALID_ID && context.pDriverData)
        (void)vtable.vaDestroyContext(&context, encode_context);
    if (surface_id != VA_INVALID_SURFACE && context.pDriverData)
        (void)vtable.vaDestroySurfaces(&context, &surface_id, 1);
    if (config_id != VA_INVALID_ID && context.pDriverData)
        (void)vtable.vaDestroyConfig(&context, config_id);
    if (context.pDriverData && vtable.vaTerminate)
        (void)vtable.vaTerminate(&context);
out:
    if (module) dlclose(module);
    return rc;
}
