/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define _POSIX_C_SOURCE 200809L
#include "vtremote/client.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

#define VTR_CAP_H264 (UINT64_C(1) << 0)
#define VTR_CAP_HEVC (UINT64_C(1) << 1)
#define VTR_CAP_NV12 (UINT64_C(1) << 2)
#define VTR_CAP_P010 (UINT64_C(1) << 3)

#ifndef VTREMOTE_VERSION
#define VTREMOTE_VERSION "dev"
#endif

static void set_error(char *error, size_t error_size, const char *fmt, ...) {
    va_list ap;
    if (!error || error_size == 0) return;
    va_start(ap, fmt);
    vsnprintf(error, error_size, fmt, ap);
    va_end(ap);
}

static uint16_t read_be16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static uint32_t read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | p[3];
}

static int append_annexb_nal(VTRBuffer *out, const uint8_t *data, size_t size) {
    static const uint8_t start_code[] = {0, 0, 0, 1};
    int rc;

    if (!out || !data || size == 0) return -EINVAL;
    if ((rc = vtr_put_bytes(out, start_code, sizeof(start_code))) < 0) return rc;
    return vtr_put_bytes(out, data, size);
}

static void parameter_set_flags(const uint8_t *data, size_t size,
                                const char *codec, unsigned *flags) {
    size_t offset = 0;

    if (!data || !codec || !flags) return;
    while (offset + 3 < size) {
        size_t nal_offset;
        uint8_t nal_type;

        if (data[offset] != 0 || data[offset + 1] != 0) {
            ++offset;
            continue;
        }
        if (data[offset + 2] == 1) {
            nal_offset = offset + 3;
        } else if (offset + 4 < size && data[offset + 2] == 0 &&
                   data[offset + 3] == 1) {
            nal_offset = offset + 4;
        } else {
            ++offset;
            continue;
        }
        if (nal_offset >= size) break;
        if (strcmp(codec, "hevc") == 0) {
            nal_type = (uint8_t)((data[nal_offset] >> 1) & 0x3fU);
            if (nal_type == 32) *flags |= 1U;
            if (nal_type == 33) *flags |= 2U;
            if (nal_type == 34) *flags |= 4U;
        } else {
            nal_type = data[nal_offset] & 0x1fU;
            if (nal_type == 7) *flags |= 1U;
            if (nal_type == 8) *flags |= 2U;
        }
        offset = nal_offset + 1;
    }
}

static int avcc_to_annexb(const uint8_t *data, size_t size, VTRBuffer *out) {
    size_t offset;
    unsigned flags = 0;
    unsigned index;
    unsigned count;
    int rc;

    if (!data || size < 7 || data[0] != 1 || !out) return -EPROTO;
    offset = 5;
    count = data[offset++] & 0x1fU;
    for (index = 0; index < count; ++index) {
        uint16_t nal_size;
        if (offset + 2 > size) return -EPROTO;
        nal_size = read_be16(data + offset);
        offset += 2;
        if (nal_size == 0 || offset + nal_size > size) return -EPROTO;
        if ((data[offset] & 0x1fU) == 7) flags |= 1U;
        if ((rc = append_annexb_nal(out, data + offset, nal_size)) < 0) return rc;
        offset += nal_size;
    }
    if (offset >= size) return -EPROTO;
    count = data[offset++];
    for (index = 0; index < count; ++index) {
        uint16_t nal_size;
        if (offset + 2 > size) return -EPROTO;
        nal_size = read_be16(data + offset);
        offset += 2;
        if (nal_size == 0 || offset + nal_size > size) return -EPROTO;
        if ((data[offset] & 0x1fU) == 8) flags |= 2U;
        if ((rc = append_annexb_nal(out, data + offset, nal_size)) < 0) return rc;
        offset += nal_size;
    }
    return flags == 3U ? 0 : -EPROTO;
}

