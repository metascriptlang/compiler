/*
 * MetaScript AES Runtime — AES-GCM and AES-CBC
 *
 * AES-GCM: authenticated encryption (AEAD) — safe default
 * AES-CBC: legacy mode (requires separate authentication)
 *
 * Both run on the vendored mbedTLS (aes.c, gcm.c).
 */
#ifndef MS_CRYPTO_AES_H
#define MS_CRYPTO_AES_H

#include "runtime/core/string.h"
#include <stdint.h>

/* ===== High-Level AEAD (seal/open) ===== */

/* Seal: AES-GCM encrypt with auto-generated 12-byte nonce.
 * Writes nonce(12) || cipherText || authTag(16) into out, which holds 12 + plainText.len + 16 bytes.
 * Key: 16 bytes (AES-128) or 32 bytes (AES-256).
 * aad: additional authenticated data (can be empty).
 * Returns 1, 0 on a bad key or a cipher failure, -1 when the OS random source failed. */
int64_t msCryptoAesSealInto(msString key, msString plainText, msString aad, uint8_t* out);

/* Seal with a caller-chosen 12-byte nonce, for tests that need a reproducible blob; std/crypto/aes
 * never exposes it, because a repeated nonce under one key breaks GCM. Same layout and returns
 * as msCryptoAesSealInto, 0 also for a nonce that is not 12 bytes. */
int64_t msCryptoAesSealWithNonceInto(msString key, msString nonce, msString plainText, msString aad, uint8_t* out);

/* Open: AES-GCM decrypt from sealed blob nonce(12) || cipherText || authTag(16).
 * out holds sealed.len - 28 bytes. Returns 1 when the tag verifies and out holds the plaintext
 * (an empty plaintext is a valid success), 0 on error, with out zeroed after an auth failure. */
int64_t msCryptoAesOpenInto(msString key, msString sealed, msString aad, uint8_t* out);

/* ===== CBC Mode (expert use) ===== */

/* CBC encrypt with PKCS7 padding. IV must be 16 bytes. Never empty on success. */
msString msCryptoAesCbcEncrypt(msString key, msString plainText, msString iv);

/* CBC decrypt with PKCS7 unpadding, no authentication. IV must be 16 bytes.
 * Returns 1 and stores the plaintext in *plainTextOut (possibly empty), 0 on a bad padding or input. */
int64_t msCryptoAesCbcDecrypt(msString key, msString cipherText, msString iv, msString* plainTextOut);

#endif /* MS_CRYPTO_AES_H */
