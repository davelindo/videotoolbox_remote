/*
 * VTRemoted Client - C++ implementation of the vtremoted protocol
 */

#include "vtremoted-client.h"
#include "vtremoted-protocol.h"

#include <lz4.h>
#include <zstd.h>

#include <obs-module.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "Ws2_32.lib")
typedef SOCKET socket_t;
#define SOCKET_INVALID INVALID_SOCKET
#define SOCKET_ERROR_VAL SOCKET_ERROR
#define close_socket closesocket
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
typedef int socket_t;
#define SOCKET_INVALID (-1)
#define SOCKET_ERROR_VAL (-1)
#define close_socket close
#endif

enum { READ_OK = 0, READ_ERROR = -1, READ_DISCONNECTED = -2 };
static int read_exact(socket_t sock, void *buf, size_t len);
static void log_err(const char *fmt, ...);

namespace {

constexpr uint32_t HELLO_ACK_MAX_BYTES = 64 * 1024;
constexpr uint32_t CONFIGURE_ACK_MAX_BYTES = 4 * 1024 * 1024;
constexpr uint32_t INBOUND_MESSAGE_MAX_BYTES = 8 * 1024 * 1024;

const char *wire_compression_name(int mode) {
  switch (mode) {
  case VTR_WIRE_NONE:
    return "none";
  case VTR_WIRE_LZ4:
    return "lz4";
  case VTR_WIRE_ZSTD:
    return "zstd";
  default:
    return "unknown";
  }
}

bool is_supported_wire_compression(int mode) {
  return mode == VTR_WIRE_NONE || mode == VTR_WIRE_LZ4 ||
         mode == VTR_WIRE_ZSTD;
}

bool validate_inbound_length(uint16_t type, uint32_t length, uint32_t cap) {
  if (length > cap) {
    log_err("Rejecting message type=%u len=%u cap=%u", (unsigned)type, length,
            cap);
    return false;
  }
  return true;
}

bool discard_exact(socket_t sock, uint32_t len) {
  std::array<uint8_t, 16 * 1024> scratch{};
  uint32_t remaining = len;
  while (remaining > 0) {
    const size_t chunk = std::min<size_t>(remaining, scratch.size());
    if (!read_exact(sock, scratch.data(), chunk))
      return false;
    remaining -= (uint32_t)chunk;
  }
  return true;
}

bool compress_plane_payload(const uint8_t *src, uint32_t src_size,
                            int wire_compression,
                            std::vector<uint8_t> &compress_buf,
                            const uint8_t *&payload,
                            size_t &payload_size) {
  payload = src;
  payload_size = src_size;

  switch (wire_compression) {
  case VTR_WIRE_NONE:
    return true;
  case VTR_WIRE_LZ4: {
    const int max_dst = LZ4_compressBound((int)src_size);
    if (max_dst <= 0) {
      log_err("Invalid LZ4 bound for src_size=%u", src_size);
      return false;
    }
    if (compress_buf.size() < (size_t)max_dst)
      compress_buf.resize((size_t)max_dst);
    const int compressed =
        LZ4_compress_default((const char *)src, (char *)compress_buf.data(),
                             (int)src_size, max_dst);
    if (compressed <= 0) {
      log_err("LZ4 compression failed src_size=%u", src_size);
      return false;
    }
    payload = compress_buf.data();
    payload_size = (size_t)compressed;
    return true;
  }
  case VTR_WIRE_ZSTD: {
    const size_t max_dst = ZSTD_compressBound((size_t)src_size);
    if (max_dst == 0 || ZSTD_isError(max_dst)) {
      log_err("Invalid Zstd bound for src_size=%u", src_size);
      return false;
    }
    if (compress_buf.size() < max_dst)
      compress_buf.resize(max_dst);
    const size_t compressed =
        ZSTD_compress(compress_buf.data(), max_dst, src, (size_t)src_size,
                      ZSTD_CLEVEL_DEFAULT);
    if (ZSTD_isError(compressed) || compressed == 0) {
      log_err("Zstd compression failed src_size=%u err=%s", src_size,
              ZSTD_getErrorName(compressed));
      return false;
    }
    payload = compress_buf.data();
    payload_size = compressed;
    return true;
  }
  default:
    log_err("Unsupported wire compression mode=%d", wire_compression);
    return false;
  }
}

} // namespace