static int hvcc_to_annexb(const uint8_t *data, size_t size, VTRBuffer *out) {
    size_t offset;
    unsigned flags = 0;
    unsigned array_index;
    unsigned array_count;

    if (!data || size < 23 || data[0] != 1 || !out) return -EPROTO;
    array_count = data[22];
    offset = 23;
    for (array_index = 0; array_index < array_count; ++array_index) {
        uint8_t nal_type;
        uint16_t nal_count;
        unsigned nal_index;

        if (offset + 3 > size) return -EPROTO;
        nal_type = data[offset++] & 0x3fU;
        nal_count = read_be16(data + offset);
        offset += 2;
        for (nal_index = 0; nal_index < nal_count; ++nal_index) {
            uint16_t nal_size;
            int rc;
            if (offset + 2 > size) return -EPROTO;
            nal_size = read_be16(data + offset);
            offset += 2;
            if (nal_size == 0 || offset + nal_size > size) return -EPROTO;
            if (nal_type >= 32 && nal_type <= 34) {
                flags |= 1U << (nal_type - 32);
                rc = append_annexb_nal(out, data + offset, nal_size);
                if (rc < 0) return rc;
            }
            offset += nal_size;
        }
    }
    return flags == 7U ? 0 : -EPROTO;
}

static int store_parameter_sets(VTRClient *client, const uint8_t *data,
                                size_t size) {
    unsigned flags = 0;
    unsigned required;
    int rc;

    if (!client) return -EINVAL;
    vtr_buffer_reset(&client->parameter_sets);
    if (size == 0) return 0;
    if (!data) return -EINVAL;

    if (size >= 8 && read_be32(data) == size &&
        ((memcmp(data + 4, "avcC", 4) == 0) ||
         (memcmp(data + 4, "hvcC", 4) == 0))) {
        data += 8;
        size -= 8;
    }
    if (size >= 4 && data[0] == 0 && data[1] == 0 &&
        (data[2] == 1 || (data[2] == 0 && data[3] == 1))) {
        parameter_set_flags(data, size, client->codec, &flags);
        required = strcmp(client->codec, "hevc") == 0 ? 7U : 3U;
        if ((flags & required) != required) return -EPROTO;
        return vtr_put_bytes(&client->parameter_sets, data, size);
    }
    rc = strcmp(client->codec, "hevc") == 0
             ? hvcc_to_annexb(data, size, &client->parameter_sets)
             : avcc_to_annexb(data, size, &client->parameter_sets);
    if (rc < 0) vtr_buffer_reset(&client->parameter_sets);
    return rc;
}

static void write_be16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)v;
}

static void write_be32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)v;
}

static int parse_endpoint(const char *endpoint, char *host, size_t host_size,
                          char *port, size_t port_size) {
    const char *colon = NULL;
    size_t host_len;
    if (!endpoint || !*endpoint || !host || !port) return -EINVAL;
    if (endpoint[0] == '[') {
        const char *end = strchr(endpoint, ']');
        if (!end) return -EINVAL;
        host_len = (size_t)(end - endpoint - 1);
        if (end[1] == ':') {
            if (!end[2]) return -EINVAL;
            snprintf(port, port_size, "%s", end + 2);
        } else if (!end[1]) {
            snprintf(port, port_size, "%s", VTR_DEFAULT_PORT);
        } else {
            return -EINVAL;
        }
        if (host_len == 0 || host_len >= host_size) return -ENAMETOOLONG;
        memcpy(host, endpoint + 1, host_len);
        host[host_len] = '\0';
        return 0;
    }

    colon = strrchr(endpoint, ':');
    if (colon && strchr(endpoint, ':') == colon) {
        host_len = (size_t)(colon - endpoint);
        if (!colon[1]) return -EINVAL;
        snprintf(port, port_size, "%s", colon + 1);
    } else {
        host_len = strlen(endpoint);
        snprintf(port, port_size, "%s", VTR_DEFAULT_PORT);
    }
    if (host_len == 0 || host_len >= host_size) return -ENAMETOOLONG;
    memcpy(host, endpoint, host_len);
    host[host_len] = '\0';
    return 0;
}

