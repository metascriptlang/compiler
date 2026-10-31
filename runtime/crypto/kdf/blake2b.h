/*
 * MetaScript BLAKE2b Runtime — Monocypher wrapper
 *
 * BLAKE2b: fast cryptographic hash (faster than SHA-256, RFC 7693).
 * Supports keyed hashing (MAC) and variable output length (1-64 bytes).
 */

#ifndef MS_CRYPTO_BLAKE2B_H
#define MS_CRYPTO_BLAKE2B_H

#include "runtime/core/string.h"
#include <stdint.h>

/* Hash data with BLAKE2b. hashSize: output bytes (1-64); another size returns the empty string. */
msString msBlake2b(msString data, int32_t hashSize);

/* Keyed BLAKE2b (MAC). key: 1-64 bytes. A bad hashSize or key returns the empty string. */
msString msBlake2bKeyed(msString key, msString data, int32_t hashSize);

/* Streaming BLAKE2b — opaque handle pattern. Init returns 0 for a hashSize outside 1-64. */
int64_t  msBlake2bInit(int32_t hashSize);
void     msBlake2bUpdate(int64_t ctx, msString data);
msString msBlake2bFinal(int64_t ctx);

#endif /* MS_CRYPTO_BLAKE2B_H */
