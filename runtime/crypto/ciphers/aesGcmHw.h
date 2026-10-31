/*
 * MetaScript AES-GCM hardware path (Arm AES + PMULL, x86-64 AES-NI + PCLMULQDQ).
 */
#ifndef MS_CRYPTO_AES_GCM_HW_H
#define MS_CRYPTO_AES_GCM_HW_H

#include "mbedtls/private/aes.h"
#include <stddef.h>
#include <stdint.h>

/* Runs GCM with a 12-byte iv over an encryption key schedule built by mbedtls_aes_setkey_enc.
 * Writes len bytes to out (not aliasing in) and the tag over the cipher text to tag: encrypts
 * when decrypt is 0, otherwise decrypts and leaves comparing the tag to the caller.
 * The caller refuses lengths past the SP 800-38D limits first. Returns 0 without touching out when this CPU or build has no hardware path. */
int msAesGcmHw(const mbedtls_aes_context* aes, const uint8_t iv[12], const uint8_t* aad, size_t aadLen,
	const uint8_t* in, size_t len, uint8_t* out, uint8_t tag[16], int decrypt);

#endif /* MS_CRYPTO_AES_GCM_HW_H */
