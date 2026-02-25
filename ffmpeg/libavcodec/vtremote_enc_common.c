/*
 * VTRemote encoder common scaffolding (M0)
 */

#include "config.h"
#include "config_components.h"

#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <string.h>
#include <sys/types.h>
#if defined(HAVE_WINSOCK2_H) && HAVE_WINSOCK2_H
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <fcntl.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#endif
#include "avcodec.h"
#include "codec_internal.h"
#include "encode.h"
#include "internal.h"
#include "libavutil/avassert.h"
#include "libavutil/avstring.h"
#include "libavutil/channel_layout.h"
#include "libavutil/ffversion.h"
#include "libavutil/intreadwrite.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/pixdesc.h"
#include "libavutil/time.h"
#include "vtremote_enc_common.h"
#include "vtremote_proto.h"
#include <lz4.h>
#include <zstd.h>

#if defined(HAVE_WINSOCK2_H) && HAVE_WINSOCK2_H
#define VTR_CLOSE_SOCKET closesocket
#define VTR_SOCKOPT_ARG (const char *)
static int vtremote_net_init(void) {
  WSADATA wsa;
  if (WSAStartup(MAKEWORD(2, 2), &wsa))
    return AVERROR(WSAGetLastError());
  return 0;
}
static void vtremote_net_close(void) { WSACleanup(); }
static int vtremote_sock_errno(void) { return WSAGetLastError(); }
#else
#define VTR_CLOSE_SOCKET close
#define VTR_SOCKOPT_ARG
static int vtremote_net_init(void) { return 0; }
static void vtremote_net_close(void) {}
static int vtremote_sock_errno(void) { return errno; }
#endif

#define MIN_HVCC_LENGTH 23

#ifndef MSG_DONTWAIT
#define MSG_DONTWAIT 0
#endif

static inline int vtremote_log_enabled(const VTRemoteEncContext *s, int level);
static void vtremote_log_error_payload(AVCodecContext *avctx,
                                       const uint8_t *payload, int len);

static int vtremote_hevc_extradata_to_annexb(const uint8_t *in, int in_size,
                                             uint8_t **out, int *out_size) {
  const uint8_t *p = in;
  const uint8_t *end = in + in_size;
  uint8_t *buf = NULL;
  int size = 0;

  if (in_size < MIN_HVCC_LENGTH)
    return AVERROR_INVALIDDATA;

  /* If already AnnexB, just copy. */
  if (AV_RB24(in) == 1 || AV_RB32(in) == 1) {
    buf = av_mallocz(in_size + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!buf)
      return AVERROR(ENOMEM);
    memcpy(buf, in, in_size);
    *out = buf;
    *out_size = in_size;
    return 0;
  }

  /* Skip configurationVersion..avgFrameRate (21 bytes). */
  p += 21;
  if (p + 2 > end)
    return AVERROR_INVALIDDATA;
  /* lengthSizeMinusOne in low 2 bits; unused here. */
  p++;
  int num_arrays = *p++;

  for (int i = 0; i < num_arrays; i++) {
    if (p + 3 > end) {
      av_freep(&buf);
      return AVERROR_INVALIDDATA;
    }
    /* array completeness + reserved + nal_unit_type */
    int nal_type = p[0] & 0x3f;
    (void)nal_type;
    p++;
    int num_nalus = AV_RB16(p);
    p += 2;

    for (int j = 0; j < num_nalus; j++) {
      if (p + 2 > end) {
        av_freep(&buf);
        return AVERROR_INVALIDDATA;
      }
      int nal_len = AV_RB16(p);
      p += 2;
      if (nal_len <= 0 || p + nal_len > end) {
        av_freep(&buf);
        return AVERROR_INVALIDDATA;
      }
      if (size > INT_MAX - (nal_len + 4 + AV_INPUT_BUFFER_PADDING_SIZE)) {
        av_freep(&buf);
        return AVERROR(ENOMEM);
      }
      if (av_reallocp(&buf, size + nal_len + 4 + AV_INPUT_BUFFER_PADDING_SIZE) <
          0) {
        av_freep(&buf);
        return AVERROR(ENOMEM);
      }
      AV_WB32(buf + size, 1);
      memcpy(buf + size + 4, p, nal_len);
      size += 4 + nal_len;
      memset(buf + size, 0, AV_INPUT_BUFFER_PADDING_SIZE);
      p += nal_len;
    }
  }

  *out = buf;
  *out_size = size;
  return 0;
}

static int set_socket_timeout(int fd, int timeout_ms) {
  struct timeval tv;
  tv.tv_sec = timeout_ms / 1000;
  tv.tv_usec = (timeout_ms % 1000) * 1000;
  if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, VTR_SOCKOPT_ARG & tv,
                 sizeof(tv)) < 0)
    return AVERROR(vtremote_sock_errno());
  if (setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, VTR_SOCKOPT_ARG & tv,
                 sizeof(tv)) < 0)
    return AVERROR(vtremote_sock_errno());
  return 0;
}

/* Configure socket for high-throughput video streaming */
static void configure_socket_buffers(int fd) {
  /* Disable Nagle's algorithm for lower latency */
  int nodelay = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, VTR_SOCKOPT_ARG & nodelay,
             sizeof(nodelay));

  /* 16MB buffers to sustain multi-gigabit links */
  int bufsize = 16 * 1024 * 1024;
  setsockopt(fd, SOL_SOCKET, SO_SNDBUF, VTR_SOCKOPT_ARG & bufsize,
             sizeof(bufsize));
  setsockopt(fd, SOL_SOCKET, SO_RCVBUF, VTR_SOCKOPT_ARG & bufsize,
             sizeof(bufsize));
}

static double vtremote_guess_fps(const AVCodecContext *avctx) {
  if (avctx->framerate.num > 0 && avctx->framerate.den > 0)
    return (double)avctx->framerate.num / (double)avctx->framerate.den;
  if (avctx->time_base.num > 0 && avctx->time_base.den > 0 &&
      !(avctx->time_base.num == 1 && avctx->time_base.den == 1)) {
    return (double)avctx->time_base.den / (double)avctx->time_base.num;
  }
  return 0.0;
}

static int vtremote_pix_fmt_depth(enum AVPixelFormat pix_fmt) {
  const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(pix_fmt);
  if (!desc || desc->nb_components <= 0)
    return 8;
  return desc->comp[0].depth;
}

static int vtremote_is_p010_pix_fmt(enum AVPixelFormat pix_fmt) {
  return pix_fmt == AV_PIX_FMT_P010LE || pix_fmt == AV_PIX_FMT_P010;
}

static int vtremote_is_upload_pix_fmt(enum AVPixelFormat pix_fmt) {
  return pix_fmt == AV_PIX_FMT_NV12 || vtremote_is_p010_pix_fmt(pix_fmt);
}

static inline uint16_t vtremote_pack_p010_sample(uint16_t sample) {
  return (uint16_t)((sample & 0x03FF) << 6);
}

static enum AVPixelFormat
vtremote_target_upload_pix_fmt(const AVFrame *frame, int codec_id) {
  if (codec_id == AV_CODEC_ID_H264)
    return AV_PIX_FMT_NV12;

  if (!frame)
    return AV_PIX_FMT_NV12;

  return vtremote_pix_fmt_depth(frame->format) > 8 ? AV_PIX_FMT_P010LE
                                                    : AV_PIX_FMT_NV12;
}

static int vtremote_wire_pix_fmt_for_context(const AVCodecContext *avctx,
                                             int codec_id) {
  if (codec_id == AV_CODEC_ID_H264)
    return 1;

  if (!avctx)
    return 1;

  if (vtremote_is_p010_pix_fmt(avctx->pix_fmt) ||
      avctx->pix_fmt == AV_PIX_FMT_P210 || vtremote_pix_fmt_depth(avctx->pix_fmt) > 8)
    return 2;

  return 1;
}

static void vtremote_copy_plane_rows(uint8_t *dst, int dst_linesize,
                                     const uint8_t *src, int src_linesize,
                                     int row_bytes, int rows) {
  if (src_linesize < 0)
    src += (rows - 1) * (int64_t)src_linesize;
  if (dst_linesize < 0)
    dst += (rows - 1) * (int64_t)dst_linesize;

  for (int y = 0; y < rows; y++) {
    memcpy(dst + y * dst_linesize, src + y * src_linesize, row_bytes);
  }
}