/* Big-endian helpers */
static inline uint16_t be16(uint16_t v) {
  uint8_t *p = (uint8_t *)&v;
  return (uint16_t)p[0] << 8 | p[1];
}
static inline uint32_t be32(uint32_t v) {
  uint8_t *p = (uint8_t *)&v;
  return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 |
         p[3];
}
static inline int64_t be64(int64_t v) {
  uint8_t *p = (uint8_t *)&v;
  return (int64_t)p[0] << 56 | (int64_t)p[1] << 48 | (int64_t)p[2] << 40 |
         (int64_t)p[3] << 32 | (int64_t)p[4] << 24 | (int64_t)p[5] << 16 |
         (int64_t)p[6] << 8 | p[7];
}

static inline void write_be16(uint8_t *p, uint16_t v) {
  p[0] = (v >> 8) & 0xFF;
  p[1] = v & 0xFF;
}
static inline void write_be32(uint8_t *p, uint32_t v) {
  p[0] = (v >> 24) & 0xFF;
  p[1] = (v >> 16) & 0xFF;
  p[2] = (v >> 8) & 0xFF;
  p[3] = v & 0xFF;
}
static inline void write_be64(uint8_t *p, int64_t v) {
  for (int i = 0; i < 8; i++)
    p[i] = (v >> (56 - i * 8)) & 0xFF;
}

struct VTRemotedClient {
  socket_t sock;
  std::string host;
  int port;
  std::string token;

  bool connected;
  bool configured;

  uint32_t width;
  uint32_t height;
  uint32_t pix_fmt;

  std::vector<uint8_t> extradata;
  std::vector<uint8_t> send_buf;
  std::vector<uint8_t> recv_buf;
  std::vector<uint8_t> compress_buf;

  int wire_compression;

  VTRemotedClient()
      : sock(SOCKET_INVALID), port(VTR_PORT), connected(false),
        configured(false), width(0), height(0), pix_fmt(VTR_PIX_FMT_NV12),
        wire_compression(VTR_WIRE_LZ4) {}
};

VTRemotedClient *vtremoted_client_create(void) { return new VTRemotedClient(); }

void vtremoted_client_destroy(VTRemotedClient *client) {
  if (!client)
    return;
  vtremoted_client_disconnect(client);
  delete client;
}

static int read_exact(socket_t sock, void *buf, size_t len) {
  uint8_t *p = (uint8_t *)buf;
  size_t got = 0;
  while (got < len) {
    ssize_t r = recv(sock, (char *)(p + got), (int)(len - got), 0);
    if (r == 0)
      return READ_DISCONNECTED;
    if (r < 0) {
#ifdef _WIN32
      int err = WSAGetLastError();
      if (err == WSAEWOULDBLOCK || err == WSAETIMEDOUT)
        continue;
#else
      if (errno == EAGAIN || errno == EINTR)
        continue;
#endif
      return READ_ERROR;
    }
    got += r;
  }
  return READ_OK;
}

static void log_err(const char *fmt, ...) {
  char buffer[4096];
  va_list args;
  va_start(args, fmt);
  vsnprintf(buffer, sizeof(buffer), fmt, args);
  va_end(args);

  blog(LOG_WARNING, "[vtremoted-client] %s", buffer);
}

static bool write_all(socket_t sock, const void *buf, size_t len) {
  const uint8_t *p = (const uint8_t *)buf;
  size_t sent = 0;
  while (sent < len) {
    ssize_t w = send(sock, (const char *)(p + sent), (int)(len - sent), 0);
    if (w <= 0) {
      log_err("write_all failed: w=%zd errno=%d", w, errno);
      return false;
    }
    sent += w;
  }
  return true;
}

static bool send_msg(socket_t sock, uint16_t type, const uint8_t *body,
                     uint32_t len) {
  uint8_t hdr[12];
  write_be32(hdr, VTR_MAGIC);
  write_be16(hdr + 4, VTR_VERSION);
  write_be16(hdr + 6, type);
  write_be32(hdr + 8, len);
  if (!write_all(sock, hdr, 12)) {
    log_err("send_msg header failed type=%d", type);
    return false;
  }
  if (len > 0 && !write_all(sock, body, len)) {
    log_err("send_msg body failed type=%d len=%d", type, len);
    return false;
  }
  return true;
}