static int socket_connect_timeout(const char *endpoint, int timeout_ms,
                                  char *error, size_t error_size) {
    char host[384];
    char port[32];
    struct addrinfo hints;
    struct addrinfo *addresses = NULL;
    struct addrinfo *it;
    int fd = -1;
    int gai;
    int last_error = ECONNREFUSED;

    if (parse_endpoint(endpoint, host, sizeof(host), port, sizeof(port)) < 0) {
        set_error(error, error_size, "invalid endpoint '%s'", endpoint ? endpoint : "");
        return -EINVAL;
    }
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    gai = getaddrinfo(host, port, &hints, &addresses);
    if (gai != 0) {
        set_error(error, error_size, "getaddrinfo(%s): %s", host, gai_strerror(gai));
        return -EHOSTUNREACH;
    }

    for (it = addresses; it; it = it->ai_next) {
        int flags;
        int rc;
        struct pollfd pfd;
        socklen_t optlen;
        int so_error = 0;
        struct timeval tv;

        fd = socket(it->ai_family, it->ai_socktype, it->ai_protocol);
        if (fd < 0) {
            last_error = errno;
            continue;
        }
        flags = fcntl(fd, F_GETFL, 0);
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
            last_error = errno;
            close(fd);
            fd = -1;
            continue;
        }
        rc = connect(fd, it->ai_addr, it->ai_addrlen);
        if (rc < 0 && errno != EINPROGRESS) {
            last_error = errno;
            close(fd);
            fd = -1;
            continue;
        }
        if (rc < 0) {
            pfd.fd = fd;
            pfd.events = POLLOUT;
            pfd.revents = 0;
            rc = poll(&pfd, 1, timeout_ms);
            if (rc == 0) {
                last_error = ETIMEDOUT;
                close(fd);
                fd = -1;
                continue;
            }
            if (rc < 0) {
                last_error = errno;
                close(fd);
                fd = -1;
                continue;
            }
            optlen = sizeof(so_error);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_error, &optlen) < 0 || so_error) {
                last_error = so_error ? so_error : errno;
                close(fd);
                fd = -1;
                continue;
            }
        }
        if (fcntl(fd, F_SETFL, flags) < 0) {
            last_error = errno;
            close(fd);
            fd = -1;
            continue;
        }
        tv.tv_sec = timeout_ms / 1000;
        tv.tv_usec = (timeout_ms % 1000) * 1000;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        break;
    }
    freeaddrinfo(addresses);
    if (fd < 0) {
        set_error(error, error_size, "connect(%s): %s", endpoint, strerror(last_error));
        return -last_error;
    }
    return fd;
}

static int write_all(int fd, const uint8_t *data, size_t size) {
    size_t offset = 0;
    while (offset < size) {
        ssize_t written = send(fd, data + offset, size - offset, MSG_NOSIGNAL);
        if (written < 0) {
            if (errno == EINTR) continue;
            return -errno;
        }
        if (written == 0) return -EPIPE;
        offset += (size_t)written;
    }
    return 0;
}

static int read_all(int fd, uint8_t *data, size_t size) {
    size_t offset = 0;
    while (offset < size) {
        ssize_t count = recv(fd, data + offset, size - offset, 0);
        if (count < 0) {
            if (errno == EINTR) continue;
            return -errno;
        }
        if (count == 0) return -ECONNRESET;
        offset += (size_t)count;
    }
    return 0;
}

static int send_message(VTRClient *client, uint16_t type,
                        const uint8_t *payload, size_t payload_size) {
    uint8_t header[VTR_HEADER_SIZE];
    uint32_t wire_size;
    int rc;
    if (!client || client->fd < 0) return -ENOTCONN;
    if (payload_size > UINT32_MAX) return -EOVERFLOW;
    wire_size = (uint32_t)payload_size;
    if (vtr_validate_message_size(type, wire_size) < 0) return -EOVERFLOW;
    write_be32(header, VTR_PROTO_MAGIC);
    write_be16(header + 4, VTR_PROTO_VERSION);
    write_be16(header + 6, type);
    write_be32(header + 8, wire_size);
    if ((rc = write_all(client->fd, header, sizeof(header))) < 0) return rc;
    if (payload_size) return write_all(client->fd, payload, payload_size);
    return 0;
}

