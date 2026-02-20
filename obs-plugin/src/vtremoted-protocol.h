/*
 * VTRemoted Protocol Definitions
 * Shared between encoder and client
 */

#ifndef VTREMOTED_PROTOCOL_H
#define VTREMOTED_PROTOCOL_H

#include <stdint.h>

#define VTR_MAGIC 0x56545231 /* "VTR1" */
#define VTR_VERSION 1
#define VTR_PORT 5555

/* Message types */
enum vtr_msg_type {
  VTR_MSG_HELLO = 1,
  VTR_MSG_HELLO_ACK = 2,
  VTR_MSG_CONFIGURE = 3,
  VTR_MSG_CONFIGURE_ACK = 4,
  VTR_MSG_FRAME = 5,
  VTR_MSG_PACKET = 6,
  VTR_MSG_FLUSH = 7,
  VTR_MSG_DONE = 8,
  VTR_MSG_ERROR = 9,
  VTR_MSG_PING = 10,
  VTR_MSG_PONG = 11,
};

/* Wire header (12 bytes, big-endian) */
#pragma pack(push, 1)
struct vtr_header {
  uint32_t magic;
  uint16_t version;
  uint16_t type;
  uint32_t length;
};
#pragma pack(pop)

/* Pixel formats */
enum vtr_pix_fmt {
  VTR_PIX_FMT_NV12 = 1,
  VTR_PIX_FMT_P010 = 2,
};

/* Wire compression */
enum vtr_wire_compression {
  VTR_WIRE_NONE = 0,
  VTR_WIRE_LZ4 = 1,
  VTR_WIRE_ZSTD = 2,
};

/* HELLO_ACK status */
enum vtr_status {
  VTR_STATUS_OK = 0,
  VTR_STATUS_BUSY = 1,
  VTR_STATUS_AUTH_FAIL = 2,
};

#endif /* VTREMOTED_PROTOCOL_H */