static int vtremote_prepare_upload_frame(AVCodecContext *avctx,
                                         const AVFrame *frame,
                                         const AVFrame **out_frame) {
  VTRemoteEncContext *s = avctx->priv_data;
  enum AVPixelFormat dst_fmt;
  const AVPixFmtDescriptor *src_desc;
  int ret;

  if (!frame || !out_frame)
    return AVERROR(EINVAL);

  dst_fmt = vtremote_target_upload_pix_fmt(frame, s->codec_id);
  if (frame->format == dst_fmt && vtremote_is_upload_pix_fmt(dst_fmt)) {
    *out_frame = frame;
    return 0;
  }

  src_desc = av_pix_fmt_desc_get(frame->format);
  if (src_desc && (src_desc->flags & AV_PIX_FMT_FLAG_HWACCEL)) {
    av_log(avctx, AV_LOG_ERROR,
           "Remote encode does not accept hardware frames (%s) directly; "
           "use hwdownload/format first.\n",
           av_get_pix_fmt_name(frame->format));
    return AVERROR(EINVAL);
  }

  if (!s->convert_frame) {
    s->convert_frame = av_frame_alloc();
    if (!s->convert_frame)
      return AVERROR(ENOMEM);
  }

  if (s->convert_frame->format != dst_fmt ||
      s->convert_frame->width != frame->width ||
      s->convert_frame->height != frame->height) {
    av_frame_unref(s->convert_frame);
    s->convert_frame->format = dst_fmt;
    s->convert_frame->width = frame->width;
    s->convert_frame->height = frame->height;
    ret = av_frame_get_buffer(s->convert_frame, 32);
    if (ret < 0)
      return ret;
  }

  ret = av_frame_make_writable(s->convert_frame);
  if (ret < 0)
    return ret;

  if (frame->format == AV_PIX_FMT_YUV420P || frame->format == AV_PIX_FMT_YUVJ420P) {
    const int width = frame->width;
    const int height = frame->height;
    const int cw = (width + 1) >> 1;
    const int ch = (height + 1) >> 1;

    if (dst_fmt == AV_PIX_FMT_NV12) {
      vtremote_copy_plane_rows(s->convert_frame->data[0], s->convert_frame->linesize[0],
                               frame->data[0], frame->linesize[0], width, height);
      for (int y = 0; y < ch; y++) {
        const uint8_t *u = frame->data[1] + y * frame->linesize[1];
        const uint8_t *v = frame->data[2] + y * frame->linesize[2];
        uint8_t *uv = s->convert_frame->data[1] + y * s->convert_frame->linesize[1];
        for (int x = 0; x < cw; x++) {
          uv[2 * x + 0] = u[x];
          uv[2 * x + 1] = v[x];
        }
      }
    } else if (dst_fmt == AV_PIX_FMT_P010LE) {
      for (int y = 0; y < height; y++) {
        const uint8_t *src_y = frame->data[0] + y * frame->linesize[0];
        uint8_t *dst_y = s->convert_frame->data[0] + y * s->convert_frame->linesize[0];
        for (int x = 0; x < width; x++) {
          AV_WL16(dst_y + 2 * x, ((uint16_t)src_y[x]) << 8);
        }
      }
      for (int y = 0; y < ch; y++) {
        const uint8_t *u = frame->data[1] + y * frame->linesize[1];
        const uint8_t *v = frame->data[2] + y * frame->linesize[2];
        uint8_t *uv = s->convert_frame->data[1] + y * s->convert_frame->linesize[1];
        for (int x = 0; x < cw; x++) {
          AV_WL16(uv + 4 * x + 0, ((uint16_t)u[x]) << 8);
          AV_WL16(uv + 4 * x + 2, ((uint16_t)v[x]) << 8);
        }
      }
    } else {
      av_log(avctx, AV_LOG_ERROR, "Unsupported conversion target %s\n",
             av_get_pix_fmt_name(dst_fmt));
      return AVERROR(EINVAL);
    }
  } else if ((frame->format == AV_PIX_FMT_YUV420P10LE ||
              frame->format == AV_PIX_FMT_YUV420P10BE) &&
             dst_fmt == AV_PIX_FMT_P010LE) {
    const int width = frame->width;
    const int height = frame->height;
    const int cw = (width + 1) >> 1;
    const int ch = (height + 1) >> 1;
    const int be = frame->format == AV_PIX_FMT_YUV420P10BE;

    // yuv420p10 stores sample values in the low 10 bits of each 16-bit word.
    // P010 expects them in the high 10 bits (low 6 bits zero).
    for (int y = 0; y < height; y++) {
      const uint8_t *src_y = frame->data[0] + y * frame->linesize[0];
      uint8_t *dst_y = s->convert_frame->data[0] + y * s->convert_frame->linesize[0];
      for (int x = 0; x < width; x++) {
        uint16_t y10 = be ? AV_RB16(src_y + 2 * x) : AV_RL16(src_y + 2 * x);
        AV_WL16(dst_y + 2 * x, vtremote_pack_p010_sample(y10));
      }
    }

    for (int y = 0; y < ch; y++) {
      const uint8_t *u = frame->data[1] + y * frame->linesize[1];
      const uint8_t *v = frame->data[2] + y * frame->linesize[2];
      uint8_t *uv = s->convert_frame->data[1] + y * s->convert_frame->linesize[1];
      for (int x = 0; x < cw; x++) {
        uint16_t u10 = be ? AV_RB16(u + 2 * x) : AV_RL16(u + 2 * x);
        uint16_t v10 = be ? AV_RB16(v + 2 * x) : AV_RL16(v + 2 * x);
        AV_WL16(uv + 4 * x + 0, vtremote_pack_p010_sample(u10));
        AV_WL16(uv + 4 * x + 2, vtremote_pack_p010_sample(v10));
      }
    }
  } else {
    av_log(avctx, AV_LOG_ERROR,
           "Unsupported frame format %s for remote upload (expected NV12/P010-compatible).\n",
           av_get_pix_fmt_name(frame->format));
    return AVERROR(EINVAL);
  }

  s->convert_frame->pts = frame->pts;
  s->convert_frame->duration = frame->duration;
  s->convert_frame->pict_type = frame->pict_type;
  s->convert_frame->flags &= ~AV_FRAME_FLAG_KEY;
  s->convert_frame->flags |= (frame->flags & AV_FRAME_FLAG_KEY);

  *out_frame = s->convert_frame;
  return 0;
}

static double vtremote_estimate_raw_mbps(const AVCodecContext *avctx) {
  if (!avctx || avctx->width <= 0 || avctx->height <= 0)
    return 0.0;
  double fps = vtremote_guess_fps(avctx);
  if (fps <= 0.0)
    fps = 30.0;

  double bytes_per_pixel =
      vtremote_wire_pix_fmt_for_context(avctx, avctx->codec_id) == 2 ? 3.0 : 1.5;

  double bytes_per_frame = bytes_per_pixel * (double)avctx->width *
                           (double)avctx->height;
  return bytes_per_frame * fps * 8.0 / 1000000.0;
}

static void vtremote_apply_auto_wire_compression(AVCodecContext *avctx,
                                                  VTRemoteEncContext *s) {
  if (!s || s->wire_compression != 3)
    return;

  double raw_mbps = vtremote_estimate_raw_mbps(avctx);
  int chosen = 1; /* lz4 */
  if (raw_mbps > 0.0 && raw_mbps < 200.0)
    chosen = 2; /* zstd */

  s->wire_compression = chosen;
  if (vtremote_log_enabled(s, AV_LOG_VERBOSE)) {
    av_log(avctx, AV_LOG_VERBOSE,
           "vtremote auto wire_compression=%.1fMb/s -> %s\n",
           raw_mbps, chosen == 2 ? "zstd" : "lz4");
  }
}

static void vtremote_init_inflight(AVCodecContext *avctx,
                                   VTRemoteEncContext *s) {
  if (!s)
    return;
  s->inflight_auto = s->inflight == 0;
  s->inflight_blocked = 0;
  s->inflight_idle_intervals = 0;
  s->inflight_last_adjust_us = av_gettime_relative();

  if (!s->inflight_auto) {
    s->inflight_min = s->inflight;
    s->inflight_max_limit = s->inflight;
    s->inflight_step = 0;
    return;
  }

  if (s->codec_id == AV_CODEC_ID_H264) {
    s->inflight_min = 16;
    s->inflight_max_limit = 64;
    s->inflight_step = 8;
    s->inflight = 32;
  } else {
    s->inflight_min = 8;
    s->inflight_max_limit = 32;
    s->inflight_step = 4;
    s->inflight = 16;
  }
}

static void vtremote_auto_adjust_inflight(AVCodecContext *avctx,
                                          VTRemoteEncContext *s) {
  if (!s || !s->inflight_auto || s->inflight_step <= 0)
    return;

  int64_t now = av_gettime_relative();
  if (now - s->inflight_last_adjust_us < 1000000)
    return;

  if (s->inflight_blocked > 0 && s->inflight < s->inflight_max_limit) {
    int next = s->inflight + s->inflight_step;
    s->inflight = FFMIN(next, s->inflight_max_limit);
    s->inflight_idle_intervals = 0;
    if (vtremote_log_enabled(s, AV_LOG_VERBOSE))
      av_log(avctx, AV_LOG_VERBOSE,
             "vtremote inflight auto increase to %d\n", s->inflight);
  } else if (s->inflight_blocked == 0 && s->inflight > s->inflight_min) {
    s->inflight_idle_intervals++;
    if (s->inflight_idle_intervals >= 3) {
      int next = s->inflight - s->inflight_step;
      s->inflight = FFMAX(next, s->inflight_min);
      s->inflight_idle_intervals = 0;
      if (vtremote_log_enabled(s, AV_LOG_VERBOSE))
        av_log(avctx, AV_LOG_VERBOSE,
               "vtremote inflight auto decrease to %d\n", s->inflight);
    }
  } else {
    s->inflight_idle_intervals = 0;
  }

  s->inflight_blocked = 0;
  s->inflight_last_adjust_us = now;
}

