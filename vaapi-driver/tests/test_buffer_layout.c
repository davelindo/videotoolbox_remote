/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include <va/va.h>
#include <va/va_backend.h>
#include <va/va_enc_h264.h>
#include <va/va_enc_hevc.h>
#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern VAStatus __vaDriverInit_1_22(VADriverContextP ctx);
#define OK(call) assert((call) == VA_STATUS_SUCCESS)

static void submit_parameter(VADriverContextP va, VAContextID context,
                             VABufferType type, void *data, unsigned size,
                             int mapped) {
    VABufferID buffer;
    void *pointer = NULL;
    OK(va->vtable->vaCreateBuffer(va, context, type, size, 1,
                                 mapped ? NULL : data, &buffer));
    if (mapped) {
        OK(va->vtable->vaMapBuffer(va, buffer, &pointer));
        memcpy(pointer, data, size);
        OK(va->vtable->vaUnmapBuffer(va, buffer));
    }
    OK(va->vtable->vaRenderPicture(va, context, &buffer, 1));
    OK(va->vtable->vaDestroyBuffer(va, buffer));
}

static void test_parameters(VADriverContextP va, int hevc, int mapped) {
    VAConfigID config;
    VAContextID context;
    VASurfaceID surface;
    VABufferID coded, resized;
    void *pointer = NULL;
    union {
        VAEncSequenceParameterBufferH264 h264;
        VAEncSequenceParameterBufferHEVC hevc;
    } sequence = {0};
    union {
        VAEncPictureParameterBufferH264 h264;
        VAEncPictureParameterBufferHEVC hevc;
    } picture = {0};
    struct {
        VAEncMiscParameterType type;
        VAEncMiscParameterFrameRate rate;
    } fps = {0};
    struct {
        VAEncMiscParameterType type;
        VAEncMiscParameterRateControl rate;
    } bitrate = {0};
    unsigned sequence_size = hevc ? sizeof(sequence.hevc) : sizeof(sequence.h264);
    unsigned picture_size = hevc ? sizeof(picture.hevc) : sizeof(picture.h264);
    OK(va->vtable->vaCreateConfig(va, hevc ? VAProfileHEVCMain : VAProfileH264High,
                                 VAEntrypointEncSlice, NULL, 0, &config));
    OK(va->vtable->vaCreateSurfaces2(va, VA_RT_FORMAT_YUV420, 64, 64,
                                    &surface, 1, NULL, 0));
    OK(va->vtable->vaCreateContext(va, config, 64, 64, VA_PROGRESSIVE,
                                  &surface, 1, &context));
    OK(va->vtable->vaCreateBuffer(va, context, VAEncCodedBufferType,
                                 1024, 2, NULL, &coded));
    /* Allocated output capacity must never be reported as encoded bytes. */
    OK(va->vtable->vaBufferSetNumElements(va, coded, 1));
    OK(va->vtable->vaBufferSetNumElements(va, coded, 2));
    OK(va->vtable->vaMapBuffer(va, coded, &pointer));
    assert(((VACodedBufferSegment *)pointer)->size == 0);
    OK(va->vtable->vaUnmapBuffer(va, coded));
    if (hevc) {
        sequence.hevc.intra_period = sequence.hevc.intra_idr_period = 30;
        sequence.hevc.ip_period = 1;
        sequence.hevc.bits_per_second = 3000000;
        picture.hevc.coded_buf = coded;
        picture.hevc.decoded_curr_pic.picture_id = surface;
        picture.hevc.pic_fields.bits.idr_pic_flag = 1;
    } else {
        sequence.h264.intra_period = sequence.h264.intra_idr_period = 30;
        sequence.h264.ip_period = 1;
        sequence.h264.bits_per_second = 3000000;
        picture.h264.coded_buf = coded;
        picture.h264.CurrPic.picture_id = surface;
        picture.h264.pic_fields.bits.idr_pic_flag = 1;
    }
    fps.type = VAEncMiscParameterTypeFrameRate;
    fps.rate.framerate = (1001U << 16) | 30000U;
    bitrate.type = VAEncMiscParameterTypeRateControl;
    bitrate.rate.bits_per_second = 4000000;
    bitrate.rate.target_percentage = 75;
    OK(va->vtable->vaBeginPicture(va, context, surface));
    submit_parameter(va, context, VAEncSequenceParameterBufferType,
                     &sequence, sequence_size, mapped);
    submit_parameter(va, context, VAEncPictureParameterBufferType,
                     &picture, picture_size, mapped);
    submit_parameter(va, context, VAEncMiscParameterBufferType, &fps, sizeof(fps), mapped);
    submit_parameter(va, context, VAEncMiscParameterBufferType, &bitrate, sizeof(bitrate), mapped);

    /* Changing the valid count must preserve the allocation and mapped data,
     * including bytes outside the temporarily valid range. */
    OK(va->vtable->vaCreateBuffer(va, context, VAEncSequenceParameterBufferType,
                                 1, sequence_size + 16, NULL, &resized));
    OK(va->vtable->vaMapBuffer(va, resized, &pointer));
    void *original_pointer = pointer;
    memset(pointer, 0xa5, sequence_size + 16);
    memcpy(pointer, &sequence, sequence_size);
    OK(va->vtable->vaBufferSetNumElements(va, resized, sequence_size - 1));
    OK(va->vtable->vaBufferSetNumElements(va, resized, sequence_size + 16));
    OK(va->vtable->vaUnmapBuffer(va, resized));
    OK(va->vtable->vaMapBuffer(va, resized, &pointer));
    assert(pointer == original_pointer);
    assert(memcmp(pointer, &sequence, sequence_size) == 0);
    for (unsigned i = sequence_size; i < sequence_size + 16; ++i)
        assert(((uint8_t *)pointer)[i] == 0xa5);
    OK(va->vtable->vaUnmapBuffer(va, resized));
    OK(va->vtable->vaRenderPicture(va, context, &resized, 1));
    OK(va->vtable->vaBufferSetNumElements(va, resized, sequence_size - 1));
    assert(va->vtable->vaRenderPicture(va, context, &resized, 1) == VA_STATUS_ERROR_INVALID_BUFFER);
    OK(va->vtable->vaBufferSetNumElements(va, resized, 0));
    assert(va->vtable->vaRenderPicture(va, context, &resized, 1) == VA_STATUS_ERROR_INVALID_BUFFER);
    OK(va->vtable->vaBufferSetNumElements(va, resized, sequence_size));
    assert(va->vtable->vaBufferSetNumElements(va, resized, sequence_size + 17) ==
           VA_STATUS_ERROR_MAX_NUM_EXCEEDED);
    assert(va->vtable->vaBufferSetNumElements(va, resized, UINT_MAX) ==
           VA_STATUS_ERROR_MAX_NUM_EXCEEDED);
    OK(va->vtable->vaRenderPicture(va, context, &resized, 1));
    OK(va->vtable->vaDestroyBuffer(va, resized));
    /* No EndPicture: this regression tests local parameter submission only. */
    OK(va->vtable->vaDestroyContext(va, context));
    OK(va->vtable->vaDestroyBuffer(va, coded));
    OK(va->vtable->vaDestroySurfaces(va, &surface, 1));
    OK(va->vtable->vaDestroyConfig(va, config));
}

