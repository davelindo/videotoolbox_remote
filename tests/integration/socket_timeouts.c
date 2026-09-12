/* Exercise the actual FFmpeg transport helper against a non-responsive peer. */
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#define VTR_SOCKOPT_ARG (char *)
#define vtremote_sock_errno WSAGetLastError
#define close closesocket
static double now_ms(void) { return (double)GetTickCount64(); }
#else
#include <arpa/inet.h>
#include <sys/time.h>
#include <unistd.h>
#include <time.h>
#define VTR_SOCKOPT_ARG
static int vtremote_sock_errno(void) { return errno; }
static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}
#endif
#include "libavcodec/vtremote_sock.h"

static void open_pair(int timeout_ms, int *sender_out, int *peer_out) {
    struct sockaddr_in address;
    socklen_t size = sizeof(address);
    int listener = (int)socket(AF_INET, SOCK_STREAM, 0);
    int sender, peer;
    int buffer_size = 4096;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(listener >= 0);
    assert(setsockopt(listener, SOL_SOCKET, SO_RCVBUF, VTR_SOCKOPT_ARG & buffer_size,
                      sizeof(buffer_size)) == 0);
    assert(bind(listener, (struct sockaddr *)&address, size) == 0);
    assert(listen(listener, 1) == 0);
    assert(getsockname(listener, (struct sockaddr *)&address, &size) == 0);
    sender = (int)socket(AF_INET, SOCK_STREAM, 0);
    assert(sender >= 0);
    assert(vtremote_set_socket_timeout(sender, timeout_ms) == 0);
    assert(setsockopt(sender, SOL_SOCKET, SO_SNDBUF, VTR_SOCKOPT_ARG & buffer_size,
                      sizeof(buffer_size)) == 0);
    assert(connect(sender, (struct sockaddr *)&address, size) == 0);
    peer = (int)accept(listener, NULL, NULL);
    assert(peer >= 0);
#ifdef _WIN32
    for (int i = 0; i < 2; ++i) {
        DWORD installed = 0;
        int length = sizeof(installed);
        assert(getsockopt(sender, SOL_SOCKET, i ? SO_SNDTIMEO : SO_RCVTIMEO, (char *)&installed,
                          &length) == 0);
        assert(length == sizeof(installed) && installed == (DWORD)timeout_ms);
    }
#endif
    close(listener);
    *sender_out = sender;
    *peer_out = peer;
}

static void exercise(int timeout_ms) {
    int sender, peer;
    char bytes[65536] = {0};
    double started, elapsed;
    open_pair(timeout_ms, &sender, &peer);
    /* A fragmented header/body must eventually time out after its prefix. */
    assert(send(peer, "V", 1, 0) == 1);
    assert(recv(sender, bytes, 1, 0) == 1);
    started = now_ms();
    assert(recv(sender, bytes, 12, 0) < 0);
    assert(vtremote_blocking_error(vtremote_sock_errno()) == AVERROR(ETIMEDOUT));
    elapsed = now_ms() - started;
    assert(elapsed >= timeout_ms * 0.8 && elapsed < timeout_ms + 1000);
    printf("PASS receive timeout=%d elapsed=%.0fms\n", timeout_ms, elapsed);
    close(peer);
    close(sender);
    /* Keep blocked-send validation independent of the timed-out receive. */
    open_pair(timeout_ms, &sender, &peer);
    started = now_ms();
    while (send(sender, bytes, sizeof(bytes), 0) > 0) {
        assert(now_ms() - started < 5000 + timeout_ms);
    }
    assert(vtremote_blocking_error(vtremote_sock_errno()) == AVERROR(ETIMEDOUT));
    elapsed = now_ms() - started;
    assert(elapsed >= timeout_ms * 0.8 && elapsed < 5000 + timeout_ms);
    printf("PASS blocked send timeout=%d elapsed=%.0fms\n", timeout_ms, elapsed);
    close(peer);
    close(sender);
}

int main(void) {
#ifdef _WIN32
    WSADATA data;
    assert(WSAStartup(MAKEWORD(2, 2), &data) == 0);
#endif
    assert(vtremote_set_socket_timeout(-1, 200) < 0);
    assert(vtremote_blocking_error(EAGAIN) == AVERROR(ETIMEDOUT));
#ifdef _WIN32
    assert(vtremote_blocking_error(WSAETIMEDOUT) == AVERROR(ETIMEDOUT));
#endif
    exercise(200);
    exercise(1200);
#ifdef _WIN32
    WSACleanup();
#endif
    return 0;
}