static int configure_zstd_ctx(AVCodecContext *avctx, VTRemoteEncContext *s,
                              int src_size) {
  int job_size = 0;
  if (!s->zstd_cctx) {
    s->zstd_cctx = ZSTD_createCCtx();
    if (!s->zstd_cctx)
      return AVERROR(ENOMEM);
    {
      size_t zrc = ZSTD_CCtx_setParameter(s->zstd_cctx, ZSTD_c_checksumFlag, 0);
      if (ZSTD_isError(zrc)) {
        av_log(avctx, AV_LOG_WARNING, "Zstd checksumFlag not supported: %s\n",
               ZSTD_getErrorName(zrc));
      }
    }
    {
      size_t zrc =
          ZSTD_CCtx_setParameter(s->zstd_cctx, ZSTD_c_contentSizeFlag, 0);
      if (ZSTD_isError(zrc)) {
        av_log(avctx, AV_LOG_WARNING,
               "Zstd contentSizeFlag not supported: %s\n",
               ZSTD_getErrorName(zrc));
      }
    }
  }
  if (s->zstd_workers > 0) {
    job_size = src_size / s->zstd_workers;
    if (job_size < (1 << 20))
      job_size = 1 << 20;
  }
  if (s->zstd_last_level != s->zstd_level) {
    size_t zrc = ZSTD_CCtx_setParameter(s->zstd_cctx, ZSTD_c_compressionLevel,
                                        s->zstd_level);
    if (ZSTD_isError(zrc)) {
      av_log(avctx, AV_LOG_ERROR, "Zstd level set failed: %s\n",
             ZSTD_getErrorName(zrc));
      return AVERROR_EXTERNAL;
    }
    s->zstd_last_level = s->zstd_level;
  }
  if (s->zstd_last_workers != s->zstd_workers) {
    size_t zrc =
        ZSTD_CCtx_setParameter(s->zstd_cctx, ZSTD_c_nbWorkers, s->zstd_workers);
    if (ZSTD_isError(zrc)) {
      av_log(avctx, AV_LOG_WARNING, "Zstd workers not supported: %s\n",
             ZSTD_getErrorName(zrc));
    }
    s->zstd_last_workers = s->zstd_workers;
    s->zstd_last_job_size = -1;
  }
  if (s->zstd_workers > 0 && job_size > 0 &&
      job_size != s->zstd_last_job_size) {
    size_t zrc = ZSTD_CCtx_setParameter(s->zstd_cctx, ZSTD_c_jobSize, job_size);
    if (ZSTD_isError(zrc)) {
      av_log(avctx, AV_LOG_WARNING, "Zstd jobSize not supported: %s\n",
             ZSTD_getErrorName(zrc));
    } else {
      s->zstd_last_job_size = job_size;
    }
  } else if (s->zstd_workers == 0) {
    s->zstd_last_job_size = 0;
  }
  return 0;
}

static int write_full(int fd, const uint8_t *buf, int size) {
  int sent = 0;
  while (sent < size) {
    int r = (int)send(fd, buf + sent, size - sent, 0);
    if (r < 0) {
      int err = vtremote_sock_errno();
#if defined(HAVE_WINSOCK2_H) && HAVE_WINSOCK2_H
      if (err == WSAEINTR)
        continue;
#endif
      if (err == EINTR)
        continue;
      return AVERROR(err);
    }
    if (r == 0)
      return AVERROR_EOF;
    sent += r;
  }
  return 0;
}

static int read_full(int fd, uint8_t *buf, int size) {
  int got = 0;
  while (got < size) {
    int r = (int)recv(fd, buf + got, size - got, 0);
    if (r < 0) {
      int err = vtremote_sock_errno();
#if defined(HAVE_WINSOCK2_H) && HAVE_WINSOCK2_H
      if (err == WSAEINTR)
        continue;
#endif
      if (err == EINTR)
        continue;
      if (err == EAGAIN || err == EWOULDBLOCK
#if defined(HAVE_WINSOCK2_H) && HAVE_WINSOCK2_H
          || err == WSAEWOULDBLOCK
#endif
      )
        return got == 0 ? AVERROR(EAGAIN) : AVERROR(EIO);
      return AVERROR(err);
    }
    if (r == 0)
      return AVERROR_EOF;
    got += r;
  }
  return 0;
}

/* Non-blocking check if data is available to read */
static int check_readable(int fd, int timeout_ms) {
#if defined(HAVE_WINSOCK2_H) && HAVE_WINSOCK2_H
  fd_set readfds;
  struct timeval tv;
  FD_ZERO(&readfds);
  FD_SET(fd, &readfds);
  tv.tv_sec = timeout_ms / 1000;
  tv.tv_usec = (timeout_ms % 1000) * 1000;
  return select(fd + 1, &readfds, NULL, NULL, &tv);
#else
  struct pollfd pfd;
  pfd.fd = fd;
  pfd.events = POLLIN;
  pfd.revents = 0;
  return poll(&pfd, 1, timeout_ms);
#endif
}

static int connect_hostport(const char *hostport, int timeout_ms) {
  if (!hostport)
    return AVERROR(EINVAL);

  char host[256];
  char port[16];
  const char *colon = strrchr(hostport, ':');
  if (!colon || colon == hostport || strlen(colon + 1) >= sizeof(port))
    return AVERROR(EINVAL);
  av_strlcpy(port, colon + 1, sizeof(port));
  size_t hostlen = colon - hostport;
  if (hostlen >= sizeof(host))
    return AVERROR(EINVAL);
  memcpy(host, hostport, hostlen);
  host[hostlen] = '\0';

  struct addrinfo hints = {0}, *res = NULL, *rp;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_family = AF_INET;
  int err = getaddrinfo(host, port, &hints, &res);
  if (err)
    return AVERROR(EIO);

  int fd = -1;
  for (rp = res; rp; rp = rp->ai_next) {
    fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
    if (fd < 0)
      continue;
    /* Configure socket buffers BEFORE connect() for correct TCP Window Scale
     * negotiation */
    configure_socket_buffers(fd);
    set_socket_timeout(fd, timeout_ms);
    if (connect(fd, rp->ai_addr, rp->ai_addrlen) == 0)
      break;
    VTR_CLOSE_SOCKET(fd);
    fd = -1;
  }
  freeaddrinfo(res);
  if (fd < 0)
    return AVERROR(vtremote_sock_errno() ? vtremote_sock_errno() : EIO);

  return fd;
}

static inline int vtremote_log_enabled(const VTRemoteEncContext *s, int level) {
  return s && s->log_level >= level;
}

/* Forward declaration for enqueue_packet */
static int enqueue_packet(AVCodecContext *avctx, const uint8_t *payload,
                          int payload_size);

static int vtremote_add_opt(VTRemoteKV **opts, int *count, int *cap,
                            const char *key, char *value) {
  if (!opts || !count || !cap || !key || !value)
    return AVERROR(EINVAL);
  if (*count >= *cap) {
    int new_cap = (*cap == 0) ? 16 : (*cap * 2);
    VTRemoteKV *tmp = av_realloc_array(*opts, new_cap, sizeof(**opts));
    if (!tmp)
      return AVERROR(ENOMEM);
    *opts = tmp;
    *cap = new_cap;
  }
  (*opts)[*count].key = key;
  (*opts)[*count].value = value;
  (*count)++;
  return 0;
}

static const char *codec_name_for_id(int codec_id) {
  switch (codec_id) {
  case AV_CODEC_ID_H264:
    return "h264";
  case AV_CODEC_ID_HEVC:
    return "hevc";
  default:
    return "unknown";
  }
}

static int vtremote_send_msg_blocking(VTRemoteEncContext *s, int msg_type,
                                      VTRemoteWBuf *payload) {
  if (!s)
    return AVERROR(EINVAL);
  const uint8_t *payload_data = payload ? payload->data : NULL;
  const uint32_t payload_size = payload ? (uint32_t)payload->size : 0;
  uint8_t header_buf[VTREMOTE_HEADER_SIZE];
  VTRemoteMsgHeader hdr = {
      .magic = VTREMOTE_PROTO_MAGIC,
      .version = VTREMOTE_PROTO_VERSION,
      .type = msg_type,
      .length = payload_size,
  };
  int ret = vtremote_write_header(header_buf, sizeof(header_buf), &hdr);
  if (ret < 0)
    return ret;
  ret = write_full(s->fd, header_buf, VTREMOTE_HEADER_SIZE);
  if (ret < 0)
    return ret;
  if (payload_size) {
    ret = write_full(s->fd, payload_data, payload_size);
    if (ret < 0)
      return ret;
  }
  s->bytes_sent += VTREMOTE_HEADER_SIZE + payload_size;
  return 0;
}

static void vtremote_sendbuf_reset(VTRemoteSendBuf *slot) {
  if (!slot)
    return;
  av_frame_free(&slot->frame_ref);
  av_freep(&slot->owned_plane[0]);
  av_freep(&slot->owned_plane[1]);
  slot->owned_plane_size[0] = slot->owned_plane_size[1] = 0;
  av_freep(&slot->owned_side_data);
  slot->owned_side_data_size = 0;

  slot->seg_count = 0;
  slot->seg_index = 0;
  slot->seg_offset = 0;
  slot->is_frame = 0;
  slot->enqueue_us = 0;
}

