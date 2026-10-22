/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "vtremote/client.h"
#include <assert.h>
#include <sys/wait.h>

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

static void send_test_message(int fd, uint16_t type, unsigned payload_size) {
    uint8_t wire[VTR_HEADER_SIZE + 200] = {0};
    assert(payload_size <= 200);
    write_be32(wire, VTR_PROTO_MAGIC);
    write_be16(wire + 4, VTR_PROTO_VERSION);
    write_be16(wire + 6, type);
    write_be32(wire + 8, payload_size);
    assert(send(fd, wire, VTR_HEADER_SIZE + payload_size, 0) ==
           (ssize_t)(VTR_HEADER_SIZE + payload_size));
}

static void test_receive_storage(void) {
    int sockets[2];
    VTRClient client;
    VTRMessage message;
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    vtr_client_init(&client);
    client.fd = sockets[0];
    for (unsigned i = 0; i < 2; ++i) {
        send_test_message(sockets[1], VTR_MSG_PACKET, 200);
        assert(receive_message_until(&client, &message, now_ms() + 100) == 0);
        assert(message.payload_size == 200 && client.rx.capacity == 256);
    }
    /* A partial body must survive another reserve and bounded receive. */
    uint8_t header[VTR_HEADER_SIZE] = {0};
    write_be32(header, VTR_PROTO_MAGIC);
    write_be16(header + 4, VTR_PROTO_VERSION);
    write_be16(header + 6, VTR_MSG_PACKET);
    write_be32(header + 8, 200);
    assert(send(sockets[1], header, sizeof(header), 0) == (ssize_t)sizeof(header));
    uint8_t body[200];
    memset(body, 0x73, sizeof(body));
    assert(send(sockets[1], body, 25, 0) == 25);
    assert(receive_message_until(&client, &message, now_ms()) == -EAGAIN);
    assert(client.rx_body_read == 25 && client.rx.capacity == 256);
    assert(send(sockets[1], body + 25, 175, 0) == 175);
    assert(receive_message_until(&client, &message, now_ms() + 100) == 0);
    assert(client.rx.capacity == 256 && memcmp(message.payload, body, 200) == 0);
    vtr_client_destroy(&client);
    close(sockets[1]);
}

static void test_done_payload(void) {
    for (unsigned payload_size = 0; payload_size <= 1; ++payload_size) {
        int sockets[2];
        VTRClient client;
        VTRBuffer packet;
        char error[256] = {0};
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
        vtr_client_init(&client);
        vtr_buffer_init(&packet);
        client.fd = sockets[0];
        client.connected = client.flushing = 1;
        send_test_message(sockets[1], VTR_MSG_DONE, payload_size);
        int rc = vtr_client_receive_packet_timeout(&client, &packet, NULL, NULL, NULL,
                                                   error, sizeof(error), 100);
        assert(rc == (payload_size ? -EPROTO : 1));
        assert(!client.connected);
        if (payload_size) assert(client.fd == -1 && strstr(error, "DONE"));
        vtr_buffer_free(&packet);
        vtr_client_destroy(&client);
        close(sockets[1]);
    }
}

static void test_send_deadline(void) {
    int sockets[2];
    int buffer_size = 4096;
    VTRClient client;
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    assert(setsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF,
                      &buffer_size, sizeof(buffer_size)) == 0);
    assert(fcntl(sockets[0], F_SETFL, O_NONBLOCK) == 0);
    assert(fcntl(sockets[1], F_SETFL, O_NONBLOCK) == 0);
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        uint8_t data[1024];
        size_t received = 0;
        int64_t deadline = now_ms() + 250;
        close(sockets[0]);
        while (now_ms() < deadline) {
            ssize_t count = recv(sockets[1], data, sizeof(data), MSG_DONTWAIT);
            if (count == 0) break;
            if (count > 0) received += (size_t)count;
            struct timespec pause = {0, 5000000};
            nanosleep(&pause, NULL);
        }
        close(sockets[1]);
        _exit(received ? 0 : 1);
    }
    close(sockets[1]);
    vtr_client_init(&client);
    client.fd = sockets[0];
    client.timeout_ms = 60;
    uint8_t *body = calloc(1, 1024 * 1024);
    assert(body);
    int64_t started = now_ms();
    int rc = send_message(&client, VTR_MSG_FRAME, body, 1024 * 1024);
    int64_t elapsed = now_ms() - started;
    free(body);
    vtr_client_destroy(&client);
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    if (rc != -ETIMEDOUT || elapsed < 40 || elapsed >= 250)
        fprintf(stderr, "send deadline: result=%d elapsed_ms=%lld\n", rc, (long long)elapsed);
    assert(rc == -ETIMEDOUT && elapsed >= 40 && elapsed < 250);
}

