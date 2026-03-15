/* Minimal mbedTLS config — hash algorithms only */
#ifndef MBEDTLS_CONFIG_H
#define MBEDTLS_CONFIG_H
#define MBEDTLS_MD_C
#define MBEDTLS_SHA256_C
#define MBEDTLS_SHA512_C
#define MBEDTLS_SHA1_C
#define MBEDTLS_SHA3_C
#define MBEDTLS_MD5_C
#define MBEDTLS_RIPEMD160_C
#define MBEDTLS_PLATFORM_C
#define MBEDTLS_PLATFORM_MEMORY
#include "mbedtls/check_config.h"
#endif