static int vtremote_sendq_enqueue_empty(VTRemoteEncContext *s, int msg_type,
                                       int is_frame) {
  if (!s || !s->send_queue)
    return AVERROR(EINVAL);
  if (s->send_q_count >= s->send_q_size)
    return AVERROR(EAGAIN);
  if (is_frame && (s->queued_frames + s->inflight_frames) >= s->inflight)
    return AVERROR(EAGAIN);

  VTRemoteSendBuf *slot = &s->send_queue[s->send_q_tail];
  vtremote_sendbuf_reset(slot);

  VTRemoteMsgHeader hdr = {
      .magic = VTREMOTE_PROTO_MAGIC,
      .version = VTREMOTE_PROTO_VERSION,
      .type = msg_type,
      .length = 0,
  };
  int ret = vtremote_write_header(slot->header, sizeof(slot->header), &hdr);
  if (ret < 0)
    return ret;

  slot->segs[0] = slot->header;
  slot->seg_lens[0] = VTREMOTE_HEADER_SIZE;
  slot->seg_count = 1;
  slot->seg_index = 0;
  slot->seg_offset = 0;
  slot->is_frame = is_frame;
  slot->enqueue_us = av_gettime_relative();

  s->send_q_tail = (s->send_q_tail + 1) % s->send_q_size;
  s->send_q_count++;
  if (is_frame)
    s->queued_frames++;
  return 0;
}

static int vtremote_sendq_enqueue_frame(AVCodecContext *avctx, VTRemoteEncContext *s,
                                       const AVFrame *frame,
                                       const uint8_t *const *planes,
                                       const uint32_t *strides,
                                       const uint32_t *heights,
                                       const uint32_t *sizes,
                                       const VTRemoteSideData *sd,
                                       int sd_count) {
  if (!s || !s->send_queue || !frame || !planes || !strides || !heights || !sizes)
    return AVERROR(EINVAL);
  if (s->send_q_count >= s->send_q_size)
    return AVERROR(EAGAIN);
  if ((s->queued_frames + s->inflight_frames) >= s->inflight)
    return AVERROR(EAGAIN);

  const uint8_t *send_planes[2] = {planes[0], planes[1]};
  uint32_t send_sizes[2] = {sizes[0], sizes[1]};

  VTRemoteSendBuf *slot = &s->send_queue[s->send_q_tail];
  vtremote_sendbuf_reset(slot);

  int ret = 0;

#define FAIL(code)           \
  do {                       \
    ret = (code);            \
    goto fail;               \
  } while (0)

  if (s->wire_compression == 1 || s->wire_compression == 2) {
    if (s->wire_compression == 2) {
      int zret = configure_zstd_ctx(avctx, s, (int)sizes[0]);
      if (zret < 0)
        FAIL(zret);
    }

    for (int i = 0; i < 2; i++) {
      const int src_size = (int)sizes[i];
      size_t bound;
      if (s->wire_compression == 1) {
        bound = (size_t)LZ4_compressBound(src_size);
      } else {
        bound = ZSTD_compressBound(src_size);
      }
      if (bound <= 0)
        FAIL(AVERROR_EXTERNAL);

      uint8_t *out = av_malloc(bound);
      if (!out)
        FAIL(AVERROR(ENOMEM));

      size_t out_size = 0;
      if (s->wire_compression == 1) {
        int wrote = LZ4_compress_default((const char *)planes[i], (char *)out,
                                         src_size, (int)bound);
        if (wrote <= 0) {
          av_freep(&out);
          FAIL(AVERROR_EXTERNAL);
        }
        out_size = (size_t)wrote;
      } else {
        size_t wrote = ZSTD_compress2(s->zstd_cctx, out, bound, planes[i], src_size);
        if (ZSTD_isError(wrote)) {
          av_log(avctx, AV_LOG_ERROR, "Zstd compress failed: %s\n",
                 ZSTD_getErrorName(wrote));
          av_freep(&out);
          FAIL(AVERROR_EXTERNAL);
        }
        out_size = wrote;
      }

      // Shrink to fit to keep queue memory bounded.
      uint8_t *shrunk = av_realloc(out, out_size);
      if (shrunk)
        out = shrunk;

      slot->owned_plane[i] = out;
      slot->owned_plane_size[i] = (int)out_size;
      send_planes[i] = out;
      send_sizes[i] = (uint32_t)out_size;
    }
  } else {
    // Uncompressed: keep the frame alive until the queued send completes.
    slot->frame_ref = av_frame_alloc();
    if (!slot->frame_ref)
      FAIL(AVERROR(ENOMEM));
    ret = av_frame_ref(slot->frame_ref, frame);
    if (ret < 0)
      FAIL(ret);
    send_planes[0] = slot->frame_ref->data[0];
    send_planes[1] = slot->frame_ref->data[1];
  }

  if (!send_planes[0] || !send_planes[1] || send_sizes[0] == 0 || send_sizes[1] == 0) {
    FAIL(AVERROR(EINVAL));
  }

  // Pack optional side data into a single owned blob to keep segment count small.
  if (sd_count > 0 && sd) {
    int64_t side_len = 1; // count
    for (int i = 0; i < sd_count; i++) {
      side_len += 8 + (int64_t)sd[i].size;
    }
    if (side_len > INT_MAX)
      FAIL(AVERROR(ENOMEM));
    slot->owned_side_data = av_malloc((size_t)side_len);
    if (!slot->owned_side_data)
      FAIL(AVERROR(ENOMEM));
    slot->owned_side_data_size = (int)side_len;

    uint8_t *p = slot->owned_side_data;
    *p++ = (uint8_t)sd_count;
    for (int i = 0; i < sd_count; i++) {
      AV_WB32(p, sd[i].type);
      p += 4;
      AV_WB32(p, sd[i].size);
      p += 4;
      if (sd[i].size && sd[i].data) {
        memcpy(p, sd[i].data, sd[i].size);
        p += sd[i].size;
      }
    }
  }

  // Build frame payload meta (v1 wire format).
  uint8_t *m = slot->frame_meta;
  AV_WB64(m, (uint64_t)frame->pts);
  m += 8;
  AV_WB64(m, (uint64_t)frame->duration);
  m += 8;
  AV_WB32(m, frame->pict_type == AV_PICTURE_TYPE_I ? 1U : 0U);
  m += 4;
  *m++ = 2; // plane count

  AV_WB32(slot->plane_meta[0] + 0, strides[0]);
  AV_WB32(slot->plane_meta[0] + 4, heights[0]);
  AV_WB32(slot->plane_meta[0] + 8, send_sizes[0]);

  AV_WB32(slot->plane_meta[1] + 0, strides[1]);
  AV_WB32(slot->plane_meta[1] + 4, heights[1]);
  AV_WB32(slot->plane_meta[1] + 8, send_sizes[1]);

  uint32_t payload_len = 21 + 24 + send_sizes[0] + send_sizes[1];
  if (slot->owned_side_data)
    payload_len += (uint32_t)slot->owned_side_data_size;

  VTRemoteMsgHeader hdr = {
      .magic = VTREMOTE_PROTO_MAGIC,
      .version = VTREMOTE_PROTO_VERSION,
      .type = VTREMOTE_MSG_FRAME,
      .length = payload_len,
  };
  ret = vtremote_write_header(slot->header, sizeof(slot->header), &hdr);
  if (ret < 0)
    FAIL(ret);

  int seg = 0;
  slot->segs[seg] = slot->header;
  slot->seg_lens[seg++] = VTREMOTE_HEADER_SIZE;

  slot->segs[seg] = slot->frame_meta;
  slot->seg_lens[seg++] = 21;

  slot->segs[seg] = slot->plane_meta[0];
  slot->seg_lens[seg++] = 12;
  slot->segs[seg] = send_planes[0];
  slot->seg_lens[seg++] = (int)send_sizes[0];

  slot->segs[seg] = slot->plane_meta[1];
  slot->seg_lens[seg++] = 12;
  slot->segs[seg] = send_planes[1];
  slot->seg_lens[seg++] = (int)send_sizes[1];

  if (slot->owned_side_data) {
    slot->segs[seg] = slot->owned_side_data;
    slot->seg_lens[seg++] = slot->owned_side_data_size;
  }

  if (seg > VTREMOTE_SEND_MAX_SEGS) {
    FAIL(AVERROR_BUG);
  }

  slot->seg_count = seg;
  slot->seg_index = 0;
  slot->seg_offset = 0;
  slot->is_frame = 1;
  slot->enqueue_us = av_gettime_relative();

  s->send_q_tail = (s->send_q_tail + 1) % s->send_q_size;
  s->send_q_count++;
  s->queued_frames++;

  return 0;

fail:
  vtremote_sendbuf_reset(slot);
  return ret;

#undef FAIL
}

