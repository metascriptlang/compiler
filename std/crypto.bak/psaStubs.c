/**
 * PSA-to-mbedTLS error conversion stubs.
 * Required by md.c in mbedTLS 4.0 when not linking the full PSA crypto layer.
 * These stubs return generic errors — sufficient for Phase 1 (hash/HMAC only).
 */
#include <stdint.h>
#include <stddef.h>

int psa_generic_status_to_mbedtls(int32_t s) {
    (void)s;
    return -1;
}

int psa_status_to_mbedtls(int32_t s, void* t, size_t n, int (*h)(int32_t)) {
    (void)s; (void)t; (void)n; (void)h;
    return -1;
}

const int psa_to_md_errors[] = {0};
