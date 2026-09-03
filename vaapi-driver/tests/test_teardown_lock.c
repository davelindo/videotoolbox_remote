/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define _POSIX_C_SOURCE 200809L

#include "vtremote/client.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static atomic_bool flush_started;

static int test_client_flush(VTRClient *client, char *error, size_t error_size)
{
    const struct timespec delay = { .tv_sec = 0, .tv_nsec = 400000000L };

    (void)client;
    (void)error;
    (void)error_size;
    atomic_store_explicit(&flush_started, true, memory_order_release);
    nanosleep(&delay, NULL);
    return 0;
}

#define vtr_client_flush test_client_flush
#include "../src/va_driver.c"
#undef vtr_client_flush

typedef struct DestroyArgs {
    VADriverContextP va_context;
    VAContextID context_id;
    VAStatus status;
} DestroyArgs;

static void *destroy_context(void *opaque)
{
    DestroyArgs *args = opaque;

    args->status = vtrva_destroy_context(args->va_context, args->context_id);
    return NULL;
}

static double elapsed_seconds(const struct timespec *start,
                              const struct timespec *end)
{
    return (double)(end->tv_sec - start->tv_sec) +
           (double)(end->tv_nsec - start->tv_nsec) / 1000000000.0;
}

int main(void)
{
    struct VADriverContext va_context;
    VTRVADriver driver;
    VTRVAContext *context;
    VTRVASurface *surface;
    DestroyArgs args;
    pthread_t thread;
    struct timespec started;
    struct timespec finished;
    const struct timespec poll_delay = { .tv_sec = 0, .tv_nsec = 1000000L };
    VAStatus status;
    unsigned int attempts;

    memset(&va_context, 0, sizeof(va_context));
    memset(&driver, 0, sizeof(driver));
    atomic_init(&flush_started, false);
    if (pthread_mutex_init(&driver.lock, NULL) != 0)
        return 1;
    driver.lock_initialized = true;
    va_context.pDriverData = &driver;

    context = &driver.contexts[0];
    context->active = true;
    context->id = VTRVA_CONTEXT_BASE + 1U;
    if (pthread_mutex_init(&context->io_lock, NULL) != 0)
        return 1;
    context->io_lock_initialized = true;
    vtr_client_init(&context->client);
    context->client.connected = true;
    context->client_initialized = true;
    vtr_buffer_init(&context->packet);
    context->packet_initialized = true;

    surface = &driver.surfaces[0];
    surface->active = true;
    surface->id = VTRVA_SURFACE_BASE + 1U;
    surface->last_error = VA_STATUS_SUCCESS;

    args.va_context = &va_context;
    args.context_id = context->id;
    args.status = VA_STATUS_ERROR_OPERATION_FAILED;
    if (pthread_create(&thread, NULL, destroy_context, &args) != 0)
        return 1;

    for (attempts = 0; attempts < 1000; ++attempts) {
        if (atomic_load_explicit(&flush_started, memory_order_acquire))
            break;
        nanosleep(&poll_delay, NULL);
    }
    if (attempts == 1000) {
        fprintf(stderr, "context teardown did not enter flush\n");
        return 1;
    }

    clock_gettime(CLOCK_MONOTONIC, &started);
    status = vtrva_sync_surface(&va_context, surface->id);
    clock_gettime(CLOCK_MONOTONIC, &finished);
    if (status != VA_STATUS_SUCCESS ||
        elapsed_seconds(&started, &finished) >= 0.15) {
        fprintf(stderr, "unrelated driver operation blocked during flush\n");
        return 1;
    }

    if (pthread_join(thread, NULL) != 0 || args.status != VA_STATUS_SUCCESS)
        return 1;
    pthread_mutex_destroy(&driver.lock);
    puts("ok");
    return 0;
}