static int receive_message(VTRClient *client, VTRMessage *message) {
    uint8_t header[VTR_HEADER_SIZE];
    uint32_t magic;
    uint16_t version;
    uint32_t size;
    int rc;
    if (!client || !message || client->fd < 0) return -EINVAL;
    memset(message, 0, sizeof(*message));
    if ((rc = read_all(client->fd, header, sizeof(header))) < 0) return rc;
    magic = read_be32(header);
    version = read_be16(header + 4);
    message->type = read_be16(header + 6);
    size = read_be32(header + 8);
    if (magic != VTR_PROTO_MAGIC || version != VTR_PROTO_VERSION) return -EPROTO;
    if (vtr_validate_message_size(message->type, size) < 0) return -EOVERFLOW;
    if (vtr_buffer_reserve(&client->rx, size) < 0) return -ENOMEM;
    client->rx.size = size;
    if (size && (rc = read_all(client->fd, client->rx.data, size)) < 0) return rc;
    message->payload = client->rx.data;
    message->payload_size = size;
    return 0;
}

typedef struct Reader {
    const uint8_t *data;
    size_t size;
    size_t pos;
} Reader;

static int reader_u8(Reader *r, uint8_t *value) {
    if (!r || !value || r->pos >= r->size) return -EPROTO;
    *value = r->data[r->pos++];
    return 0;
}

static int reader_u16(Reader *r, uint16_t *value) {
    if (!r || !value || r->size - r->pos < 2) return -EPROTO;
    *value = read_be16(r->data + r->pos);
    r->pos += 2;
    return 0;
}

static int reader_string(Reader *r, const uint8_t **value, uint16_t *length) {
    uint16_t len;
    if (reader_u16(r, &len) < 0 || r->size - r->pos < len) return -EPROTO;
    if (value) *value = r->data + r->pos;
    if (length) *length = len;
    r->pos += len;
    return 0;
}

static uint64_t capability_for(const uint8_t *name, uint16_t length) {
#define CAP(s, f) if (length == sizeof(s) - 1 && memcmp(name, s, sizeof(s) - 1) == 0) return (f)
    CAP("h264", VTR_CAP_H264);
    CAP("hevc", VTR_CAP_HEVC);
    CAP("pixfmt.nv12", VTR_CAP_NV12);
    CAP("pixfmt.p010", VTR_CAP_P010);
#undef CAP
    return 0;
}

static VTRWireCompression resolve_wire_compression(const VTRClientConfig *config) {
    double bytes_per_pixel;
    double fps;
    double raw_mbps;
    if (config->wire_compression != VTR_WIRE_COMPRESSION_AUTO)
        return config->wire_compression;
    bytes_per_pixel = config->pixel_format == VTR_PIXFMT_P010 ? 3.0 : 1.5;
    fps = config->frame_rate_den
              ? (double)config->frame_rate_num / config->frame_rate_den
              : 30.0;
    raw_mbps = bytes_per_pixel * config->width * config->height * fps * 8.0 /
               1000000.0;
    return raw_mbps > 0.0 && raw_mbps < 200.0
               ? VTR_WIRE_COMPRESSION_ZSTD
               : VTR_WIRE_COMPRESSION_LZ4;
}

static int parse_hello_ack(VTRClient *client, const VTRMessage *message,
                           const VTRClientConfig *config,
                           char *error, size_t error_size) {
    Reader r;
    uint8_t status;
    uint8_t cap_count;
    uint16_t length;
    const uint8_t *text;
    unsigned i;
    uint64_t required_codec;
    uint64_t required_pixel;

    if (!client || !message || !config || message->type != VTR_MSG_HELLO_ACK)
        return -EPROTO;
    r.data = message->payload;
    r.size = message->payload_size;
    r.pos = 0;
    if (reader_u8(&r, &status) < 0) return -EPROTO;
    if (status != 0) {
        set_error(error, error_size, "VTRemote HELLO rejected with status %u", status);
        return -EACCES;
    }
    if (reader_string(&r, &text, &length) < 0 ||
        reader_string(&r, &text, &length) < 0 ||
        reader_u8(&r, &cap_count) < 0) {
        return -EPROTO;
    }
    client->server_caps = 0;
    for (i = 0; i < cap_count; ++i) {
        if (reader_string(&r, &text, &length) < 0) return -EPROTO;
        client->server_caps |= capability_for(text, length);
    }
    /* Published v1 peers may omit the session counters. */
    if (r.size - r.pos == 4) {
        uint16_t ignored;
        if (reader_u16(&r, &ignored) < 0 || reader_u16(&r, &ignored) < 0)
            return -EPROTO;
    } else if (r.size != r.pos) {
        return -EPROTO;
    }

    required_codec = strcmp(config->codec, "hevc") == 0 ? VTR_CAP_HEVC : VTR_CAP_H264;
    required_pixel = config->pixel_format == VTR_PIXFMT_P010 ? VTR_CAP_P010 : VTR_CAP_NV12;
    if ((client->server_caps & required_codec) == 0) {
        set_error(error, error_size, "server does not advertise %s", config->codec);
        return -ENOTSUP;
    }
    /* Original v1 servers did not advertise pixel-format capabilities.  Only
       enforce these flags when at least one pixel-format flag is present. */
    if ((client->server_caps & (VTR_CAP_NV12 | VTR_CAP_P010)) &&
        !(client->server_caps & required_pixel)) {
        set_error(error, error_size, "server does not advertise requested pixel format");
        return -ENOTSUP;
    }
    return 0;
}