static bool recv_header(socket_t sock, struct vtr_header *hdr) {
  uint8_t buf[12];
  if (!read_exact(sock, buf, 12))
    return false;
  hdr->magic = be32(*(uint32_t *)buf);
  hdr->version = be16(*(uint16_t *)(buf + 4));
  hdr->type = be16(*(uint16_t *)(buf + 6));
  hdr->length = be32(*(uint32_t *)(buf + 8));
  return hdr->magic == VTR_MAGIC;
}

bool vtremoted_client_connect(VTRemotedClient *client, const char *host,
                              int port, const char *token) {
  if (!client || client->connected)
    return false;

  client->host = host ? host : "127.0.0.1";
  client->port = port > 0 ? port : VTR_PORT;
  client->token = token ? token : "";

#ifdef _WIN32
  WSADATA wsa;
  WSAStartup(MAKEWORD(2, 2), &wsa);
#endif

  client->sock = socket(AF_INET, SOCK_STREAM, 0);
  if (client->sock == SOCKET_INVALID)
    return false;

  /* TCP_NODELAY for low latency */
  int yes = 1;
  setsockopt(client->sock, IPPROTO_TCP, TCP_NODELAY, (const char *)&yes,
             sizeof(yes));

  struct sockaddr_in addr = {};
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)client->port);
  if (inet_pton(AF_INET, client->host.c_str(), &addr.sin_addr) != 1) {
    log_err("Invalid address: %s", client->host.c_str());
    close_socket(client->sock);
    client->sock = SOCKET_INVALID;
    return false;
  }

  if (connect(client->sock, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    close_socket(client->sock);
    client->sock = SOCKET_INVALID;
    return false;
  }

  client->connected = true;

  /* Send HELLO */
  std::vector<uint8_t> hello;
  /* token length (2) + token + codec length (2) + codec + client_name length
   * (2) + client_name + build length (2) + build */
  auto add_string = [&hello](const char *s) {
    size_t len = s ? strlen(s) : 0;
    hello.push_back((len >> 8) & 0xFF);
    hello.push_back(len & 0xFF);
    if (len > 0)
      hello.insert(hello.end(), s, s + len);
  };
  add_string(client->token.c_str());
  add_string("h264");
  add_string("obs-vtremoted");
  add_string("1.0.0");

  log_err("Sending HELLO");
  if (!send_msg(client->sock, VTR_MSG_HELLO, hello.data(),
                (uint32_t)hello.size())) {
    log_err("Send HELLO failed");
    vtremoted_client_disconnect(client);
    return false;
  }

  /* Receive HELLO_ACK */
  struct vtr_header hdr;
  if (!recv_header(client->sock, &hdr)) {
    log_err("Recv HELLO_ACK header failed");
    vtremoted_client_disconnect(client);
    return false;
  }
  if (hdr.type != VTR_MSG_HELLO_ACK) {
    log_err("Expected HELLO_ACK (2), got %d", hdr.type);
    vtremoted_client_disconnect(client);
    return false;
  }
  if (!validate_inbound_length(hdr.type, hdr.length, HELLO_ACK_MAX_BYTES)) {
    vtremoted_client_disconnect(client);
    return false;
  }
  log_err("Received HELLO_ACK header, len=%d", hdr.length);

  std::vector<uint8_t> ack_body(hdr.length);
  if (hdr.length > 0 && !read_exact(client->sock, ack_body.data(), hdr.length)) {
    log_err("Recv HELLO_ACK body failed");
    vtremoted_client_disconnect(client);
    return false;
  }

  /* Check status */
  if (ack_body.size() < 1 || ack_body[0] != VTR_STATUS_OK) {
    log_err("HELLO_ACK status error: %d",
            ack_body.size() > 0 ? ack_body[0] : -1);
    vtremoted_client_disconnect(client);
    return false;
  }
  log_err("Connected successfully");

  return true;
}

void vtremoted_client_disconnect(VTRemotedClient *client) {
  if (!client)
    return;
  if (client->sock != SOCKET_INVALID) {
    close_socket(client->sock);
    client->sock = SOCKET_INVALID;
  }
  client->connected = false;
  client->configured = false;
}

bool vtremoted_client_is_connected(VTRemotedClient *client) {
  return client && client->connected;
}

