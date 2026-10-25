#ifndef LIB_H
#define LIB_H
#include <stdint.h>
int32_t imported(void);
int64_t sumBytes(const uint8_t *bytes, int64_t length);
extern const int32_t libLimit;
#endif
