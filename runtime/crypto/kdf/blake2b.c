/*
 * MetaScript BLAKE2b Runtime — Monocypher wrapper
 */

#include "runtime/crypto/kdf/blake2b.h"
#include "vendor/monocypher/src/monocypher.h"

#include <stdlib.h>
#include <string.h>

/* ===== One-shot API ===== */

msString msBlake2b(msString data, int32_t hashSize) {
	if (hashSize < 1 || hashSize > 64) return MS_EMPTY_STRING;

	uint8_t hash[64];
	crypto_blake2b(hash, (size_t)hashSize,
		(const uint8_t *)msStrData(&data),
		msStrLen(data));

	return msStringNew((const char *)hash, (int64_t)hashSize);
}

msString msBlake2bKeyed(msString key, msString data, int32_t hashSize) {
	if (hashSize < 1 || hashSize > 64) return MS_EMPTY_STRING;
	if (msStrLen(key) < 1 || msStrLen(key) > 64) return MS_EMPTY_STRING;

	uint8_t hash[64];
	crypto_blake2b_keyed(hash, (size_t)hashSize,
		(const uint8_t *)msStrData(&key), msStrLen(key),
		(const uint8_t *)msStrData(&data),
		msStrLen(data));

	return msStringNew((const char *)hash, (int64_t)hashSize);
}

/* ===== Streaming API ===== */

typedef struct {
	crypto_blake2b_ctx ctx;
	size_t hash_size;
} msBlake2bCtx;

#define B2B_TO_HANDLE(p)   ((int64_t)(uintptr_t)(p))
#define B2B_FROM_HANDLE(h) ((msBlake2bCtx*)(uintptr_t)(h))

int64_t msBlake2bInit(int32_t hashSize) {
	if (hashSize < 1 || hashSize > 64) return 0;

	msBlake2bCtx *c = (msBlake2bCtx *)msMemAlloc0(sizeof(msBlake2bCtx));

	c->hash_size = (size_t)hashSize;
	crypto_blake2b_init(&c->ctx, c->hash_size);
	return B2B_TO_HANDLE(c);
}

void msBlake2bUpdate(int64_t handle, msString data) {
	msBlake2bCtx *c = B2B_FROM_HANDLE(handle);
	if (!c) return;
	if (msStrLen(data) > 0) {
		crypto_blake2b_update(&c->ctx,
			(const uint8_t *)msStrData(&data), msStrLen(data));
	}
}

msString msBlake2bFinal(int64_t handle) {
	msBlake2bCtx *c = B2B_FROM_HANDLE(handle);
	if (!c) return MS_EMPTY_STRING;

	uint8_t hash[64];
	crypto_blake2b_final(&c->ctx, hash);
	msString result = msStringNew((const char *)hash, (int64_t)c->hash_size);

	crypto_wipe(c, sizeof(msBlake2bCtx));
	free(c);
	return result;
}
