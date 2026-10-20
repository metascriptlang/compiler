#include "mbedtls/platform.h"
#include "mbedtls/platform_time.h"
#include <stdint.h>

static inline int32_t wasiEntropyChecks(void) {
    unsigned char bytes[16] = {0};
    size_t estimate = 99;
    int status = mbedtls_platform_get_entropy(0, &estimate, bytes, sizeof(bytes));
    if (status != 0 || estimate != 128) return 0;
    for (size_t i = 0; i < sizeof(bytes); ++i) {
        if (bytes[i] != 42) return 0;
    }
    status = mbedtls_platform_get_entropy(0, &estimate, bytes, sizeof(bytes));
    if (status != PSA_ERROR_INSUFFICIENT_ENTROPY || estimate != 0) return 0;
    estimate = 99;
    status = mbedtls_platform_get_entropy(1, &estimate, bytes, sizeof(bytes));
    if (status != PSA_ERROR_NOT_SUPPORTED || estimate != 0) return 0;
    estimate = 99;
    status = mbedtls_platform_get_entropy(0, &estimate, bytes, SIZE_MAX);
    if (status != PSA_ERROR_INSUFFICIENT_ENTROPY || estimate != 0) return 0;
    return 1;
}

static inline int64_t wasiClockMilliseconds(void) {
    return mbedtls_ms_time();
}