static int vtremote_sendq_pump(AVCodecContext *avctx, int blocking) {
  VTRemoteEncContext *s = avctx->priv_data;
  int flags = blocking ? 0 : MSG_DONTWAIT;
  while (s->send_q_count > 0) {
    VTRemoteSendBuf *slot = &s->send_queue[s->send_q_head];
    while (slot->seg_index < slot->seg_count) {
      const uint8_t *base = slot->segs[slot->seg_index];
      const int len = slot->seg_lens[slot->seg_index];
      const uint8_t *ptr = base + slot->seg_offset;
      const int to_send = len - slot->seg_offset;
      int r = (int)send(s->fd, ptr, to_send, flags);
      if (r < 0) {
        int err = vtremote_sock_errno();
#if defined(HAVE_WINSOCK2_H) && HAVE_WINSOCK2_H
        if (err == WSAEINTR)
          continue;
        if (!blocking && err == WSAEWOULDBLOCK)
          return AVERROR(EAGAIN);
#endif
        if (err == EINTR)
          continue;
        if (!blocking && (err == EAGAIN || err == EWOULDBLOCK))
          return AVERROR(EAGAIN);
        return AVERROR(err);
      }
      if (r == 0)
        return AVERROR(EPIPE);
      slot->seg_offset += r;
      s->bytes_sent += r;
      if (slot->seg_offset >= len) {
        slot->seg_index++;
        slot->seg_offset = 0;
      }
    }

    if (slot->is_frame) {
      s->inflight_frames++;
      if (s->inflight_frames > s->max_inflight)
        s->max_inflight = s->inflight_frames;
      s->frames_sent++;
      if (slot->enqueue_us > 0) {
        int64_t send_elapsed_us = av_gettime_relative() - slot->enqueue_us;
        if (send_elapsed_us > 0) {
          s->send_time_us += send_elapsed_us;
          s->send_frames++;
        }
      }
      if (s->queued_frames > 0)
        s->queued_frames--;
    }

    vtremote_sendbuf_reset(slot);
    s->send_q_head = (s->send_q_head + 1) % s->send_q_size;
    s->send_q_count--;
  }
  return 0;
}

static int vtremote_read_msg(VTRemoteEncContext *s, VTRemoteMsgHeader *hdr,
                             uint8_t **payload) {
  uint8_t header_buf[VTREMOTE_HEADER_SIZE];
  if (!s)
    return AVERROR(EINVAL);
  int ret = read_full(s->fd, header_buf, VTREMOTE_HEADER_SIZE);
  if (ret < 0)
    return ret;
  ret = vtremote_read_header(header_buf, VTREMOTE_HEADER_SIZE, hdr);
  if (ret < 0)
    return ret;
  if (hdr->length == 0) {
    *payload = NULL;
    s->bytes_recv += VTREMOTE_HEADER_SIZE;
    return 0;
  }
  uint8_t *buf = av_malloc(hdr->length);
  if (!buf)
    return AVERROR(ENOMEM);
  ret = read_full(s->fd, buf, hdr->length);
  if (ret < 0) {
    av_free(buf);
    return ret;
  }
  *payload = buf;
  s->bytes_recv += VTREMOTE_HEADER_SIZE + hdr->length;
  return 0;
}

/* Try to read a message without blocking. Returns AVERROR(EAGAIN) if no data
 * available. */
static int vtremote_read_msg_nonblock(VTRemoteEncContext *s,
                                      VTRemoteMsgHeader *hdr,
                                      uint8_t **payload) {
  if (!s)
    return AVERROR(EINVAL);
  /* Check if data is available with 0ms timeout */
  int ready = check_readable(s->fd, 0);
  if (ready <= 0)
    return AVERROR(EAGAIN);
  return vtremote_read_msg(s, hdr, payload);
}

/* Drain all available packets into the queue without blocking */
static int vtremote_drain_available_packets(AVCodecContext *avctx) {
  VTRemoteEncContext *s = avctx->priv_data;
  int packets_read = 0;

  while (s->pkt_q_count < s->pkt_q_size) {
    VTRemoteMsgHeader hdr;
    uint8_t *payload = NULL;
    int ret = vtremote_read_msg_nonblock(s, &hdr, &payload);
    if (ret == AVERROR(EAGAIN))
      break; /* No more data available */
    if (ret < 0)
      return ret;

    switch (hdr.type) {
    case VTREMOTE_MSG_PACKET:
      ret = enqueue_packet(avctx, payload, hdr.length);
      av_free(payload);
      if (ret < 0)
        return ret;
      if (s->inflight_frames > 0)
        s->inflight_frames--;
      packets_read++;
      break;
    case VTREMOTE_MSG_DONE:
      av_free(payload);
      s->done = 1;
      return packets_read;
    case VTREMOTE_MSG_PING: {
      vtremote_sendq_enqueue_empty(s, VTREMOTE_MSG_PONG, 0);
      vtremote_sendq_pump(avctx, 0);
      av_free(payload);
      break;
    }
    case VTREMOTE_MSG_ERROR: {
      vtremote_log_error_payload(avctx, payload, hdr.length);
      av_free(payload);
      return AVERROR(EIO);
    }
    default:
      av_free(payload);
      break;
    }
  }
  return packets_read;
}

static void vtremote_log_error_payload(AVCodecContext *avctx,
                                       const uint8_t *payload, int len) {
  uint32_t code = 0;
  VTRemoteRBuf er;
  vtremote_rbuf_init(&er, payload, len);
  vtremote_rbuf_read_u32(&er, &code);
  const uint8_t *msg = NULL;
  int mlen = 0;
  if (vtremote_rbuf_read_str(&er, &msg, &mlen) == 0)
    av_log(avctx, AV_LOG_ERROR, "vtremote server error %u: %.*s\n", code, mlen,
           msg);
  else
    av_log(avctx, AV_LOG_ERROR, "vtremote server error %u\n", code);
}

static int vtremote_handle_hello_ack(AVCodecContext *avctx,
                                     const uint8_t *payload, int len) {
  VTRemoteRBuf r;
  vtremote_rbuf_init(&r, payload, len);
  uint8_t status;
  int ret = vtremote_rbuf_read_u8(&r, &status);
  if (ret < 0)
    return ret;

  /* Best-effort parse server info so we can produce useful diagnostics on failure. */
  const uint8_t *server_name = NULL, *server_ver = NULL;
  int server_name_len = 0, server_ver_len = 0;
  vtremote_rbuf_read_str(&r, &server_name, &server_name_len); /* server_name */
  vtremote_rbuf_read_str(&r, &server_ver, &server_ver_len);   /* server_version */
  uint8_t caps = 0;
  vtremote_rbuf_read_u8(&r, &caps);
  for (int i = 0; i < caps; i++) {
    const uint8_t *s = NULL;
    int slen = 0;
    vtremote_rbuf_read_str(&r, &s, &slen);
  }
  uint16_t max_sessions = 0, active = 0;
  vtremote_rbuf_read_u16(&r, &max_sessions);
  vtremote_rbuf_read_u16(&r, &active);

  if (status != 0) {
    if (status == 1) {
      av_log(avctx, AV_LOG_ERROR,
             "vtremote server busy (sessions active=%u max=%u) [%.*s %.*s]\n",
             active, max_sessions,
             server_name_len,
             server_name ? (const char *)server_name : "",
             server_ver_len, server_ver ? (const char *)server_ver : "");
      return AVERROR(EAGAIN);
    }
    if (status == 2) {
      av_log(avctx, AV_LOG_ERROR,
             "vtremote server unauthorized (token mismatch) [%.*s %.*s]\n",
             server_name_len,
             server_name ? (const char *)server_name : "",
             server_ver_len, server_ver ? (const char *)server_ver : "");
      return AVERROR(EACCES);
    }
    av_log(avctx, AV_LOG_ERROR,
           "vtremote server refused handshake (status=%u) [%.*s %.*s]\n", status,
           server_name_len, server_name ? (const char *)server_name : "",
           server_ver_len, server_ver ? (const char *)server_ver : "");
    return AVERROR(EACCES);
  }
  return 0;
}

