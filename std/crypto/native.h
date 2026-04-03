/*
 * MetaScript Crypto Runtime — C Header
 *
 * Phase 1: Hashing (SHA-256/384/512, SHA-1, MD5, SHA-3, RIPEMD-160),
 *          HMAC, random bytes/UUID, timing-safe comparison.
 *
 * Uses mbedTLS legacy MD API for portable, secure implementations.
 * All string types are msString (16-byte value handles).
 */

#ifndef MS_CRYPTO_H
#define MS_CRYPTO_H

#include "runtime/system/string.h"
#include <stdint.h>

/* ===== Initialization ===== */

/* Initialize crypto subsystem (idempotent) — returns 1 on success */
double msCryptoInit(void);

/* Cleanup crypto subsystem */
void msCryptoCleanup(void);

/* ===== Hashing ===== */

/* Hash a string, return encoded result (hex or base64).
 * Returns empty string on error. */
msString msCryptoHashString(msString algorithm, msString data, msString encoding);

/* Hash raw binary data, return raw hash bytes as msString buffer.
 * Returns empty string on error. */
msString msCryptoHashBuffer(msString algorithm, msString data);

/* ===== HMAC ===== */

/* HMAC of string data with string key, return encoded result.
 * Returns empty string on error. */
msString msCryptoHmacString(msString algorithm, msString key, msString data, msString encoding);

/* HMAC of raw data with raw key, return raw bytes as msString buffer.
 * Returns empty string on error. */
msString msCryptoHmacBuffer(msString algorithm, msString key, msString data);

/* ===== Random ===== */

/* Generate cryptographically secure random bytes.
 * Returns empty string on error. */
msString msCryptoRandomBytes(int64_t size);

/* Generate random integer in [min, max). Returns -1 on error. */
double msCryptoRandomInt(double min, double max);

/* Generate random UUID v4. Returns empty string on error. */
msString msCryptoRandomUuid(void);

/* ===== Timing-Safe Comparison ===== */

/* Constant-time comparison of two strings. Returns 1 if equal, 0 if not. */
double msCryptoTimingSafeEqual(msString a, msString b);

/* ===== Streaming Hash Context ===== */

/* Opaque hash context handle */
typedef struct msCryptoHashCtx msCryptoHashCtx;

/* Create streaming hash context. Returns NULL on error. */
msCryptoHashCtx* msCryptoHashInit(msString algorithm);

/* Feed data into streaming hash */
void msCryptoHashUpdate(msCryptoHashCtx* ctx, msString data);

/* Finalize and get encoded hash. Frees context. */
msString msCryptoHashFinal(msCryptoHashCtx* ctx, msString encoding);

/* Finalize and get raw hash bytes. Frees context. */
msString msCryptoHashFinalBuffer(msCryptoHashCtx* ctx);

/* Free a hash context without finalizing */
void msCryptoHashFree(msCryptoHashCtx* ctx);

/* ===== Streaming HMAC Context ===== */

/* Opaque HMAC context handle */
typedef struct msCryptoHmacCtx msCryptoHmacCtx;

/* Create streaming HMAC context. Returns NULL on error. */
msCryptoHmacCtx* msCryptoHmacInit(msString algorithm, msString key);

/* Feed data into streaming HMAC */
void msCryptoHmacUpdate(msCryptoHmacCtx* ctx, msString data);

/* Finalize and get encoded HMAC. Frees context. */
msString msCryptoHmacFinal(msCryptoHmacCtx* ctx, msString encoding);

/* Finalize and get raw HMAC bytes. Frees context. */
msString msCryptoHmacFinalBuffer(msCryptoHmacCtx* ctx);

/* Free an HMAC context without finalizing */
void msCryptoHmacFree(msCryptoHmacCtx* ctx);

/* ===== Handle Wrappers (int64 ↔ pointer for MetaScript) ===== */

#define HASH_CTX_TO_HANDLE(p)   ((int64_t)(uintptr_t)(p))
#define HASH_CTX_FROM_HANDLE(h) ((msCryptoHashCtx*)(uintptr_t)(h))
#define HMAC_CTX_TO_HANDLE(p)   ((int64_t)(uintptr_t)(p))
#define HMAC_CTX_FROM_HANDLE(h) ((msCryptoHmacCtx*)(uintptr_t)(h))

static inline int64_t msCryptoHashInitHandle(msString algorithm) {
    return HASH_CTX_TO_HANDLE(msCryptoHashInit(algorithm));
}
static inline void msCryptoHashUpdateHandle(int64_t ctx, msString data) {
    msCryptoHashUpdate(HASH_CTX_FROM_HANDLE(ctx), data);
}
static inline msString msCryptoHashFinalHandle(int64_t ctx, msString encoding) {
    return msCryptoHashFinal(HASH_CTX_FROM_HANDLE(ctx), encoding);
}
static inline msString msCryptoHashFinalBufferHandle(int64_t ctx) {
    return msCryptoHashFinalBuffer(HASH_CTX_FROM_HANDLE(ctx));
}
static inline void msCryptoHashFreeHandle(int64_t ctx) {
    msCryptoHashFree(HASH_CTX_FROM_HANDLE(ctx));
}

static inline int64_t msCryptoHmacInitHandle(msString algorithm, msString key) {
    return HMAC_CTX_TO_HANDLE(msCryptoHmacInit(algorithm, key));
}
static inline void msCryptoHmacUpdateHandle(int64_t ctx, msString data) {
    msCryptoHmacUpdate(HMAC_CTX_FROM_HANDLE(ctx), data);
}
static inline msString msCryptoHmacFinalHandle(int64_t ctx, msString encoding) {
    return msCryptoHmacFinal(HMAC_CTX_FROM_HANDLE(ctx), encoding);
}
static inline msString msCryptoHmacFinalBufferHandle(int64_t ctx) {
    return msCryptoHmacFinalBuffer(HMAC_CTX_FROM_HANDLE(ctx));
}
static inline void msCryptoHmacFreeHandle(int64_t ctx) {
    msCryptoHmacFree(HMAC_CTX_FROM_HANDLE(ctx));
}

/* ===== Utility ===== */

/* Check if a hash algorithm is supported. Returns 1/0. */
double msCryptoIsHashSupported(msString algorithm);

/* ===== Encoding ===== */

msString msCryptoToHex(msString data);
msString msCryptoFromHex(msString hex);
msString msCryptoToBase64(msString data);
msString msCryptoFromBase64(msString b64);

/* ===== Key Derivation ===== */

msString msCryptoPbkdf2(msString password, msString salt,
                        int32_t iterations, int32_t keyLength, msString digest);
msString msCryptoHkdf(msString algorithm, msString ikm, msString salt,
                      msString info, int32_t length);

#endif /* MS_CRYPTO_H */
