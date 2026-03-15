/* PSA stubs — mbedTLS 4.x requires these symbols even for legacy MD API */
#include <stdint.h>
#include <stddef.h>
int psa_generic_status_to_mbedtls(int32_t s) { (void)s; return -1; }
int psa_status_to_mbedtls(int32_t s, void* t, size_t n, int (*h)(int32_t)) {
    (void)s; (void)t; (void)n; (void)h; return -1;
}
const int psa_to_md_errors[] = {0};