static int parse_configure_ack(VTRClient *client, const VTRMessage *message,
                               VTRPixelFormat expected_pixel_format,
                               char *error, size_t error_size) {
    Reader r;
    uint8_t status;
    uint16_t extradata_size;
    const uint8_t *extradata;
    int rc;
    if (!client || !message || message->type != VTR_MSG_CONFIGURE_ACK)
        return -EPROTO;
    r.data = message->payload;
    r.size = message->payload_size;
    r.pos = 0;
    if (reader_u8(&r, &status) < 0) return -EPROTO;
    if (status != 0) {
        set_error(error, error_size, "VTRemote CONFIGURE rejected with status %u", status);
        return -EINVAL;
    }
    if (reader_u16(&r, &extradata_size) < 0 || r.size - r.pos < extradata_size)
        return -EPROTO;
    extradata = r.data + r.pos;
    r.pos += extradata_size;
    rc = store_parameter_sets(client, extradata, extradata_size);
    if (rc < 0) {
        set_error(error, error_size, "invalid %s encoder extradata",
                  client->codec);
        return rc;
    }
    /* Published v1 peers may omit the reported format and warning list. */
    if (r.pos == r.size) return 0;
    {
        uint8_t reported_pixel_format;
        uint8_t warning_count;
        unsigned i;
        const uint8_t *ignored;
        uint16_t ignored_length;
        if (reader_u8(&r, &reported_pixel_format) < 0 ||
            reported_pixel_format != (uint8_t)expected_pixel_format ||
            reader_u8(&r, &warning_count) < 0) return -EPROTO;
        for (i = 0; i < warning_count; ++i) {
            if (reader_string(&r, &ignored, &ignored_length) < 0) return -EPROTO;
        }
    }
    if (r.pos != r.size) return -EPROTO;
    return 0;
}

static void error_from_remote(const VTRMessage *message, char *error, size_t error_size) {
    Reader r;
    uint32_t code;
    const uint8_t *text;
    uint16_t length;
    size_t n;
    if (!error || error_size == 0) return;
    if (!message || !message->payload_size) {
        set_error(error, error_size, "remote server returned ERROR");
        return;
    }
    r.data = message->payload;
    r.size = message->payload_size;
    r.pos = 0;
    if (r.size < 4) {
        set_error(error, error_size, "remote server returned malformed ERROR");
        return;
    }
    code = read_be32(r.data);
    r.pos = 4;
    if (reader_string(&r, &text, &length) < 0) {
        set_error(error, error_size, "remote error code=%u", code);
        return;
    }
    if (r.pos != r.size) {
        set_error(error, error_size, "remote error code=%u had malformed payload", code);
        return;
    }
    n = length < error_size - 1 ? length : error_size - 1;
    memcpy(error, text, n);
    error[n] = '\0';
}

void vtr_client_init(VTRClient *client) {
    if (!client) return;
    memset(client, 0, sizeof(*client));
    client->fd = -1;
    vtr_buffer_init(&client->tx);
    vtr_buffer_init(&client->rx);
    vtr_buffer_init(&client->parameter_sets);
}

void vtr_client_destroy(VTRClient *client) {
    if (!client) return;
    if (client->fd >= 0) close(client->fd);
    client->fd = -1;
    client->connected = 0;
    vtr_buffer_free(&client->tx);
    vtr_buffer_free(&client->rx);
    vtr_buffer_free(&client->parameter_sets);
}