static uint8_t pixel(unsigned plane, unsigned row, unsigned column, unsigned seed) {
    return (uint8_t)(1 + (plane * 71 + row * 13 + column * 3 + seed) % 200);
}

static void image_pixels(VADriverContextP va, const VAImage *image,
                         unsigned seed, uint8_t padding, int fill) {
    void *pointer = NULL;
    unsigned sample_bytes = image->format.fourcc == VA_FOURCC_P010 ? 2 : 1;
    OK(va->vtable->vaMapBuffer(va, image->buf, &pointer));
    if (fill) memset(pointer, padding, image->data_size);
    for (unsigned plane = 0; plane < 2; ++plane) {
        unsigned rows = plane ? (image->height + 1U) / 2U : image->height;
        /* Chroma has complete interleaved U/V pairs, even for one pixel. */
        unsigned samples = plane ? image->width + (image->width % 2U) : image->width;
        unsigned bytes = samples * sample_bytes;
        assert(bytes <= image->pitches[plane]);
        for (unsigned row = 0; row < rows; ++row) {
            uint8_t *p = (uint8_t *)pointer + image->offsets[plane] + row * image->pitches[plane];
            for (unsigned column = 0; column < image->pitches[plane]; ++column) {
                uint8_t expected = column < bytes ? pixel(plane, row, column, seed) : padding;
                if (fill) p[column] = expected;
                else assert(p[column] == expected);
            }
        }
    }
    OK(va->vtable->vaUnmapBuffer(va, image->buf));
}