bool vtremoted_client_configure(VTRemotedClient *client, uint32_t width,
                                uint32_t height, uint8_t pix_fmt,
                                uint32_t time_base_num, uint32_t time_base_den,
                                uint32_t fr_num, uint32_t fr_den, int bitrate,
                                int gop, int wire_compression) {
  if (!client || !client->connected)
    return false;
  if (!is_supported_wire_compression(wire_compression)) {
    log_err("Unsupported wire compression mode=%d", wire_compression);
    return false;
  }

  client->width = width;
  client->height = height;
  client->pix_fmt = pix_fmt;
  client->wire_compression = wire_compression;

  /* Build CONFIGURE message */
  std::vector<uint8_t> cfg;
  cfg.resize(25); /* width(4) + height(4) + pix_fmt(1) + time_bases + frs */
  write_be32(cfg.data(), width);
  write_be32(cfg.data() + 4, height);
  cfg[8] = pix_fmt;
  write_be32(cfg.data() + 9, time_base_num);
  write_be32(cfg.data() + 13, time_base_den);
  write_be32(cfg.data() + 17, fr_num);
  write_be32(cfg.data() + 21, fr_den);

  /* Options map: key-value pairs */
  auto add_string = [&cfg](const char *value) {
    size_t len = value ? strlen(value) : 0;
    cfg.push_back((len >> 8) & 0xFF);
    cfg.push_back(len & 0xFF);
    if (len > 0) {
      cfg.insert(cfg.end(), value, value + len);
    }
  };

  int option_count = 0;
  auto add_option = [&cfg, &add_string, &option_count](const char *key,
                                                        const char *value) {
    size_t klen = strlen(key);
    if (klen == 0)
      return;
    add_string(key);
    add_string(value);
    option_count += 1;
  };

  auto add_option_int = [&add_option](const char *key, int value) {
    char tmp[32];
    snprintf(tmp, sizeof(tmp), "%d", value);
    add_option(key, tmp);
  };

  /* Option count (patched after options are appended). */
  const size_t option_count_pos = cfg.size();
  cfg.push_back(0);
  cfg.push_back(0);

  add_option("mode", "encode");
  add_option_int("bitrate", bitrate);
  add_option_int("gop", gop);
  add_option_int("wire_compression", wire_compression);

  cfg[option_count_pos] = (option_count >> 8) & 0xFF;
  cfg[option_count_pos + 1] = option_count & 0xFF;

  /* Extradata (empty for encode mode) */
  cfg.push_back(0);
  cfg.push_back(0);
  cfg.push_back(0);
  cfg.push_back(0);

  log_err("Sending CONFIGURE, len=%u", (uint32_t)cfg.size());
  if (!send_msg(client->sock, VTR_MSG_CONFIGURE, cfg.data(),
                (uint32_t)cfg.size())) {
    log_err("Send CONFIGURE failed");
    return false;
  }

  /* Receive CONFIGURE_ACK */
  struct vtr_header hdr;
  log_err("Waiting for CONFIGURE_ACK");
  if (!recv_header(client->sock, &hdr)) {
    log_err("Recv CONFIGURE_ACK header failed");
    return false;
  }
  if (hdr.type != VTR_MSG_CONFIGURE_ACK) {
    log_err("Expected CONFIGURE_ACK (4), got %d", hdr.type);
    return false;
  }
  if (!validate_inbound_length(hdr.type, hdr.length, CONFIGURE_ACK_MAX_BYTES)) {
    vtremoted_client_disconnect(client);
    return false;
  }
  log_err("Received CONFIGURE_ACK, len=%d", hdr.length);

  std::vector<uint8_t> ack_body(hdr.length);
  if (hdr.length > 0 && !read_exact(client->sock, ack_body.data(), hdr.length)) {
    log_err("Recv CONFIGURE_ACK body failed");
    return false;
  }

  if (ack_body.size() < 4) {
    log_err("CONFIGURE_ACK too short: %zu", ack_body.size());
    return false;
  }

  const uint8_t status = ack_body[0];
  if (status != VTR_STATUS_OK) {
    log_err("CONFIGURE_ACK status error: %u", status);
    return false;
  }

  const uint16_t extradata_len = (uint16_t(ack_body[1]) << 8) | ack_body[2];
  const size_t expected_min = size_t(3) + extradata_len + 2; // +pixel_format +warnings
  if (ack_body.size() < expected_min) {
    log_err("CONFIGURE_ACK malformed: extradata_len=%u body_len=%zu",
            extradata_len, ack_body.size());
    return false;
  }

  client->extradata.assign(ack_body.begin() + 3,
                           ack_body.begin() + 3 + extradata_len);
  client->configured = true;
  return true;
}

