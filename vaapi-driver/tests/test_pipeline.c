/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define _POSIX_C_SOURCE 200809L
#include "vtremote/client.h"
#include <assert.h>
#include <errno.h>
#include <string.h>

static int submitted, completed, reconfigured, fail_at = -1;
static int test_connect(VTRClient *client, const VTRClientConfig *config, char *error,
                        size_t size) {
    (void)config;
    (void)error;
    (void)size;
    assert(submitted == completed);
    ++reconfigured;
    client->connected = 1;
    return 0;
}
static int test_flush(VTRClient *client, char *error, size_t size) {
    (void)client;
    (void)error;
    (void)size;
    assert(submitted == completed);
    return 0;
}
static int test_send_frame(VTRClient *client, const VTRFrame *frame, char *error, size_t size) {
    (void)client;
    (void)error;
    (void)size;
    assert(frame->pts == submitted++);
    assert(frame->planes[0].data[0] == (uint8_t)frame->pts);
    assert((frame->flags & 1) == (frame->pts % 3 == 0));
    return 0;
}
static int test_receive(VTRClient *client, VTRBuffer *packet, int64_t *pts, int64_t *dts,
                        uint32_t *flags, char *error, size_t size, int timeout_ms) {
    (void)client;
    (void)error;
    (void)size;
    if (!timeout_ms)
        return -EAGAIN;
    if (completed == fail_at)
        return -ECONNRESET;
    assert(completed < submitted);
    *pts = *dts = completed++;
    *flags = 0;
    vtr_buffer_reset(packet);
    uint8_t payload = (uint8_t)*pts;
    return vtr_put_bytes(packet, &payload, 1);
}
#define vtr_client_send_frame test_send_frame
#define vtr_client_receive_packet_timeout test_receive
#define vtr_client_connect test_connect
#define vtr_client_flush test_flush
#include "../src/va_driver.c"
#undef vtr_client_send_frame
#undef vtr_client_receive_packet_timeout
#undef vtr_client_connect
#undef vtr_client_flush

int main(void) {
    VTRVADriver driver = {0};
    struct VADriverContext va = {0};
    va.pDriverData = &driver;
    pthread_mutex_init(&driver.lock, NULL);
    VTRVAConfig *config = &driver.configs[0];
    config->active = true;
    config->id = VTRVA_CONFIG_BASE + 1;
    config->profile = VAProfileH264High;
    VTRVAContext *context = &driver.contexts[0];
    context->active = true;
    context->id = VTRVA_CONTEXT_BASE + 1;
    context->config_id = config->id;
    context->current_surface = VA_INVALID_SURFACE;
    context->pending_coded_buffer = VA_INVALID_ID;
    context->width = context->height = 4;
    context->gop_size = 3;
    context->timeout_ms = 100;
    pthread_mutex_init(&context->io_lock, NULL);
    context->io_lock_initialized = true;
    pthread_cond_init(&context->io_idle, NULL);
    context->io_idle_initialized = true;
    vtr_client_init(&context->client);
    context->client.connected = true;
    context->client_initialized = true;
    vtr_buffer_init(&context->packet);
    context->packet_initialized = true;
    for (int i = 0; i < 20; ++i) {
        VTRVASurface *surface = &driver.surfaces[i];
        surface->active = true;
        surface->id = VTRVA_SURFACE_BASE + i + 1;
        surface->width = surface->height = surface->stride_y = surface->stride_uv = 4;
        surface->uv_height = 2;
        surface->fourcc = VA_FOURCC_NV12;
        surface->data = malloc(24);
        memset(surface->data, i, 24);
        VTRVABuffer *buffer = &driver.buffers[i];
        buffer->active = true;
        buffer->id = VTRVA_BUFFER_BASE + i + 1;
        buffer->context_id = context->id;
        buffer->type = VAEncCodedBufferType;
        buffer->owns_data = true;
        assert(vtrva_begin_picture(&va, context->id, surface->id) == VA_STATUS_SUCCESS);
        context->pending_coded_buffer = buffer->id;
        assert(vtrva_end_picture(&va, context->id) == VA_STATUS_SUCCESS);
        assert(context->pending_count <= 16);
        if (i < 16)
            assert(completed == 0); /* submission overlaps remote work */
    }
    assert(submitted == 20 && completed == 4);
    pthread_mutex_lock(&context->io_lock);
    int64_t started = pipeline_now_ms();
    assert(vtrva_sync_buffer(&va, driver.buffers[19].id, 20000000) == VA_STATUS_ERROR_TIMEDOUT);
    assert(pipeline_now_ms() - started >= 20 && pipeline_now_ms() - started < 200);
    assert(context->io_users == 0 && context->pending_count == 16);
    pthread_mutex_unlock(&context->io_lock);
    assert(vtrva_sync_buffer(&va, driver.buffers[19].id, 0) == VA_STATUS_ERROR_TIMEDOUT);
    assert(context->pending_count == 16);
    void *mapped = NULL;
    assert(vtrva_map_buffer(&va, driver.buffers[19].id, &mapped) == VA_STATUS_SUCCESS);
    assert(completed == 20 && context->pending_count == 0);
    for (int i = 0; i < 20; ++i) {
        assert(driver.surfaces[i].status == VASurfaceReady);
        assert(!driver.buffers[i].pending && driver.buffers[i].size == 1);
        assert(driver.buffers[i].data[0] == i);
    }
    vtrva_unmap_buffer(&va, driver.buffers[19].id);
    setenv("VTREMOTE_HOST", "127.0.0.1:1", 1); /* connect is stubbed */
    for (int i = 0; i < 4; ++i) {
        driver.surfaces[i].data[0] = (uint8_t)(20 + i);
        assert(vtrva_begin_picture(&va, context->id, driver.surfaces[i].id) == VA_STATUS_SUCCESS);
        context->pending_coded_buffer = driver.buffers[i].id;
        if (i == 3)
            context->connection_dirty = true;
        assert(vtrva_end_picture(&va, context->id) == VA_STATUS_SUCCESS);
    }
    assert(reconfigured == 1 && completed == 23 && context->pending_count == 1);
    assert(vtrva_sync_surface(&va, driver.surfaces[3].id) == VA_STATUS_SUCCESS);
    for (int i = 0; i < 4; ++i) {
        driver.surfaces[i].data[0] = (uint8_t)(24 + i);
        assert(vtrva_begin_picture(&va, context->id, driver.surfaces[i].id) == VA_STATUS_SUCCESS);
        context->pending_coded_buffer = driver.buffers[i].id;
        assert(vtrva_end_picture(&va, context->id) == VA_STATUS_SUCCESS);
    }
    fail_at = 25;
    assert(vtrva_sync_surface(&va, driver.surfaces[3].id) == VA_STATUS_ERROR_ENCODING_ERROR);
    assert(context->pending_count == 0);
    for (int i = 1; i < 4; ++i) {
        assert(driver.surfaces[i].last_error == VA_STATUS_ERROR_ENCODING_ERROR);
        assert(!driver.buffers[i].pending);
    }
    assert(vtrva_destroy_context(&va, context->id) == VA_STATUS_SUCCESS);
    for (int i = 0; i < 20; ++i) {
        release_buffer_locked(&driver.buffers[i]);
        release_surface_locked(&driver.surfaces[i]);
    }
    pthread_mutex_destroy(&driver.lock);
    puts("PASS bounded submission, FIFO wrap, sync/map completion, failure and teardown");
    return 0;
}
