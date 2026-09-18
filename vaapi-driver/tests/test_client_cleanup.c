/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "vtremote/client.h"
#include <assert.h>

static unsigned released_buffers;
static void counted_buffer_free(VTRBuffer *buffer) {
    if (buffer->data)
        ++released_buffers;
    vtr_buffer_free(buffer);
}

/* Count releases in the real client without replacing its allocator. */
#define vtr_buffer_free counted_buffer_free
#include "../src/client.c"
#undef vtr_buffer_free

int main(void) {
    VTRClient client;
    VTRBuffer packet;
    char error[256] = {0};
    VTRClientConfig config = {0};
    config.endpoint = ""; /* Stop before networking, after reconnect cleanup. */
    config.codec = "h264";
    config.width = config.height = 16;
    config.wire_compression = VTR_WIRE_COMPRESSION_NONE;
    vtr_client_init(&client);
    vtr_buffer_init(&packet);
    for (unsigned iteration = 0; iteration < 3; ++iteration) {
        int sockets[2];
        assert(vtr_buffer_reserve(&client.tx, 4096) == 0);
        assert(vtr_buffer_reserve(&client.rx, 4096) == 0);
        assert(vtr_buffer_reserve(&client.parameter_sets, 256) == 0);
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
        client.fd = sockets[0];
        client.connected = 1;
        close(sockets[1]);
        assert(vtr_client_receive_packet_timeout(&client, &packet, NULL, NULL,
                   NULL, error, sizeof(error), 100) == -ECONNRESET);
        assert(client.fd == -1 && !client.connected);
        assert(vtr_client_connect(&client, &config, error, sizeof(error)) < 0);
        assert(released_buffers == 3 * (iteration + 1));
        assert(!client.tx.data && !client.rx.data && !client.parameter_sets.data);
    }
    vtr_client_destroy(&client);
    vtr_client_destroy(&client);
    vtr_buffer_free(&packet);
    puts("PASS terminal disconnect releases buffers on reconnect; destroy is idempotent");
    return 0;
}