const uint8_t *vtremoted_client_get_extradata(VTRemotedClient *client,
                                              size_t *size) {
  if (!client || client->extradata.empty()) {
    if (size)
      *size = 0;
    return nullptr;
  }
  if (size)
    *size = client->extradata.size();
  return client->extradata.data();
}

bool vtremoted_client_send_frame(VTRemotedClient *client, int64_t pts,
                                 int64_t duration, uint8_t plane_count,
                                 const uint8_t *const *planes,
                                 const uint32_t *strides,
                                 const uint32_t *heights,
                                 const uint32_t *sizes) {
  if (!client || !client->connected || !client->configured)
    return false;

  std::vector<uint8_t> &buf = client->send_buf;
  buf.clear();
  buf.resize(21);
  write_be64(buf.data(), pts);
  write_be64(buf.data() + 8, duration);
  write_be32(buf.data() + 16, 0); // flags
  buf[20] = plane_count;

  for (int i = 0; i < plane_count; i++) {
    uint8_t meta[12];
    write_be32(meta, strides[i]);
    write_be32(meta + 4, heights[i]);

    const uint8_t *payload = planes[i];
    size_t payload_size = sizes[i];

    if (!compress_plane_payload(planes[i], sizes[i], client->wire_compression,
                                client->compress_buf, payload, payload_size)) {
      log_err("Failed to compress plane=%d mode=%s", i,
              wire_compression_name(client->wire_compression));
      return false;
    }

    write_be32(meta + 8, (uint32_t)payload_size);
    buf.insert(buf.end(), meta, meta + 12);
    buf.insert(buf.end(), payload, payload + payload_size);
  }

  // Side data count (0)
  buf.push_back(0);

  return send_msg(client->sock, VTR_MSG_FRAME, buf.data(),
                  (uint32_t)buf.size());
}

bool vtremoted_client_receive_packet(VTRemotedClient *client,
                                     const uint8_t **out_data, size_t *out_size,
                                     int64_t *out_pts, int64_t *out_dts,
                                     bool *out_keyframe) {
  if (!client || !client->connected)
    return false;

  struct vtr_header hdr;
  if (!recv_header(client->sock, &hdr))
    return false;
  if (!validate_inbound_length(hdr.type, hdr.length,
                               INBOUND_MESSAGE_MAX_BYTES)) {
    vtremoted_client_disconnect(client);
    return false;
  }

  if (hdr.type == VTR_MSG_ERROR || hdr.type == VTR_MSG_DONE) {
    /* Skip body */
    if (hdr.length > 0 && !discard_exact(client->sock, hdr.length))
      vtremoted_client_disconnect(client);
    return false;
  }

  if (hdr.type != VTR_MSG_PACKET) {
    /* Unexpected message, skip */
    if (hdr.length > 0 && !discard_exact(client->sock, hdr.length))
      vtremoted_client_disconnect(client);
    return false;
  }

  /* Packet: pts(8) + dts(8) + duration(8) + flags(4) + data */
  std::vector<uint8_t> &buf = client->recv_buf;
  buf.resize(hdr.length);
  if (!read_exact(client->sock, buf.data(), hdr.length))
    return false;

  if (buf.size() < 32)
    return false;

  int64_t pts = be64(*(int64_t *)buf.data());
  int64_t dts = be64(*(int64_t *)(buf.data() + 8));
  /* int64_t duration = be64(*(int64_t *)(buf.data() + 16)); */
  uint32_t flags = be32(*(uint32_t *)(buf.data() + 24));
  uint32_t data_len = be32(*(uint32_t *)(buf.data() + 28));

  size_t data_offset = 32;
  if (buf.size() < data_offset + data_len)
    return false;

  *out_data = buf.data() + data_offset;
  *out_size = data_len;
  *out_pts = pts;
  *out_dts = dts;
  *out_keyframe = (flags & 1) != 0;

  return true;
}
