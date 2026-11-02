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

#include "runtime/core/string.h"
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
int64_t msCryptoHashInto(msString algorithm, msString data, void* output, int64_t capacity);
/* The same over bytes the caller keeps alive for the call; data may be NULL when dataLen is 0. */
int64_t msCryptoHashSpanInto(msString algorithm, const uint8_t* data, int64_t dataLen, void* output, int64_t capacity);

/* ===== HMAC ===== */

/* HMAC of raw data with raw key, return raw bytes as msString buffer.
 * Returns empty string on error. */
msString msCryptoHmacBuffer(msString algorithm, msString key, msString data);
int64_t msCryptoHmacInto(msString algorithm, msString key, msString data, void* output, int64_t capacity);
int64_t msCryptoHmacSpanInto(msString algorithm, const uint8_t* key, int64_t keyLen, const uint8_t* data, int64_t dataLen, void* output, int64_t capacity);

/* ===== Random ===== */

/* Generate cryptographically secure random bytes.
 * Returns empty string on error. */
msString msCryptoRandomBytes(int64_t size);

/* Draw an integer in [min, max) into *out by rejection sampling. Returns 0, or a
 * MS_RANDOM_INT_* code naming why nothing was drawn; the result never shares the
 * status channel. Bounds are safe integers and max - min <= 2^48. */
#define MS_RANDOM_INT_BAD_MIN 1
#define MS_RANDOM_INT_BAD_MAX 2
#define MS_RANDOM_INT_EMPTY_RANGE 3
#define MS_RANDOM_INT_RANGE_TOO_WIDE 4
#define MS_RANDOM_INT_SOURCE_FAILED 5
int32_t msCryptoRandomIntInto(double min, double max, int64_t* out);

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

/* Finalize and get raw hash bytes. Frees context. */
msString msCryptoHashFinalBuffer(msCryptoHashCtx* ctx);
int64_t msCryptoHashFinalInto(msCryptoHashCtx* ctx, void* output, int64_t capacity);

/* Free a hash context without finalizing */
void msCryptoHashFree(msCryptoHashCtx* ctx);

/* ===== Streaming HMAC Context ===== */

/* Opaque HMAC context handle */
typedef struct msCryptoHmacCtx msCryptoHmacCtx;

/* Create streaming HMAC context. Returns NULL on error. */
msCryptoHmacCtx* msCryptoHmacInit(msString algorithm, msString key);

/* Feed data into streaming HMAC */
void msCryptoHmacUpdate(msCryptoHmacCtx* ctx, msString data);

/* Finalize and get raw HMAC bytes. Frees context. */
msString msCryptoHmacFinalBuffer(msCryptoHmacCtx* ctx);
int64_t msCryptoHmacFinalInto(msCryptoHmacCtx* ctx, void* output, int64_t capacity);

/* Free an HMAC context without finalizing */
void msCryptoHmacFree(msCryptoHmacCtx* ctx);

/* ===== Handle Wrappers (int64 ↔ pointer for MetaScript) ===== */
/* Lost during runtime relocation (std/crypto/native.h → runtime/crypto/hash.h) */

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
static inline msString msCryptoHashFinalBufferHandle(int64_t ctx) {
    return msCryptoHashFinalBuffer(HASH_CTX_FROM_HANDLE(ctx));
}
static inline int64_t msCryptoHashFinalIntoHandle(int64_t ctx, void* output, int64_t capacity) {
    return msCryptoHashFinalInto(HASH_CTX_FROM_HANDLE(ctx), output, capacity);
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
static inline msString msCryptoHmacFinalBufferHandle(int64_t ctx) {
    return msCryptoHmacFinalBuffer(HMAC_CTX_FROM_HANDLE(ctx));
}
static inline int64_t msCryptoHmacFinalIntoHandle(int64_t ctx, void* output, int64_t capacity) {
    return msCryptoHmacFinalInto(HMAC_CTX_FROM_HANDLE(ctx), output, capacity);
}
static inline void msCryptoHmacFreeHandle(int64_t ctx) {
    msCryptoHmacFree(HMAC_CTX_FROM_HANDLE(ctx));
}

/* ===== Utility ===== */

/* Check if a hash algorithm is supported. Returns 1/0. */
double msCryptoIsHashSupported(msString algorithm);

/* Digest size in bytes of a supported algorithm, 0 when unsupported. */
double msCryptoHashSize(msString algorithm);

/* ===== Encoding ===== */

msString msCryptoToBase64(msString data);

/* ===== Key Derivation ===== */

/* An empty result means refused: iterations < 1, keyLength outside [1, cap], an unknown digest or an md failure. */
#define MS_PBKDF2_MAX_KEY_LENGTH (1 << 20)
msString msCryptoPbkdf2(msString password, msString salt,
                        int32_t iterations, int32_t keyLength, msString digest);
msString msCryptoHkdf(msString algorithm, msString ikm, msString salt,
                      msString info, int32_t length);

#endif /* MS_CRYPTO_H */
