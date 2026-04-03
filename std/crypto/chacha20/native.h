/*
 * MetaScript ChaCha20-Poly1305 Runtime — Monocypher wrapper
 *
 * XChaCha20-Poly1305 AEAD (extended 24-byte nonce, RFC 8439 + xchacha draft).
 * Same pattern as AES-GCM seal/open: nonce auto-generated on encrypt.
 */

#ifndef MS_CRYPTO_CHACHA20_H
#define MS_CRYPTO_CHACHA20_H

#include "runtime/system/string.h"
#include <stdint.h>

/* Encrypt with XChaCha20-Poly1305.
 * Auto-generates 24-byte nonce. Key: 32 bytes.
 * Returns: nonce(24) || cipherText || mac(16). */
msString msChacha20Seal(msString key, msString plainText, msString aad);

/* Decrypt XChaCha20-Poly1305 sealed blob.
 * Input: nonce(24) || cipherText || mac(16). */
msString msChacha20Open(msString key, msString sealed, msString aad);

#endif /* MS_CRYPTO_CHACHA20_H */