static void test_full_socket_pong(void) {
    int sockets[2];
    VTRClient client;
    VTRBuffer packet;
    char error[128] = {0};
    uint8_t bytes[4096] = {0};
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    assert(fcntl(sockets[0], F_SETFL, O_NONBLOCK) == 0);
    assert(fcntl(sockets[1], F_SETFL, O_NONBLOCK) == 0);
    while (send(sockets[0], bytes, sizeof(bytes), 0) > 0) {}
    assert(errno == EAGAIN || errno == EWOULDBLOCK);
    vtr_client_init(&client);
    vtr_buffer_init(&packet);
    client.fd = sockets[0];
    client.connected = 1;
    send_test_message(sockets[1], VTR_MSG_PING, 0);
    assert(vtr_client_receive_packet_timeout(&client, &packet, NULL, NULL, NULL,
                                               error, sizeof(error), 0) == -EAGAIN);
    assert(client.connected && client.pong_tx.size == VTR_HEADER_SIZE && !client.pong_tx_sent);
    while (recv(sockets[1], bytes, sizeof(bytes), 0) > 0) {}
    assert(errno == EAGAIN || errno == EWOULDBLOCK);
    assert(vtr_client_receive_packet_timeout(&client, &packet, NULL, NULL, NULL,
                                               error, sizeof(error), 0) == -EAGAIN);
    assert(client.connected && !client.pong_tx.size);
    assert(recv(sockets[1], bytes, sizeof(bytes), 0) == VTR_HEADER_SIZE);
    assert(read_be16(bytes + 6) == VTR_MSG_PONG && read_be32(bytes + 8) == 0);
    vtr_buffer_free(&packet);
    vtr_client_destroy(&client);
    close(sockets[1]);
}

static void test_partial_pong(uint16_t next_message) {
    int sockets[2], control[2];
    int buffer_size = 4096;
    VTRClient client;
    VTRBuffer packet, ping;
    char error[128] = {0}, signal = 1;
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    assert(fcntl(sockets[0], F_SETFL, O_NONBLOCK) == 0);
    assert(fcntl(sockets[1], F_SETFL, O_NONBLOCK) == 0);
    assert(setsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF,
                      &buffer_size, sizeof(buffer_size)) == 0);
    assert(pipe(control) == 0);
    vtr_buffer_init(&ping);
    assert(vtr_put_u32(&ping, VTR_PROTO_MAGIC) == 0);
    assert(vtr_put_u16(&ping, VTR_PROTO_VERSION) == 0);
    assert(vtr_put_u16(&ping, VTR_MSG_PING) == 0);
    assert(vtr_put_u32(&ping, 65536) == 0);
    for (unsigned i = 0; i < 65536; ++i) assert(vtr_put_u8(&ping, (uint8_t)(i % 251)) == 0);
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        VTRClient peer;
        VTRMessage message;
        close(sockets[0]);
        close(control[1]);
        vtr_client_init(&peer);
        peer.fd = sockets[1];
        assert(write_all(peer.fd, ping.data, ping.size, now_ms() + 1000) == 0);
        assert(read(control[0], &signal, 1) == 1);
        assert(receive_message_until(&peer, &message, now_ms() + 1000) == 0);
        assert(message.type == VTR_MSG_PONG && message.payload_size == 65536);
        assert(memcmp(message.payload, ping.data + VTR_HEADER_SIZE, 65536) == 0);
        if (next_message) {
            assert(receive_message_until(&peer, &message, now_ms() + 1000) == 0);
            assert(message.type == next_message);
            if (next_message == VTR_MSG_FRAME)
                assert(message.payload_size >= 21 && message.payload[7] == 71);
        }
        assert(read(control[0], &signal, 1) == 1);
        assert(recv(peer.fd, &signal, 1, MSG_DONTWAIT) == -1);
        assert(errno == EAGAIN || errno == EWOULDBLOCK);
        vtr_client_destroy(&peer);
        vtr_buffer_free(&ping);
        close(control[0]);
        _exit(0);
    }
    close(sockets[1]);
    close(control[0]);
    vtr_client_init(&client);
    vtr_buffer_init(&packet);
    client.fd = sockets[0];
    client.connected = 1;
    client.timeout_ms = 500;
    int64_t deadline = now_ms() + 1000;
    while (!client.pong_tx.size && now_ms() < deadline) {
        assert(vtr_client_receive_packet_timeout(&client, &packet, NULL, NULL, NULL,
                                                   error, sizeof(error), 0) == -EAGAIN);
        struct timespec pause = {0, 1000000};
        nanosleep(&pause, NULL);
    }
    assert(client.connected && client.pong_tx_sent > 0 && client.pong_tx_sent < client.pong_tx.size);
    assert(write(control[1], &signal, 1) == 1);
    if (next_message == VTR_MSG_FRAME) {
        uint8_t y[4] = {1, 2, 3, 4}, uv[2] = {5, 6};
        VTRFrame frame = {0};
        frame.pts = 71;
        frame.duration = 1;
        frame.plane_count = 2;
        frame.planes[0] = (VTRFramePlane){y, 2, 2, sizeof(y)};
        frame.planes[1] = (VTRFramePlane){uv, 2, 1, sizeof(uv)};
        assert(vtr_client_send_frame(&client, &frame, error, sizeof(error)) == 0);
    } else if (next_message == VTR_MSG_FLUSH) {
        assert(vtr_client_start_flush(&client, error, sizeof(error)) == 0);
    }
    deadline = now_ms() + 1000;
    do {
        assert(vtr_client_receive_packet_timeout(&client, &packet, NULL, NULL, NULL,
                                                   error, sizeof(error), 0) == -EAGAIN);
    } while (client.pong_tx.size && now_ms() < deadline);
    assert(client.connected && !client.pong_tx.size);
    assert(write(control[1], &signal, 1) == 1);
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    close(control[1]);
    vtr_buffer_free(&ping);
    vtr_buffer_free(&packet);
    vtr_client_destroy(&client);
}

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
    test_receive_storage();
    test_done_payload();
    test_send_deadline();
    test_full_socket_pong();
    test_partial_pong(0);
    test_partial_pong(VTR_MSG_FRAME);
    test_partial_pong(VTR_MSG_FLUSH);
    puts("PASS client cleanup, receive storage, DONE validation, deadlines, and resumable PONGs");
    return 0;
}
