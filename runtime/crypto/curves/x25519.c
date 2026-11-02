/*
 * MetaScript X25519 Runtime — Monocypher wrapper
 */

#include "runtime/crypto/curves/x25519.h"
#include "vendor/monocypher/src/monocypher.h"

#include <stdlib.h>
#include <string.h>

#include "runtime/crypto/randomFill.h"

/* A key is one calloc'd 64-byte block: a private key holds the secret scalar then its public key,
 * a public key holds the point in its first 32 bytes. The block is wiped before it is freed. */
#define KEY_BLOCK 64

static uint8_t *blockOf(int64_t handle) {
	return (uint8_t *)(intptr_t)handle;
}

static int64_t newPrivate(const uint8_t sk[32]) {
	uint8_t *block = (uint8_t *)calloc(1, KEY_BLOCK);
	if (!block) return 0;
	memcpy(block, sk, 32);
	crypto_x25519_public_key(block + 32, sk);
	return (int64_t)(intptr_t)block;
}

int64_t msX25519KeyGenerate(void) {
	uint8_t sk[32];
	if (ms_random_fill(sk, 32) != 0) return 0;
	int64_t handle = newPrivate(sk);
	crypto_wipe(sk, 32);
	return handle;
}

int64_t msX25519KeyFromRaw(msString raw) {
	if (msStrLen(raw) != 32) return 0;
	return newPrivate((const uint8_t *)msStrData(&raw));
}

msString msX25519KeyPublicRaw(int64_t key) {
	return msStringNew((const char *)blockOf(key) + 32, 32);
}

int64_t msX25519PublicFromRaw(msString raw) {
	if (msStrLen(raw) != 32) return 0;
	uint8_t *block = (uint8_t *)calloc(1, KEY_BLOCK);
	if (!block) return 0;
	memcpy(block, msStrData(&raw), 32);
	return (int64_t)(intptr_t)block;
}

msString msX25519PublicRaw(int64_t key) {
	return msStringNew((const char *)blockOf(key), 32);
}

msString msX25519SharedSecret(int64_t privateKey, int64_t publicKey) {
	uint8_t shared[32];
	crypto_x25519(shared, blockOf(privateKey), blockOf(publicKey));

	/* RFC 7748 6.1: a low-order public key forces the all-zero output; refuse it.
	 * crypto_verify32 compares in constant time. */
	static const uint8_t zero[32] = {0};
	if (crypto_verify32(shared, zero) == 0) {
		crypto_wipe(shared, 32);
		return MS_EMPTY_STRING;
	}

	msString result = msStringNew((const char *)shared, 32);
	crypto_wipe(shared, 32);
	return result;
}

void msX25519KeyFree(int64_t key) {
	if (!key) return;
	crypto_wipe(blockOf(key), KEY_BLOCK);
	free(blockOf(key));
}
