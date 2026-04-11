/* MetaScript mbedTLS config — hash + crypto + TLS */
#ifndef MBEDTLS_CONFIG_H
#define MBEDTLS_CONFIG_H

/* Platform */
#define MBEDTLS_PLATFORM_C
#ifndef MBEDTLS_PLATFORM_MEMORY
#define MBEDTLS_PLATFORM_MEMORY
#endif
#define MBEDTLS_PLATFORM_STD_CALLOC calloc
#define MBEDTLS_PLATFORM_STD_FREE   free
#define MBEDTLS_HAVE_TIME

/* Hash algorithms */
#define MBEDTLS_MD_C
#define MBEDTLS_SHA256_C
#define MBEDTLS_SHA512_C
#define MBEDTLS_SHA1_C
#define MBEDTLS_SHA3_C
#define MBEDTLS_MD5_C
#define MBEDTLS_RIPEMD160_C

/* Symmetric encryption */
#define MBEDTLS_AES_C
#define MBEDTLS_GCM_C
#define MBEDTLS_CIPHER_C
#define MBEDTLS_CCM_C

/* Public key */
#define MBEDTLS_PK_C
#define MBEDTLS_PK_PARSE_C
#define MBEDTLS_PK_WRITE_C
#define MBEDTLS_RSA_C
#define MBEDTLS_ECDSA_C
#define MBEDTLS_ECDH_C
#define MBEDTLS_ECP_C
#define MBEDTLS_BIGNUM_C
#define MBEDTLS_ASN1_PARSE_C
#define MBEDTLS_ASN1_WRITE_C
#define MBEDTLS_OID_C
#define MBEDTLS_PEM_PARSE_C
#define MBEDTLS_PEM_WRITE_C
#define MBEDTLS_BASE64_C

/* Elliptic curves (for ECDHE key exchange) */
#define MBEDTLS_ECP_DP_SECP256R1_ENABLED
#define MBEDTLS_ECP_DP_SECP384R1_ENABLED
#define MBEDTLS_ECP_DP_SECP521R1_ENABLED
#define MBEDTLS_ECP_DP_CURVE25519_ENABLED

/* RNG */
#define MBEDTLS_CTR_DRBG_C
#define MBEDTLS_ENTROPY_C

/* X.509 certificates */
#define MBEDTLS_X509_USE_C
#define MBEDTLS_X509_CRT_PARSE_C
#define MBEDTLS_X509_CRL_PARSE_C
/* DO NOT REMOVE — required for TLS 1.3 handshake with RSA server certs.
 *
 * Upstream bug: https://github.com/Mbed-TLS/mbedtls/issues/10641
 *   "Stop misusing MBEDTLS_X509_RSASSA_PSS_SUPPORT in TLS code" (mpg, 2026-03-16)
 * Upstream fix: https://github.com/Mbed-TLS/mbedtls/pull/10591 (not in 4.0.x yet)
 *
 * mbedTLS 4.0.0's TLS 1.3 code gates `rsa_pss_rsae_sha256/384/512` in
 * `ssl_tls13_default_sig_algs` behind this macro, even though the macro
 * nominally controls X.509 cert chain parsing. Without it, the ClientHello
 * `signature_algorithms` extension omits RSA-PSS, and any server with an
 * RSA certificate (e.g. AWS CloudFront, api.metascriptlang.org) sends
 * `handshake_failure(40)` → mbedTLS returns MBEDTLS_ERR_SSL_HANDSHAKE_FAILURE
 * (-0x6E00). ECDSA servers (e.g. github.com) are unaffected.
 *
 * When upstream PR #10591 lands in a mbedTLS release we vendor, this define
 * can be removed — RSA-PSS will be keyed off PSA_WANT_ALG_RSA_PSS instead. */
#define MBEDTLS_X509_RSASSA_PSS_SUPPORT

/* SSL/TLS */
#define MBEDTLS_SSL_TLS_C
#define MBEDTLS_SSL_CLI_C
#define MBEDTLS_SSL_PROTO_TLS1_2
#define MBEDTLS_SSL_PROTO_TLS1_3
#define MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_EPHEMERAL_ENABLED
#define MBEDTLS_SSL_KEEP_PEER_CERTIFICATE

/* Key exchange */
#define MBEDTLS_KEY_EXCHANGE_ECDHE_RSA_ENABLED
#define MBEDTLS_KEY_EXCHANGE_ECDHE_ECDSA_ENABLED
#define MBEDTLS_KEY_EXCHANGE_RSA_ENABLED

/* TLS extensions */
#define MBEDTLS_SSL_SERVER_NAME_INDICATION
#define MBEDTLS_SSL_ALPN

/* File I/O for loading CA certs */
#define MBEDTLS_FS_IO

/* check_config.h requires include path — validated at compile time */
#endif
