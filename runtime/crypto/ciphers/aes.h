/*
 * MetaScript AES Runtime — AES-GCM and AES-CBC
 *
 * AES-GCM: authenticated encryption (AEAD) — safe default
 * AES-CBC: legacy mode (requires separate authentication)
 *
 * GCM implemented manually using AES-ECB + GHASH (no mbedTLS GCM module needed).
 * Only requires mbedTLS aes.c + platform_util.c.
 */
#ifndef MS_CRYPTO_AES_H
#define MS_CRYPTO_AES_H

#include "runtime/core/string.h"
#include <stdint.h>

/* ===== High-Level AEAD (seal/open) ===== */

/* Seal: AES-GCM encrypt with auto-generated 12-byte nonce.
 * Output: nonce(12) || cipherText || authTag(16)
 * Key: 16 bytes (AES-128) or 32 bytes (AES-256).
 * aad: additional authenticated data (can be empty). */
msString msCryptoAesSeal(msString key, msString plainText, msString aad);

/* Open: AES-GCM decrypt from sealed blob.
 * Input: nonce(12) || cipherText || authTag(16)
 * Returns 1 and stores the plaintext in *plainTextOut when the tag verifies,
 * 0 on auth failure or error (an empty plaintext is a valid success). */
int64_t msCryptoAesOpen(msString key, msString sealed, msString aad, msString* plainTextOut);

/* ===== CBC Mode (expert use) ===== */

/* CBC encrypt with PKCS7 padding. IV must be 16 bytes. */
msString msCryptoAesCbcEncrypt(msString key, msString plainText, msString iv);

/* CBC decrypt with PKCS7 unpadding. IV must be 16 bytes. */
msString msCryptoAesCbcDecrypt(msString key, msString cipherText, msString iv);

#endif /* MS_CRYPTO_AES_H */
