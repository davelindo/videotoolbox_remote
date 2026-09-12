/* Private completion handling. Callers hold context->io_lock for socket I/O. */
/* Callers also hold driver->lock while publishing a completion. */
static void finish_pending_locked(VTRVAContext *context, VTRVASurface *surface, VTRVABuffer *coded,
                                  VAStatus status) {
    if (surface) {
        surface->pending_context = 0;
        surface->status = VASurfaceReady;
        surface->last_error = status;
    }
    if (coded) {
        coded->pending = false;
        coded->last_error = status;
    }
    context->pending_head = (context->pending_head + 1) % ARRAY_SIZE(context->pending);
    --context->pending_count;
}

static void abort_pending(VTRVADriver *driver, VTRVAContext *context) {
    context->session_failed = true;
    vtr_client_destroy(&context->client);
    vtr_client_init(&context->client);
    pthread_mutex_lock(&driver->lock);
    while (context->pending_count) {
        unsigned slot = context->pending_head;
        VTRVASurface *surface = lookup_surface_locked(driver, context->pending[slot].surface);
        VTRVABuffer *coded = lookup_buffer_locked(driver, context->pending[slot].coded);
        finish_pending_locked(context, surface, coded, VA_STATUS_ERROR_ENCODING_ERROR);
    }
    pthread_mutex_unlock(&driver->lock);
}

static VAStatus complete_pending(VTRVADriver *driver, VTRVAContext *context, int timeout_ms) {
    int64_t pts, dts;
    uint32_t flags;
    char error[512] = {0};
    unsigned slot = context->pending_head;
    int rc = vtr_client_receive_packet_timeout(&context->client, &context->packet, &pts, &dts,
                                               &flags, error, sizeof(error), timeout_ms);
    if (rc == -EAGAIN)
        return VA_STATUS_ERROR_TIMEDOUT;
    if (rc != 0 || pts != context->pending[slot].pts) {
        vtrva_log(driver, true, "remote completion failed: %s",
                  error[0] ? error : "unexpected packet timestamp");
        abort_pending(driver, context);
        return VA_STATUS_ERROR_ENCODING_ERROR;
    }
    pthread_mutex_lock(&driver->lock);
    VTRVASurface *surface = lookup_surface_locked(driver, context->pending[slot].surface);
    VTRVABuffer *coded = lookup_buffer_locked(driver, context->pending[slot].coded);
    VAStatus status = VA_STATUS_SUCCESS;
    if (!surface || !coded)
        status = VA_STATUS_ERROR_INVALID_BUFFER;
    if (coded && context->packet.size > coded->capacity) {
        uint8_t *next = realloc(coded->data, context->packet.size);
        if (!next)
            status = VA_STATUS_ERROR_ALLOCATION_FAILED;
        else {
            coded->data = next;
            coded->capacity = context->packet.size;
        }
    }
    if (status == VA_STATUS_SUCCESS) {
        memcpy(coded->data, context->packet.data, context->packet.size);
        coded->size = context->packet.size;
        memset(&coded->coded, 0, sizeof(coded->coded));
        coded->coded.size = (uint32_t)coded->size;
        coded->coded.buf = coded->data;
    }
    finish_pending_locked(context, surface, coded, status);
    pthread_mutex_unlock(&driver->lock);
    return status;
}

static void release_io_reference(VTRVADriver *driver, VTRVAContext *context) {
    pthread_mutex_lock(&driver->lock);
    --context->io_users;
    pthread_cond_broadcast(&context->io_idle);
    pthread_mutex_unlock(&driver->lock);
}

static void release_io_user(VTRVADriver *driver, VTRVAContext *context) {
    pthread_mutex_unlock(&context->io_lock);
    release_io_reference(driver, context);
}

static int64_t pipeline_now_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static VAStatus sync_object(VTRVADriver *driver, VASurfaceID surface_id, VABufferID buffer_id,
                            uint64_t timeout_ns) {
    VTRVAContext *context = NULL;
    VAStatus status;
    VAContextID context_id = 0;
    int64_t deadline =
        timeout_ns == VA_TIMEOUT_INFINITE
            ? INT64_MAX
            : pipeline_now_ms() + (int64_t)(timeout_ns / 1000000 + (timeout_ns % 1000000 != 0));
    pthread_mutex_lock(&driver->lock);
    if (surface_id != VA_INVALID_SURFACE) {
        VTRVASurface *surface = lookup_surface_locked(driver, surface_id);
        if (!surface) {
            pthread_mutex_unlock(&driver->lock);
            return VA_STATUS_ERROR_INVALID_SURFACE;
        }
        context_id = surface->pending_context;
        status = surface->last_error;
    } else {
        VTRVABuffer *buffer = lookup_buffer_locked(driver, buffer_id);
        if (!buffer) {
            pthread_mutex_unlock(&driver->lock);
            return VA_STATUS_ERROR_INVALID_BUFFER;
        }
        context_id = buffer->pending ? buffer->context_id : 0;
        status = buffer->last_error;
    }
    if (!context_id) {
        pthread_mutex_unlock(&driver->lock);
        return status;
    }
    context = lookup_context_locked(driver, context_id);
    if (!context) {
        pthread_mutex_unlock(&driver->lock);
        return VA_STATUS_ERROR_ENCODING_ERROR;
    }
    ++context->io_users;
    pthread_mutex_unlock(&driver->lock);
    if (timeout_ns == VA_TIMEOUT_INFINITE) {
        pthread_mutex_lock(&context->io_lock);
    } else {
        /* Include contention with another submit/sync in the caller's deadline.
         * A monotonic try-lock loop also works on the GLIBC 2.17 baseline. */
        int rc;
        while ((rc = pthread_mutex_trylock(&context->io_lock)) == EBUSY) {
            if (pipeline_now_ms() >= deadline) {
                release_io_reference(driver, context);
                return VA_STATUS_ERROR_TIMEDOUT;
            }
            struct timespec pause = {0, 1000000};
            nanosleep(&pause, NULL);
        }
        if (rc != 0) {
            release_io_reference(driver, context);
            return VA_STATUS_ERROR_OPERATION_FAILED;
        }
    }
    for (;;) {
        bool pending;
        pthread_mutex_lock(&driver->lock);
        if (surface_id != VA_INVALID_SURFACE) {
            VTRVASurface *surface = lookup_surface_locked(driver, surface_id);
            pending = surface && surface->pending_context != 0;
            status = surface ? surface->last_error : VA_STATUS_ERROR_INVALID_SURFACE;
        } else {
            VTRVABuffer *buffer = lookup_buffer_locked(driver, buffer_id);
            pending = buffer && buffer->pending;
            status = buffer ? buffer->last_error : VA_STATUS_ERROR_INVALID_BUFFER;
        }
        pthread_mutex_unlock(&driver->lock);
        if (!pending)
            break;
        int64_t remaining = deadline - pipeline_now_ms();
        int wait_ms = remaining <= 0                    ? 0
                      : remaining < context->timeout_ms ? (int)remaining
                                                        : context->timeout_ms;
        status = complete_pending(driver, context, wait_ms);
        if (status != VA_STATUS_SUCCESS)
            break;
    }
    release_io_user(driver, context);
    return status;
}