static void test_image(VADriverContextP va, uint32_t fourcc, unsigned width, unsigned height) {
    VASurfaceID surface;
    VAImage upload, download, derived;
    VAImageFormat format = {0};
    void *pointer = NULL;
    format.fourcc = fourcc;
    OK(va->vtable->vaCreateSurfaces2(va,
        fourcc == VA_FOURCC_P010 ? VA_RT_FORMAT_YUV420_10 : VA_RT_FORMAT_YUV420,
        width, height, &surface, 1, NULL, 0));
    OK(va->vtable->vaCreateImage(va, &format, (int)width, (int)height, &upload));
    OK(va->vtable->vaCreateImage(va, &format, (int)width, (int)height, &download));
    OK(va->vtable->vaDeriveImage(va, surface, &derived));
    image_pixels(va, &upload, 7, 0xa5, 1);
    OK(va->vtable->vaPutImage(va, surface, upload.image_id,
                             0, 0, width, height, 0, 0, width, height));
    image_pixels(va, &derived, 7, 0, 0);
    image_pixels(va, &upload, 7, 0xa5, 0);
    /* Seed the surface independently, so matching upload/download bugs cannot cancel. */
    image_pixels(va, &derived, 29, 0xb6, 1);
    OK(va->vtable->vaMapBuffer(va, download.buf, &pointer));
    memset(pointer, 0xc7, download.data_size);
    OK(va->vtable->vaUnmapBuffer(va, download.buf));
    OK(va->vtable->vaGetImage(va, surface, 0, 0, width, height, download.image_id));
    image_pixels(va, &download, 29, 0xc7, 0);
    image_pixels(va, &derived, 29, 0xb6, 0);
    OK(va->vtable->vaDestroyImage(va, derived.image_id));
    OK(va->vtable->vaDestroyImage(va, download.image_id));
    OK(va->vtable->vaDestroyImage(va, upload.image_id));
    OK(va->vtable->vaDestroySurfaces(va, &surface, 1));
}

int main(int argc, char **argv) {
    struct VADriverContext va = {0};
    struct VADriverVTable vtable = {0};
    const unsigned widths[] = {1, 2, 3, 31, 32, 33, 63, 64, 65};
    assert(argc == 2);
    va.vtable = &vtable;
    OK(__vaDriverInit_1_22(&va));
    if (!strcmp(argv[1], "parameters")) {
        for (int hevc = 0; hevc < 2; ++hevc)
            for (int mapped = 1; mapped >= 0; --mapped)
                test_parameters(&va, hevc, mapped);
        puts("PASS mapped/initialized H.264 and HEVC parameters, resizing, empty coded output");
    } else {
        assert(!strcmp(argv[1], "images"));
        for (unsigned i = 0; i < sizeof(widths) / sizeof(widths[0]); ++i)
            for (unsigned height = 1; height <= 4; ++height) {
                test_image(&va, VA_FOURCC_NV12, widths[i], height);
                test_image(&va, VA_FOURCC_P010, widths[i], height);
            }
        puts("PASS NV12/P010 upload/download, odd/even dimensions and untouched padding");
    }
    OK(vtable.vaTerminate(&va));
    return 0;
}
