#ifndef MS_MBEDTLS_WASI_CONFIG_H
#define MS_MBEDTLS_WASI_CONFIG_H

/* The default platform sources require Unix or Windows APIs, not WASI. */
#if defined(__wasi__)
#undef MBEDTLS_PSA_BUILTIN_GET_ENTROPY
#define MBEDTLS_PSA_DRIVER_GET_ENTROPY
#define MBEDTLS_PLATFORM_MS_TIME_ALT
#endif

#endif
