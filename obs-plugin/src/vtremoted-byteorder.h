/*
 * Byte-order helpers for vtremoted wire fields.
 */

#ifndef VTREMOTED_BYTEORDER_H
#define VTREMOTED_BYTEORDER_H

#include <stdint.h>

static inline uint16_t vtr_read_be16(const uint8_t *p) {
  return (uint16_t)((uint16_t)p[0] << 8 | p[1]);
}

static inline uint32_t vtr_read_be32(const uint8_t *p) {
  return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 |
         (uint32_t)p[2] << 8 | p[3];
}

static inline int64_t vtr_read_be64(const uint8_t *p) {
  uint64_t v = (uint64_t)p[0] << 56 | (uint64_t)p[1] << 48 |
               (uint64_t)p[2] << 40 | (uint64_t)p[3] << 32 |
               (uint64_t)p[4] << 24 | (uint64_t)p[5] << 16 |
               (uint64_t)p[6] << 8 | p[7];
  if (v <= (uint64_t)INT64_MAX)
    return (int64_t)v;
  if (v == ((uint64_t)1 << 63))
    return INT64_MIN;
  return -(int64_t)((~v) + 1);
}

#endif /* VTREMOTED_BYTEORDER_H */
