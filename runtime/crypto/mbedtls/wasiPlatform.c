#if defined(__wasi__)
#include "mbedtls/platform.h"
#include "mbedtls/platform_time.h"
#include <stdint.h>
#include <stdlib.h>
#include <wasi/api.h>

mbedtls_ms_time_t mbedtls_ms_time(void) {
    __wasi_timestamp_t now;
    /* This API has no error result; stop rather than inventing a timestamp. */
    if (__wasi_clock_time_get(__WASI_CLOCKID_MONOTONIC, 1000000, &now) != 0) {
        abort();
    }
    return (mbedtls_ms_time_t)(now / 1000000);
}

int mbedtls_platform_get_entropy(psa_driver_get_entropy_flags_t flags,
                                size_t *estimate_bits,
                                unsigned char *output, size_t output_size) {
    *estimate_bits = 0;
    if (flags != 0) return PSA_ERROR_NOT_SUPPORTED;
    if (output_size > SIZE_MAX / 8) return PSA_ERROR_INSUFFICIENT_ENTROPY;
    if (__wasi_random_get(output, output_size) != 0) {
        return PSA_ERROR_INSUFFICIENT_ENTROPY;
    }
    *estimate_bits = output_size * 8;
    return 0;
}
#endif