int vtr_client_connect(VTRClient *client, const VTRClientConfig *config,
                       char *error, size_t error_size) {
    VTRMessage message;
    VTRKeyValue options[10];
    char bit_rate[32], max_rate[32], gop[32], bframes[32], profile[32], realtime[8];
    char global_quality[8], wire_compression[8], constant_bit_rate[8];
    int rc;

    if (!client || !config || !config->endpoint || !config->codec ||
        !config->width || !config->height) return -EINVAL;
    if (client->fd >= 0) vtr_client_destroy(client);
    vtr_client_init(client);
    client->timeout_ms = config->timeout_ms > 0 ? config->timeout_ms : 10000;
    snprintf(client->endpoint, sizeof(client->endpoint), "%s", config->endpoint);
    snprintf(client->codec, sizeof(client->codec), "%s", config->codec);
    client->wire_compression = resolve_wire_compression(config);
    if (client->wire_compression < VTR_WIRE_COMPRESSION_NONE ||
        client->wire_compression > VTR_WIRE_COMPRESSION_ZSTD) {
        set_error(error, error_size, "invalid wire compression mode");
        return -EINVAL;
    }

    client->fd = socket_connect_timeout(config->endpoint, client->timeout_ms,
                                        error, error_size);
    if (client->fd < 0) return client->fd;

    rc = vtr_build_hello(&client->tx, config->token ? config->token : "",
                         config->codec, "vtremote-vaapi", VTREMOTE_VERSION);
    if (rc < 0 || (rc = send_message(client, VTR_MSG_HELLO, client->tx.data,
                                     client->tx.size)) < 0 ||
        (rc = receive_message(client, &message)) < 0) {
        set_error(error, error_size, "HELLO transport failed: %s", strerror(-rc));
        goto fail;
    }
    if (message.type == VTR_MSG_ERROR) {
        error_from_remote(&message, error, error_size);
        rc = -EIO;
        goto fail;
    }
    if ((rc = parse_hello_ack(client, &message, config, error, error_size)) < 0)
        goto fail;

    snprintf(bit_rate, sizeof(bit_rate), "%u", config->bit_rate);
    snprintf(max_rate, sizeof(max_rate), "%u", config->max_rate ? config->max_rate : config->bit_rate);
    snprintf(gop, sizeof(gop), "%u", config->gop_size ? config->gop_size : 60);
    snprintf(bframes, sizeof(bframes), "%u", config->max_b_frames);
    snprintf(profile, sizeof(profile), "%d", config->profile);
    snprintf(global_quality, sizeof(global_quality), "%u", config->global_quality);
    snprintf(realtime, sizeof(realtime), "%d", config->realtime ? 1 : 0);
    snprintf(wire_compression, sizeof(wire_compression), "%d",
             (int)client->wire_compression);
    snprintf(constant_bit_rate, sizeof(constant_bit_rate), "%d",
             config->constant_bit_rate ? 1 : 0);
    options[0] = (VTRKeyValue){"mode", "encode"};
    options[1] = (VTRKeyValue){"bitrate", bit_rate};
    options[2] = (VTRKeyValue){"maxrate", max_rate};
    options[3] = (VTRKeyValue){"gop", gop};
    options[4] = (VTRKeyValue){"max_b_frames", bframes};
    options[5] = (VTRKeyValue){"profile", profile};
    options[6] = (VTRKeyValue){"realtime", realtime};
    options[7] = (VTRKeyValue){"wire_compression", wire_compression};
    options[8] = (VTRKeyValue){"constant_bit_rate", constant_bit_rate};
    options[9] = (VTRKeyValue){"global_quality", global_quality};

    rc = vtr_build_configure(&client->tx, config->width, config->height,
                             config->pixel_format,
                             config->frame_rate_den ? config->frame_rate_den : 1,
                             config->frame_rate_num ? config->frame_rate_num : 30,
                             config->frame_rate_num ? config->frame_rate_num : 30,
                             config->frame_rate_den ? config->frame_rate_den : 1,
                             options, sizeof(options) / sizeof(options[0]));
    if (rc < 0 || (rc = send_message(client, VTR_MSG_CONFIGURE, client->tx.data,
                                     client->tx.size)) < 0 ||
        (rc = receive_message(client, &message)) < 0) {
        set_error(error, error_size, "CONFIGURE transport failed: %s", strerror(-rc));
        goto fail;
    }
    if (message.type == VTR_MSG_ERROR) {
        error_from_remote(&message, error, error_size);
        rc = -EIO;
        goto fail;
    }
    if ((rc = parse_configure_ack(client, &message, config->pixel_format,
                                  error, error_size)) < 0) goto fail;
    client->connected = 1;
    return 0;

fail:
    vtr_client_destroy(client);
    vtr_client_init(client);
    return rc;
}

