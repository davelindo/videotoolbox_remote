#pragma once

#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
  LOG_WARNING = 300,
  LOG_INFO = 200,
};

static inline void blog(int level, const char *format, ...) {
  (void)level;
  (void)format;
  va_list args;
  va_start(args, format);
  va_end(args);
}

#ifdef __cplusplus
}
#endif
