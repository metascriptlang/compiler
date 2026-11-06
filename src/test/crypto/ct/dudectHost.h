#ifndef MS_CT_DUDECT_HOST_H
#define MS_CT_DUDECT_HOST_H
#include <stdint.h>

int32_t msCtDudectRun(uint8_t *fixed, int64_t length, int64_t measurements, int64_t batches, uint64_t seed, int32_t null);

#endif
