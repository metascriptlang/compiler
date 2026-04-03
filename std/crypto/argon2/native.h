/*
 * MetaScript Argon2 Runtime — Password Hashing
 *
 * Wraps the PHC winner Argon2 reference implementation.
 * Supports Argon2i (side-channel resistant), Argon2d (GPU resistant),
 * and Argon2id (hybrid, recommended default).
 */
#ifndef MS_CRYPTO_ARGON2_H
#define MS_CRYPTO_ARGON2_H

#include "runtime/system/string.h"
#include <stdint.h>

/* Hash a password with Argon2id (recommended).
 * Returns encoded hash string ($argon2id$...) or empty on error.
 * timeCost: number of iterations (3 recommended)
 * memoryCost: memory in KiB (65536 = 64MB recommended)
 * parallelism: number of threads (4 recommended)
 * hashLen: output hash length in bytes (32 recommended) */
msString msCryptoArgon2Hash(msString password, msString salt,
                            int32_t timeCost, int32_t memoryCost,
                            int32_t parallelism, int32_t hashLen);

/* Verify a password against an encoded Argon2 hash.
 * Returns 1.0 if match, 0.0 if not. */
double msCryptoArgon2Verify(msString encoded, msString password);

/* Hash with raw output (binary, not encoded). */
msString msCryptoArgon2HashRaw(msString password, msString salt,
                               int32_t timeCost, int32_t memoryCost,
                               int32_t parallelism, int32_t hashLen);

#endif /* MS_CRYPTO_ARGON2_H */
