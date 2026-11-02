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

/* A key object's native state: 32 raw bytes, wiped when freed. New returns 0 for a length other than
 * 32; Generate returns -1 when the OS random source failed. Export copies the bytes out.
 * KeysLive counts keys created and not yet freed. */
int64_t msChacha20KeyNew(msString raw);
int64_t msChacha20KeyGenerate(void);
msString msChacha20KeyExport(int64_t handle);
void msChacha20KeyFree(int64_t handle);
int64_t msChacha20KeysLive(void);

/* Encrypt with XChaCha20-Poly1305 into out, which holds 24 + plainText.len + 16 bytes.
 * Auto-generates the 24-byte nonce. Key: 32 bytes.
 * Writes: nonce(24) || cipherText || mac(16). Returns 1, or 0 when the key or nonce is unusable. */
int64_t msChacha20SealInto(int64_t keyHandle, const uint8_t *plainText, int64_t plainTextLen,
		const uint8_t *aad, int64_t aadLen, uint8_t *out);

/* Decrypt an XChaCha20-Poly1305 sealed blob into out, which holds sealed.len - 40 bytes.
 * Input: nonce(24) || cipherText || mac(16). Returns 1, or 0 when the key, size or mac is wrong. */
int64_t msChacha20OpenInto(int64_t keyHandle, const uint8_t *sealed, int64_t sealedLen,
		const uint8_t *aad, int64_t aadLen, uint8_t *out);

#endif /* MS_CRYPTO_CHACHA20_H */
