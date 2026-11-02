/*
 * Poly1305 over 64-bit limbs for the ChaCha20-Poly1305 AEAD construction.
 */

#ifndef MS_CRYPTO_POLY1305X64_H
#define MS_CRYPTO_POLY1305X64_H

#include <stddef.h>
#include <stdint.h>

#ifdef __SIZEOF_INT128__
#define MS_POLY1305_X64 1

/* The AEAD tag: Poly1305 under authKey (32 bytes) over ad, zero pad to 16, cipherText, zero pad to 16,
 * then both lengths as 64-bit little-endian. The same bytes as Monocypher's lock_auth. */
void msPoly1305Aead(uint8_t mac[16], const uint8_t authKey[32], const uint8_t *ad, size_t adLen,
                    const uint8_t *cipherText, size_t textLen);
#endif

#endif /* MS_CRYPTO_POLY1305X64_H */