static int vtremote_handle_configure_ack(AVCodecContext *avctx,
                                         const uint8_t *payload, int len) {
  VTRemoteRBuf r;
  vtremote_rbuf_init(&r, payload, len);
  uint8_t status;
  int ret = vtremote_rbuf_read_u8(&r, &status);
  if (ret < 0)
    return ret;
  if (status != 0)
    return AVERROR_INVALIDDATA;

  uint16_t extralen = 0;
  vtremote_rbuf_read_u16(&r, &extralen);
  if (extralen) {
    if (extralen > len - r.pos)
      return AVERROR_INVALIDDATA;
    const uint8_t *avcc = payload + r.pos;
    uint8_t *annexb = NULL;
    int annexb_size = 0;

    if (avctx->codec_id == AV_CODEC_ID_HEVC) {
      /* Convert hvcC to AnnexB extradata so muxers can reformat packets. */
      int conv = vtremote_hevc_extradata_to_annexb(avcc, extralen, &annexb,
                                                   &annexb_size);
      if (conv < 0)
        return conv;
      av_freep(&avctx->extradata);
      avctx->extradata = annexb;
      avctx->extradata_size = annexb_size;
      /* Convert avcC to AnnexB extradata so muxers can reformat packets. */
    } else if (avcc[0] == 1 && extralen > 6) {
      int pos = 5;
      int sps_count = avcc[pos++] & 0x1f;
      for (int i = 0; i < sps_count && pos + 2 <= extralen; i++) {
        int sps_len = AV_RB16(avcc + pos);
        pos += 2;
        if (pos + sps_len > extralen)
          break;
        annexb_size += 4 + sps_len;
        pos += sps_len;
      }
      int pps_count = avcc[pos++] & 0xff;
      for (int i = 0; i < pps_count && pos + 2 <= extralen; i++) {
        int pps_len = AV_RB16(avcc + pos);
        pos += 2;
        if (pos + pps_len > extralen)
          break;
        annexb_size += 4 + pps_len;
        pos += pps_len;
      }
      annexb = av_mallocz(annexb_size + AV_INPUT_BUFFER_PADDING_SIZE);
      if (!annexb)
        return AVERROR(ENOMEM);
      int w = 0;
      pos = 5;
      sps_count = avcc[pos++] & 0x1f;
      for (int i = 0; i < sps_count && pos + 2 <= extralen; i++) {
        int sps_len = AV_RB16(avcc + pos);
        pos += 2;
        if (pos + sps_len > extralen)
          break;
        AV_WB32(annexb + w, 0x00000001);
        w += 4;
        memcpy(annexb + w, avcc + pos, sps_len);
        w += sps_len;
        pos += sps_len;
      }
      pps_count = avcc[pos++] & 0xff;
      for (int i = 0; i < pps_count && pos + 2 <= extralen; i++) {
        int pps_len = AV_RB16(avcc + pos);
        pos += 2;
        if (pos + pps_len > extralen)
          break;
        AV_WB32(annexb + w, 0x00000001);
        w += 4;
        memcpy(annexb + w, avcc + pos, pps_len);
        w += pps_len;
        pos += pps_len;
      }
      av_freep(&avctx->extradata);
      avctx->extradata = annexb;
      avctx->extradata_size = annexb_size;
    } else {
      av_freep(&avctx->extradata);
      avctx->extradata = av_mallocz(extralen + AV_INPUT_BUFFER_PADDING_SIZE);
      if (!avctx->extradata)
        return AVERROR(ENOMEM);
      memcpy(avctx->extradata, avcc, extralen);
      avctx->extradata_size = extralen;
    }
    r.pos += extralen;
  } else {
    av_freep(&avctx->extradata);
    avctx->extradata_size = 0;
  }

  uint8_t reported_pix = 0;
  vtremote_rbuf_read_u8(&r, &reported_pix);
  uint8_t warn_count = 0;
  vtremote_rbuf_read_u8(&r, &warn_count);
  const uint8_t *s_ptr;
  int s_len;
  for (int i = 0; i < warn_count; i++) {
    if (vtremote_rbuf_read_str(&r, &s_ptr, &s_len) < 0)
      break;
    av_log(avctx, AV_LOG_WARNING, "vtremote warning: %.*s\n", s_len, s_ptr);
  }
  return 0;
}

