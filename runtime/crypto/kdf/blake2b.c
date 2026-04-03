/*
 * MetaScript BLAKE2b Runtime — Monocypher wrapper
 */

#include "runtime/crypto/kdf/blake2b.h"
#include "vendor/monocypher/src/monocypher.h"

#include <stdlib.h>
#include <string.h>

/* ===== One-shot API ===== */

msString msBlake2b(msString data, int32_t hashSize) {
	if (hashSize < 1 || hashSize > 64) hashSize = 32;

	uint8_t hash[64];
	crypto_blake2b(hash, (size_t)hashSize,
		data.p ? (const uint8_t *)data.p->data : (const uint8_t *)"",
		data.len);

	return msStringNew((const char *)hash, (int64_t)hashSize);
}

msString msBlake2bKeyed(msString key, msString data, int32_t hashSize) {
	if (hashSize < 1 || hashSize > 64) hashSize = 32;
	if (key.len < 1 || key.len > 64 || !key.p) return MS_EMPTY_STRING;

	uint8_t hash[64];
	crypto_blake2b_keyed(hash, (size_t)hashSize,
		(const uint8_t *)key.p->data, key.len,
		data.p ? (const uint8_t *)data.p->data : (const uint8_t *)"",
		data.len);

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
	if (hashSize < 1 || hashSize > 64) hashSize = 32;

	msBlake2bCtx *c = (msBlake2bCtx *)calloc(1, sizeof(msBlake2bCtx));
	if (!c) return 0;

	c->hash_size = (size_t)hashSize;
	crypto_blake2b_init(&c->ctx, c->hash_size);
	return B2B_TO_HANDLE(c);
}

void msBlake2bUpdate(int64_t handle, msString data) {
	msBlake2bCtx *c = B2B_FROM_HANDLE(handle);
	if (!c) return;
	if (data.p && data.len > 0) {
		crypto_blake2b_update(&c->ctx,
			(const uint8_t *)data.p->data, data.len);
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
