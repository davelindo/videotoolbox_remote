/*
 * Shared socket helpers for VideoToolbox Remote clients.
 */

#ifndef AVCODEC_VTREMOTE_SOCK_H
#define AVCODEC_VTREMOTE_SOCK_H

#include "config.h"

#include <errno.h>
#include <limits.h>

#if defined(HAVE_WINSOCK2_H) && HAVE_WINSOCK2_H
#include <winsock2.h>
#else
#include <poll.h>
#include <sys/socket.h>
#endif

#include "libavutil/error.h"
#include "libavutil/time.h"

static inline int vtremote_send_flags(int flags)
{
#if !defined(HAVE_WINSOCK2_H) || !HAVE_WINSOCK2_H
#ifdef MSG_NOSIGNAL
    flags |= MSG_NOSIGNAL;
#endif
#endif
    return flags;
}

static inline void vtremote_disable_sigpipe(int fd)
{
#if (!defined(HAVE_WINSOCK2_H) || !HAVE_WINSOCK2_H) && defined(SO_NOSIGPIPE)
    int enabled = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
               VTR_SOCKOPT_ARG &enabled, sizeof(enabled));
#else
    (void)fd;
#endif
}

static inline int vtremote_remaining_timeout_ms(int64_t deadline_us)
{
    int64_t remaining_us;

    if (deadline_us < 0)
        return -1;

    remaining_us = deadline_us - av_gettime_relative();
    if (remaining_us <= 0)
        return 0;
    if (remaining_us > (int64_t)INT_MAX * 1000)
        return INT_MAX;
    return (int)((remaining_us + 999) / 1000);
}

static inline int vtremote_finish_interrupted_connect(int fd,
                                                      int64_t deadline_us)
{
#if defined(HAVE_WINSOCK2_H) && HAVE_WINSOCK2_H
    /*
     * The POSIX EINTR continuation rule does not apply to Winsock blocking
     * connect(); keep WSAEINTR fatal instead of pretending the handshake is
     * still in progress.
     */
    return AVERROR(WSAEINTR);
#else
    for (;;) {
        struct pollfd pfd;
        int ready;
        int timeout_ms = vtremote_remaining_timeout_ms(deadline_us);
        int so_error = 0;
        socklen_t so_error_len = sizeof(so_error);

        pfd.fd = fd;
        pfd.events = POLLOUT;
        pfd.revents = 0;
        ready = poll(&pfd, 1, timeout_ms);
        if (ready < 0) {
            if (errno == EINTR)
                continue;
            return AVERROR(errno);
        }
        if (ready == 0)
            return AVERROR(ETIMEDOUT);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR,
                       VTR_SOCKOPT_ARG &so_error, &so_error_len) < 0)
            return AVERROR(errno);
        if (so_error)
            return AVERROR(so_error);
        return 0;
    }
#endif
}

static inline int vtremote_connect_or_finish(int fd,
                                             const struct sockaddr *addr,
                                             socklen_t addrlen,
                                             int timeout_ms)
{
    int64_t deadline_us = timeout_ms < 0
                              ? -1
                              : av_gettime_relative() + (int64_t)timeout_ms * 1000;

    if (connect(fd, addr, addrlen) == 0)
        return 0;

    int err = vtremote_sock_errno();
#if defined(HAVE_WINSOCK2_H) && HAVE_WINSOCK2_H
    if (err == WSAEINTR)
        return vtremote_finish_interrupted_connect(fd, deadline_us);
#endif
    if (err == EINTR)
        return vtremote_finish_interrupted_connect(fd, deadline_us);
    return AVERROR(err);
}

#endif /* AVCODEC_VTREMOTE_SOCK_H */