static int vtremote_handshake(AVCodecContext *avctx) {
  VTRemoteEncContext *s = avctx->priv_data;
  int fd = connect_hostport(s->host, s->timeout_ms);
  if (fd < 0) {
    av_log(avctx, AV_LOG_ERROR, "Failed to connect to %s\n", s->host);
    return fd;
  }
  s->fd = fd;

  /* HELLO */
  VTRemoteWBuf payload;
  vtremote_wbuf_init(&payload);
  vtremote_payload_hello(&payload, s->token, codec_name_for_id(s->codec_id),
                         "ffmpeg-vtremote", FFMPEG_VERSION);
  int ret = vtremote_send_msg_blocking(s, VTREMOTE_MSG_HELLO, &payload);
  vtremote_wbuf_free(&payload);
  if (ret < 0) {
    VTR_CLOSE_SOCKET(fd);
    s->fd = -1;
    return ret;
  }

  VTRemoteMsgHeader hdr;
  uint8_t *pl = NULL;
  ret = vtremote_read_msg(s, &hdr, &pl);
  if (ret < 0) {
    VTR_CLOSE_SOCKET(fd);
    s->fd = -1;
    return ret;
  }
  if (hdr.type == VTREMOTE_MSG_ERROR) {
    vtremote_log_error_payload(avctx, pl, hdr.length);
    av_free(pl);
    VTR_CLOSE_SOCKET(fd);
    s->fd = -1;
    return AVERROR(EIO);
  }
  if (hdr.type != VTREMOTE_MSG_HELLO_ACK) {
    av_free(pl);
    VTR_CLOSE_SOCKET(fd);
    s->fd = -1;
    return AVERROR_INVALIDDATA;
  }
  ret = vtremote_handle_hello_ack(avctx, pl, hdr.length);
  av_free(pl);
  if (ret < 0) {
    VTR_CLOSE_SOCKET(fd);
    s->fd = -1;
    return ret;
  }

  /* CONFIGURE */
  VTRemoteKV *opts = NULL;
  int opt_count = 0;
  int opt_cap = 0;
  char *tmp = NULL;

  tmp = av_strdup("encode");
  ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "mode", tmp);
  if (ret < 0)
    goto cfg_fail;

  if (s->wire_compression > 0) {
    tmp = av_asprintf("%d", s->wire_compression);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret =
        vtremote_add_opt(&opts, &opt_count, &opt_cap, "wire_compression", tmp);
    if (ret < 0)
      goto cfg_fail;
  }

  if (avctx->bit_rate > 0) {
    tmp = av_asprintf("%" PRId64, avctx->bit_rate);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "bitrate", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (avctx->rc_max_rate > 0) {
    tmp = av_asprintf("%" PRId64, avctx->rc_max_rate);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "maxrate", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (avctx->gop_size > 0) {
    tmp = av_asprintf("%d", avctx->gop_size);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "gop", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (avctx->max_b_frames > 0) {
    tmp = av_asprintf("%d", avctx->max_b_frames);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "max_b_frames", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (avctx->flags) {
    tmp = av_asprintf("%d", avctx->flags);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "flags", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (avctx->global_quality > 0) {
    tmp = av_asprintf("%d", avctx->global_quality);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "global_quality", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (avctx->qmin >= 0) {
    tmp = av_asprintf("%d", avctx->qmin);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "qmin", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (avctx->qmax >= 0) {
    tmp = av_asprintf("%d", avctx->qmax);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "qmax", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  {
    int profile =
        s->profile != AV_PROFILE_UNKNOWN ? s->profile : avctx->profile;
    if (profile != AV_PROFILE_UNKNOWN) {
      tmp = av_asprintf("%d", profile);
      if (!tmp) {
        ret = AVERROR(ENOMEM);
        goto cfg_fail;
      }
      ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "profile", tmp);
      if (ret < 0)
        goto cfg_fail;
    }
  }
  if (s->level > 0) {
    tmp = av_asprintf("%d", s->level);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "level", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (s->entropy >= 0) {
    tmp = av_asprintf("%d", s->entropy);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "entropy", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (s->allow_sw) {
    tmp = av_strdup("1");
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "allow_sw", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (s->require_sw) {
    tmp = av_strdup("1");
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "require_sw", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (s->realtime >= 0) {
    tmp = av_asprintf("%d", s->realtime);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "realtime", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (s->frames_before) {
    tmp = av_strdup("1");
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "frames_before", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (s->frames_after) {
    tmp = av_strdup("1");
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "frames_after", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (s->prio_speed >= 0) {
    tmp = av_asprintf("%d", s->prio_speed);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "prio_speed", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (s->power_efficient >= 0) {
    tmp = av_asprintf("%d", s->power_efficient);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "power_efficient", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (s->spatialaq >= 0) {
    tmp = av_asprintf("%d", s->spatialaq);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "spatial_aq", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (s->max_ref_frames > 0) {
    tmp = av_asprintf("%d", s->max_ref_frames);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "max_ref_frames", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (s->max_slice_bytes >= 0) {
    tmp = av_asprintf("%d", s->max_slice_bytes);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "max_slice_bytes", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (s->constant_bit_rate) {
    tmp = av_strdup("1");
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret =
        vtremote_add_opt(&opts, &opt_count, &opt_cap, "constant_bit_rate", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (s->alpha_quality > 0.0) {
    tmp = av_asprintf("%.6f", s->alpha_quality);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "alpha_quality", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (avctx->color_range != AVCOL_RANGE_UNSPECIFIED) {
    tmp = av_asprintf("%d", avctx->color_range);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "color_range", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (avctx->colorspace != AVCOL_SPC_UNSPECIFIED) {
    tmp = av_asprintf("%d", avctx->colorspace);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "colorspace", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (avctx->color_primaries != AVCOL_PRI_UNSPECIFIED) {
    tmp = av_asprintf("%d", avctx->color_primaries);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "color_primaries", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (avctx->color_trc != AVCOL_TRC_UNSPECIFIED) {
    tmp = av_asprintf("%d", avctx->color_trc);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "color_trc", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (avctx->sample_aspect_ratio.num > 0 &&
      avctx->sample_aspect_ratio.den > 0) {
    tmp = av_asprintf("%d", avctx->sample_aspect_ratio.num);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "sar_num", tmp);
    if (ret < 0)
      goto cfg_fail;
    tmp = av_asprintf("%d", avctx->sample_aspect_ratio.den);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "sar_den", tmp);
    if (ret < 0)
      goto cfg_fail;
  }
  if (s->a53_cc >= 0) {
    tmp = av_asprintf("%d", s->a53_cc);
    if (!tmp) {
      ret = AVERROR(ENOMEM);
      goto cfg_fail;
    }
    ret = vtremote_add_opt(&opts, &opt_count, &opt_cap, "a53_cc", tmp);
    if (ret < 0)
      goto cfg_fail;
  }

  int wire_pix_fmt = vtremote_wire_pix_fmt_for_context(avctx, s->codec_id);
  if (wire_pix_fmt != 1 && wire_pix_fmt != 2) {
    av_log(avctx, AV_LOG_ERROR, "Unsupported pix_fmt for vtremote: %s\n",
           av_get_pix_fmt_name(avctx->pix_fmt));
    ret = AVERROR(EINVAL);
    goto cfg_fail;
  }
  VTRemoteWBuf cfg;
  vtremote_wbuf_init(&cfg);
  AVRational tb = avctx->time_base;
  if (tb.num <= 0 || tb.den <= 0 ||
      (tb.num == 1 && tb.den == 1 && avctx->framerate.num > 0 &&
       avctx->framerate.den > 0)) {
    if (avctx->pkt_timebase.num > 0 && avctx->pkt_timebase.den > 0) {
      tb = avctx->pkt_timebase;
    } else if (avctx->framerate.num > 0 && avctx->framerate.den > 0) {
      tb = av_inv_q(avctx->framerate);
    } else {
      tb = (AVRational){1, 1};
    }
  }

  AVRational fr = avctx->framerate;
  if (fr.num <= 0 || fr.den <= 0) {
    if (tb.num > 0 && tb.den > 0 && !(tb.num == 1 && tb.den == 1)) {
      fr = av_inv_q(tb);
    } else {
      fr = (AVRational){0, 0};
    }
  }

  vtremote_payload_configure(&cfg, avctx->width, avctx->height, wire_pix_fmt,
                             tb.num, tb.den, fr.num, fr.den,
                             opt_count ? opts : NULL, opt_count, NULL, 0);
  ret = vtremote_send_msg_blocking(s, VTREMOTE_MSG_CONFIGURE, &cfg);
cfg_fail:
  for (int i = 0; i < opt_count; i++)
    av_freep(&opts[i].value);
  av_freep(&opts);
  vtremote_wbuf_free(&cfg);
  if (ret < 0) {
    VTR_CLOSE_SOCKET(fd);
    s->fd = -1;
    return ret;
  }

  ret = vtremote_read_msg(s, &hdr, &pl);
  if (ret < 0) {
    VTR_CLOSE_SOCKET(fd);
    s->fd = -1;
    return ret;
  }
  if (hdr.type == VTREMOTE_MSG_ERROR) {
    vtremote_log_error_payload(avctx, pl, hdr.length);
    av_free(pl);
    VTR_CLOSE_SOCKET(fd);
    s->fd = -1;
    return AVERROR(EIO);
  }
  if (hdr.type != VTREMOTE_MSG_CONFIGURE_ACK) {
    av_free(pl);
    VTR_CLOSE_SOCKET(fd);
    s->fd = -1;
    return AVERROR_INVALIDDATA;
  }
  ret = vtremote_handle_configure_ack(avctx, pl, hdr.length);
  av_free(pl);
  if (ret < 0) {
    VTR_CLOSE_SOCKET(fd);
    s->fd = -1;
    return ret;
  }

  s->connected = 1;
  return 0;
}

static int enqueue_packet(AVCodecContext *avctx, const uint8_t *payload,
                          int payload_size) {
  VTRemoteEncContext *s = avctx->priv_data;
  VTRemotePacketView view;
  int ret = vtremote_parse_packet(payload, payload_size, &view);
  if (ret < 0)
    return ret;
  if (!s->pkt_queue)
    return AVERROR_BUG;
  int idx = (s->pkt_q_head + s->pkt_q_count) % s->pkt_q_size;
  AVPacket *dst = &s->pkt_queue[idx];
  av_packet_unref(dst);
  ret = av_new_packet(dst, view.data_len);
  if (ret < 0)
    return ret;
  memcpy(dst->data, view.data, view.data_len);
  dst->pts = view.pts;
  dst->dts = view.dts;
  dst->duration = view.duration;
  dst->flags = (view.flags & 1) ? AV_PKT_FLAG_KEY : 0;
  if (dst->dts == AV_NOPTS_VALUE)
    dst->dts = dst->pts;
  if (dst->dts != AV_NOPTS_VALUE) {
    if (s->last_dts != AV_NOPTS_VALUE && dst->dts <= s->last_dts)
      dst->dts = s->last_dts + 1;
    s->last_dts = dst->dts;
  }
  if (dst->pts == AV_NOPTS_VALUE)
    dst->pts = dst->dts;
  if (s->pkt_q_count < s->pkt_q_size)
    s->pkt_q_count++;
  else
    return AVERROR_BUFFER_TOO_SMALL;
  s->packets_recv++;
  return 0;
}

int ff_vtremote_common_init(AVCodecContext *avctx) {
  VTRemoteEncContext *s = avctx->priv_data;
  int ret;
  s->codec_id = avctx->codec_id;
  s->fd = -1;
  s->start_time_us = av_gettime_relative();
  s->frames_sent = 0;
  s->packets_recv = 0;
  s->bytes_sent = 0;
  s->bytes_recv = 0;
  s->max_inflight = 0;
  s->last_dts = AV_NOPTS_VALUE;
  vtremote_wbuf_init(&s->frame_buf);
  s->comp_buf[0] = s->comp_buf[1] = NULL;
  s->comp_buf_cap[0] = s->comp_buf_cap[1] = 0;
  s->zstd_cctx = NULL;
  s->zstd_last_level = -1;
  s->zstd_last_workers = -1;
  s->zstd_last_job_size = -1;
  s->send_queue = NULL;
  s->send_q_size = 0;
  s->send_q_head = 0;
  s->send_q_tail = 0;
  s->send_q_count = 0;
  s->queued_frames = 0;
  s->convert_frame = NULL;

  if (!s->host) {
    av_log(avctx, AV_LOG_ERROR, "vt_remote_host is required\n");
    return AVERROR(EINVAL);
  }

  vtremote_init_inflight(avctx, s);
  vtremote_apply_auto_wire_compression(avctx, s);

  if (vtremote_log_enabled(s, AV_LOG_VERBOSE)) {
    av_log(avctx, AV_LOG_VERBOSE,
           "VT remote init codec=%d host=%s inflight=%d timeout_ms=%d wire=%d\n",
           s->codec_id, s->host, s->inflight, s->timeout_ms,
           s->wire_compression);
  }

  ret = vtremote_net_init();
  if (ret < 0)
    return ret;

  {
    int inflight_cap =
        s->inflight_auto ? s->inflight_max_limit : s->inflight;
    s->send_q_size = FFMAX(4, inflight_cap * 2);
  }
  s->send_queue = av_calloc(s->send_q_size, sizeof(*s->send_queue));
  if (!s->send_queue)
    return AVERROR(ENOMEM);

  ret = vtremote_handshake(avctx);
  if (ret < 0) {
    vtremote_net_close();
    if (s->send_queue) {
      for (int i = 0; i < s->send_q_size; i++)
        vtremote_sendbuf_reset(&s->send_queue[i]);
      av_freep(&s->send_queue);
      s->send_q_size = 0;
      s->send_q_head = 0;
      s->send_q_tail = 0;
      s->send_q_count = 0;
      s->queued_frames = 0;
    }
  }
  return ret;
}

int ff_vtremote_common_close(AVCodecContext *avctx) {
  VTRemoteEncContext *s = avctx->priv_data;
  if (vtremote_log_enabled(s, AV_LOG_VERBOSE))
    av_log(avctx, AV_LOG_VERBOSE, "VT remote close\n");
  if (s->fd >= 0)
    VTR_CLOSE_SOCKET(s->fd);
  vtremote_net_close();
  vtremote_wbuf_free(&s->frame_buf);
  if (s->pkt_queue) {
    for (int i = 0; i < s->pkt_q_size; i++)
      av_packet_unref(&s->pkt_queue[i]);
    av_freep(&s->pkt_queue);
  }
  av_freep(&s->comp_buf[0]);
  av_freep(&s->comp_buf[1]);
  if (s->zstd_cctx) {
    ZSTD_freeCCtx(s->zstd_cctx);
    s->zstd_cctx = NULL;
  }
  if (s->send_queue) {
    for (int i = 0; i < s->send_q_size; i++)
      vtremote_sendbuf_reset(&s->send_queue[i]);
    av_freep(&s->send_queue);
  }
  av_frame_free(&s->convert_frame);
  if (vtremote_log_enabled(s, AV_LOG_INFO) && s->start_time_us > 0) {
    int64_t elapsed_us = av_gettime_relative() - s->start_time_us;
    double elapsed = elapsed_us > 0 ? (double)elapsed_us / 1000000.0 : 0.0;
    double mbps_in =
        elapsed > 0 ? (double)s->bytes_sent * 8.0 / (elapsed * 1000000.0) : 0.0;
    double mbps_out =
        elapsed > 0 ? (double)s->bytes_recv * 8.0 / (elapsed * 1000000.0) : 0.0;
    double avg_send_ms =
        s->send_frames > 0
            ? (double)s->send_time_us / (double)s->send_frames / 1000.0
            : 0.0;
    double avg_wait_ms = s->recv_calls > 0 ? (double)s->recv_wait_us /
                                                 (double)s->recv_calls / 1000.0
                                           : 0.0;
    av_log(avctx, AV_LOG_INFO,
           "VT remote summary: frames=%" PRId64 " packets=%" PRId64
           " bytes_in=%" PRId64 " bytes_out=%" PRId64
           " max_inflight=%d elapsed=%.3fs in=%.2fMb/s out=%.2fMb/s "
           "avg_send_ms=%.2f avg_wait_ms=%.2f\n",
           s->frames_sent, s->packets_recv, s->bytes_sent, s->bytes_recv,
           s->max_inflight, elapsed, mbps_in, mbps_out, avg_send_ms,
           avg_wait_ms);
  }
  av_opt_free(s);
  return 0;
}

int ff_vtremote_common_send_frame(AVCodecContext *avctx, const AVFrame *frame) {
  VTRemoteEncContext *s = avctx->priv_data;
  const AVFrame *upload_frame = frame;
  int ret;
  if (!s->connected)
    return AVERROR(EPIPE);

  if (!frame) {
    s->flushing = 1;
    ret = vtremote_sendq_enqueue_empty(s, VTREMOTE_MSG_FLUSH, 0);
    if (ret < 0)
      return ret;
    return vtremote_sendq_pump(avctx, 1);
  }

  ret = vtremote_prepare_upload_frame(avctx, frame, &upload_frame);
  if (ret < 0)
    return ret;

  if (!vtremote_is_upload_pix_fmt(upload_frame->format)) {
    av_log(avctx, AV_LOG_ERROR, "VTRemote supports NV12/P010 only\n");
    return AVERROR(EINVAL);
  }
  if (s->send_q_count >= s->send_q_size ||
      (s->queued_frames + s->inflight_frames) >= s->inflight) {
    if (s->inflight_auto)
      s->inflight_blocked++;
    return AVERROR(EAGAIN);
  }
  if (s->codec_id == AV_CODEC_ID_H264 &&
      upload_frame->format != AV_PIX_FMT_NV12) {
    av_log(avctx, AV_LOG_ERROR, "H.264 VTRemote only supports NV12\n");
    return AVERROR(EINVAL);
  }

  const uint8_t *planes[2] = {upload_frame->data[0], upload_frame->data[1]};
  uint32_t strides[2] = {upload_frame->linesize[0], upload_frame->linesize[1]};
  uint32_t heights[2] = {(uint32_t)upload_frame->height,
                         (uint32_t)(upload_frame->height / 2)};
  uint32_t sizes[2] = {strides[0] * heights[0], strides[1] * heights[1]};

  VTRemoteSideData sd[16];
  int sd_count = 0;
  if (frame->nb_side_data > 0) {
    for (int i = 0; i < frame->nb_side_data && sd_count < 16; i++) {
      AVFrameSideData *frame_sd = frame->side_data[i];
      // Only send A53 CC for now as per MVP request/parity
      if (frame_sd->type == AV_FRAME_DATA_A53_CC) {
        sd[sd_count].type = (uint32_t)frame_sd->type;
        sd[sd_count].size = (uint32_t)frame_sd->size;
        sd[sd_count].data = frame_sd->data;
        sd_count++;
      }
    }
  }

  ret = vtremote_sendq_enqueue_frame(
      avctx, s, upload_frame, planes, strides, heights, sizes,
      sd_count > 0 ? sd : NULL, sd_count);
  if (ret < 0)
    return ret;
  ret = vtremote_sendq_pump(avctx, 0);
  if (ret == AVERROR(EAGAIN))
    ret = 0;
  return ret;
}

int ff_vtremote_common_receive_packet(AVCodecContext *avctx, AVPacket *pkt) {
  VTRemoteEncContext *s = avctx->priv_data;
  if (s->done)
    return AVERROR_EOF;

  /* if queued packets, pop */
  if (s->pkt_q_count > 0) {
    AVPacket *src = &s->pkt_queue[s->pkt_q_head];
    int ret = av_packet_ref(pkt, src);
    av_packet_unref(src);
    s->pkt_q_head = (s->pkt_q_head + 1) % s->pkt_q_size;
    s->pkt_q_count--;
    return ret;
  }

  for (;;) {
    int64_t recv_start_us = av_gettime_relative();
    VTRemoteMsgHeader hdr;
    uint8_t *payload = NULL;
    int ret = vtremote_read_msg(s, &hdr, &payload);
    int64_t recv_elapsed_us = av_gettime_relative() - recv_start_us;
    if (recv_elapsed_us > 0) {
      s->recv_wait_us += recv_elapsed_us;
      s->recv_calls++;
    }
    vtremote_auto_adjust_inflight(avctx, s);
    if (ret < 0)
      return ret;

    switch (hdr.type) {
    case VTREMOTE_MSG_PACKET:
      ret = enqueue_packet(avctx, payload, hdr.length);
      av_free(payload);
      if (ret < 0)
        return ret;
      /* pop immediately */
      if (s->pkt_q_count > 0) {
        AVPacket *src = &s->pkt_queue[s->pkt_q_head];
        int rc = av_packet_ref(pkt, src);
        av_packet_unref(src);
        s->pkt_q_head = (s->pkt_q_head + 1) % s->pkt_q_size;
        s->pkt_q_count--;
        if (s->inflight_frames > 0)
          s->inflight_frames--;
        return rc;
      }
      return AVERROR_BUG;
    case VTREMOTE_MSG_DONE:
      av_free(payload);
      s->done = 1;
      return AVERROR_EOF;
    case VTREMOTE_MSG_PING: {
      vtremote_sendq_enqueue_empty(s, VTREMOTE_MSG_PONG, 0);
      vtremote_sendq_pump(avctx, 0);
      av_free(payload);
      break;
    }
    case VTREMOTE_MSG_ERROR: {
      vtremote_log_error_payload(avctx, payload, hdr.length);
      av_free(payload);
      return AVERROR(EIO);
    }
    default:
      av_free(payload);
      break;
    }
  }
}

int ff_vtremote_encode(AVCodecContext *avctx, AVPacket *pkt,
                       const AVFrame *frame, int *got_packet) {
  VTRemoteEncContext *s = avctx->priv_data;
  if (!s->pkt_queue) {
    int inflight_cap =
        s->inflight_auto ? s->inflight_max_limit : s->inflight;
    s->pkt_q_size = FFMAX(4, inflight_cap * 2); /* Double for better pipelining */
    s->pkt_queue = av_calloc(s->pkt_q_size, sizeof(AVPacket));
    if (!s->pkt_queue)
      return AVERROR(ENOMEM);
  }

  int ret = 0;

  /*
   * Pipelining optimization: Try to drain any available packets first
   * (non-blocking). This allows us to keep the pipeline full while receiving
   * encoded data.
   */
  ret = vtremote_sendq_pump(avctx, 0);
  if (ret < 0 && ret != AVERROR(EAGAIN))
    return ret;

  ret = vtremote_drain_available_packets(avctx);
  if (ret < 0 && ret != AVERROR(EAGAIN))
    return ret;

  /* Return a queued packet if available */
  if (s->pkt_q_count > 0) {
    AVPacket *src = &s->pkt_queue[s->pkt_q_head];
    int rc = av_packet_ref(pkt, src);
    av_packet_unref(src);
    s->pkt_q_head = (s->pkt_q_head + 1) % s->pkt_q_size;
    s->pkt_q_count--;
    if (got_packet)
      *got_packet = 1;
    /* Continue to send the frame if we have one (pipelining) */
    if (frame && s->inflight_frames < s->inflight) {
      ff_vtremote_common_send_frame(avctx, frame);
    }
    return rc;
  }

  /* If we have a frame and haven't hit the inflight limit, send it */
  if (frame && s->inflight_frames < s->inflight) {
    ret = ff_vtremote_common_send_frame(avctx, frame);
    if (ret == AVERROR(EAGAIN)) {
      int pump = vtremote_sendq_pump(avctx, 1);
      if (pump < 0 && pump != AVERROR(EAGAIN))
        return pump;
      ret = ff_vtremote_common_send_frame(avctx, frame);
    }
    if (ret == AVERROR(EAGAIN)) {
      if (got_packet)
        *got_packet = 0;
      return AVERROR(EAGAIN);
    }
    if (ret < 0 && ret != AVERROR_EOF)
      return ret;
  }

  /* If we have a frame but hit the inflight limit, we must wait for a packet */
  if (frame && s->inflight_frames >= s->inflight) {
    if (s->inflight_auto)
      s->inflight_blocked++;
    vtremote_sendq_pump(avctx, 1);
    /* Block until we get at least one packet */
    ret = ff_vtremote_common_receive_packet(avctx, pkt);
    if (ret >= 0) {
      if (got_packet)
        *got_packet = 1;
      /* Now send the pending frame since we freed up a slot */
      ff_vtremote_common_send_frame(avctx, frame);
      return 0;
    }
    if (got_packet)
      *got_packet = 0;
    return ret;
  }

  /* Handle flush/draining */
  if (!frame && avctx->internal->draining) {
    ret = ff_vtremote_common_send_frame(avctx, NULL);
    if (ret < 0 && ret != AVERROR_EOF)
      return ret;
  }

  /* Try to get a packet (blocking if flushing, otherwise non-blocking) */
  if (!frame || s->flushing) {
    ret = ff_vtremote_common_receive_packet(avctx, pkt);
    if (ret >= 0) {
      if (got_packet)
        *got_packet = 1;
      return 0;
    }
  }

  if (got_packet)
    *got_packet = 0;
  return frame ? 0 : ret; /* Return success if we sent a frame even without
                             packet yet */
}
