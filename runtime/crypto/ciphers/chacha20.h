/*
 * MetaScript ChaCha20-Poly1305 Runtime — Monocypher wrapper
 *
 * XChaCha20-Poly1305 AEAD (extended 24-byte nonce, RFC 8439 + xchacha draft).
 * Same pattern as AES-GCM seal/open: nonce auto-generated on encrypt.
 */

#ifndef MS_CRYPTO_CHACHA20_H
#define MS_CRYPTO_CHACHA20_H

#include "runtime/core/string.h"
#include <stdint.h>

/* Encrypt with XChaCha20-Poly1305 into out, which holds 24 + plainText.len + 16 bytes.
 * Auto-generates the 24-byte nonce. Key: 32 bytes.
 * Writes: nonce(24) || cipherText || mac(16). Returns 1, or 0 when the key or nonce is unusable. */
int64_t msChacha20SealInto(msString key, msString plainText, msString aad, uint8_t *out);

/* Decrypt an XChaCha20-Poly1305 sealed blob into out, which holds sealed.len - 40 bytes.
 * Input: nonce(24) || cipherText || mac(16). Returns 1, or 0 when the key, size or mac is wrong. */
int64_t msChacha20OpenInto(msString key, msString sealed, msString aad, uint8_t *out);

#endif /* MS_CRYPTO_CHACHA20_H */