int vtr_client_encode(VTRClient *client, const VTRFrame *frame,
                      VTRBuffer *packet, int64_t *packet_pts,
                      int64_t *packet_dts, uint32_t *packet_flags,
                      char *error, size_t error_size) {
    VTRMessage message;
    VTRPacketView view;
    int rc;
    if (!client || !client->connected || !frame || !packet) return -EINVAL;
    if ((rc = vtr_build_frame(&client->tx, frame,
                              client->wire_compression)) < 0 ||
        (rc = send_message(client, VTR_MSG_FRAME, client->tx.data,
                           client->tx.size)) < 0) {
        set_error(error, error_size, "FRAME send failed: %s", strerror(-rc));
        return rc;
    }
    for (;;) {
        if ((rc = receive_message(client, &message)) < 0) {
            set_error(error, error_size, "PACKET receive failed: %s", strerror(-rc));
            return rc;
        }
        if (message.type == VTR_MSG_PING) {
            rc = send_message(client, VTR_MSG_PONG, message.payload, message.payload_size);
            if (rc < 0) return rc;
            continue;
        }
        if (message.type == VTR_MSG_ERROR) {
            error_from_remote(&message, error, error_size);
            return -EIO;
        }
        if (message.type != VTR_MSG_PACKET) {
            set_error(error, error_size, "expected PACKET, received %s",
                      vtr_message_type_name(message.type));
            return -EPROTO;
        }
        break;
    }
    if ((rc = vtr_parse_packet(message.payload, message.payload_size, &view)) < 0) {
        set_error(error, error_size, "invalid PACKET payload");
        return rc;
    }
    vtr_buffer_reset(packet);
    if ((view.flags & 1U) != 0 && client->parameter_sets.size != 0) {
        unsigned flags = 0;
        unsigned required = strcmp(client->codec, "hevc") == 0 ? 7U : 3U;
        parameter_set_flags(view.data, view.data_size, client->codec, &flags);
        if ((flags & required) != required &&
            (rc = vtr_put_bytes(packet, client->parameter_sets.data,
                                client->parameter_sets.size)) < 0) {
            return rc;
        }
    }
    if ((rc = vtr_put_bytes(packet, view.data, view.data_size)) < 0) return rc;
    if (packet_pts) *packet_pts = view.pts;
    if (packet_dts) *packet_dts = view.dts;
    if (packet_flags) *packet_flags = view.flags;
    return 0;
}

int vtr_client_flush(VTRClient *client, char *error, size_t error_size) {
    VTRMessage message;
    int rc;
    if (!client || client->fd < 0) return 0;
    if ((rc = send_message(client, VTR_MSG_FLUSH, NULL, 0)) < 0) {
        set_error(error, error_size, "FLUSH send failed: %s", strerror(-rc));
        return rc;
    }
    for (;;) {
        if ((rc = receive_message(client, &message)) < 0) {
            set_error(error, error_size, "FLUSH receive failed: %s", strerror(-rc));
            return rc;
        }
        if (message.type == VTR_MSG_DONE) return 0;
        if (message.type == VTR_MSG_PING) {
            rc = send_message(client, VTR_MSG_PONG, message.payload, message.payload_size);
            if (rc < 0) return rc;
            continue;
        }
        if (message.type == VTR_MSG_PACKET) continue; /* delayed packet; v1 discards at teardown */
        if (message.type == VTR_MSG_ERROR) {
            error_from_remote(&message, error, error_size);
            return -EIO;
        }
    }
}
