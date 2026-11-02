/*
 * MetaScript ChaCha20-Poly1305 Runtime — Monocypher wrapper
 */

#include "runtime/crypto/ciphers/chacha20.h"
#include "runtime/crypto/ciphers/chacha20Simd.h"
#include "runtime/crypto/ciphers/poly1305x64.h"
#include "vendor/monocypher/src/monocypher.h"

#include <stdlib.h>
#include <string.h>

#include "runtime/crypto/randomFill.h"

#define NONCE_SIZE 24
#define MAC_SIZE   16

/* One key's 32 bytes, owned by a std/crypto/chacha20 ChaChaKey; the handle given to MetaScript is its address. */
typedef struct {
	uint8_t bytes[32];
} msChachaKey;

static int64_t liveKeys = 0;

int64_t msChacha20KeyNew(msString raw) {
	if (msStrLen(raw) != 32) return 0;
	msChachaKey *key = (msChachaKey *)calloc(1, sizeof(msChachaKey));
	if (key == NULL) return 0;
	memcpy(key->bytes, msStrData(&raw), 32);
	__atomic_add_fetch(&liveKeys, 1, __ATOMIC_RELAXED);
	return (int64_t)(uintptr_t)key;
}

int64_t msChacha20KeyGenerate(void) {
	msChachaKey *key = (msChachaKey *)calloc(1, sizeof(msChachaKey));
	if (key == NULL) return 0;
	if (ms_random_fill(key->bytes, 32) != 0) {
		crypto_wipe(key, sizeof(msChachaKey));
		free(key);
		return -1;
	}
	__atomic_add_fetch(&liveKeys, 1, __ATOMIC_RELAXED);
	return (int64_t)(uintptr_t)key;
}

msString msChacha20KeyExport(int64_t handle) {
	const msChachaKey *key = (const msChachaKey *)(uintptr_t)handle;
	if (key == NULL) return MS_EMPTY_STRING;
	return msStringNew((const char *)key->bytes, 32);
}

void msChacha20KeyFree(int64_t handle) {
	msChachaKey *key = (msChachaKey *)(uintptr_t)handle;
	if (key == NULL) return;
	crypto_wipe(key, sizeof(msChachaKey));
	free(key);
	__atomic_sub_fetch(&liveKeys, 1, __ATOMIC_RELAXED);
}

int64_t msChacha20KeysLive(void) {
	return __atomic_load_n(&liveKeys, __ATOMIC_RELAXED);
}

/* ChaCha20 xor from block counter ctr: four blocks at a time where the target has them, Monocypher for the rest. */
static void chachaXor(uint8_t *out, const uint8_t *in, size_t n, const uint8_t key[32], const uint8_t nonce[8], uint64_t ctr) {
	size_t done = 0;
#ifdef MS_CHACHA20_SIMD
	done = msChacha20SimdXor(out, in, n, key, nonce, &ctr);
#endif
	if (n > done) crypto_chacha20_djb(out + done, in + done, n - done, key, nonce, ctr);
}

static void aeadTag(uint8_t mac[16], const uint8_t authKey[32], const uint8_t *ad, size_t adLen, const uint8_t *cipherText, size_t textLen) {
#ifdef MS_POLY1305_X64
	msPoly1305Aead(mac, authKey, ad, adLen, cipherText, textLen);
#else
	static const uint8_t zeros[16] = {0};
	uint8_t sizes[16];
	for (int i = 0; i < 8; i++) {
		sizes[i] = (uint8_t)((uint64_t)adLen >> (8 * i));
		sizes[8 + i] = (uint8_t)((uint64_t)textLen >> (8 * i));
	}
	crypto_poly1305_ctx ctx;
	crypto_poly1305_init(&ctx, authKey);
	crypto_poly1305_update(&ctx, ad, adLen);
	crypto_poly1305_update(&ctx, zeros, (16 - (adLen & 15)) & 15);
	crypto_poly1305_update(&ctx, cipherText, textLen);
	crypto_poly1305_update(&ctx, zeros, (16 - (textLen & 15)) & 15);
	crypto_poly1305_update(&ctx, sizes, 16);
	crypto_poly1305_final(&ctx, mac);
#endif
}

/* XChaCha20-Poly1305 as Monocypher's crypto_aead_lock: HChaCha20 subkey, block 0 keys Poly1305, text from block 1. */
static void aeadLock(uint8_t *cipherText, uint8_t mac[16], const uint8_t key[32], const uint8_t nonce[24], const uint8_t *ad, size_t adLen, const uint8_t *plainText, size_t textLen) {
	uint8_t subKey[32], authKey[64];
	crypto_chacha20_h(subKey, key, nonce);
	crypto_chacha20_djb(authKey, NULL, 64, subKey, nonce + 16, 0);
	chachaXor(cipherText, plainText, textLen, subKey, nonce + 16, 1);
	aeadTag(mac, authKey, ad, adLen, cipherText, textLen);
	crypto_wipe(subKey, sizeof subKey);
	crypto_wipe(authKey, sizeof authKey);
}

/* Returns 0 when the tag matches, and writes plainText only then. */
static int aeadUnlock(uint8_t *plainText, const uint8_t mac[16], const uint8_t key[32], const uint8_t nonce[24], const uint8_t *ad, size_t adLen, const uint8_t *cipherText, size_t textLen) {
	uint8_t subKey[32], authKey[64], realMac[16];
	crypto_chacha20_h(subKey, key, nonce);
	crypto_chacha20_djb(authKey, NULL, 64, subKey, nonce + 16, 0);
	aeadTag(realMac, authKey, ad, adLen, cipherText, textLen);
	int mismatch = crypto_verify16(mac, realMac);
	if (!mismatch) chachaXor(plainText, cipherText, textLen, subKey, nonce + 16, 1);
	crypto_wipe(subKey, sizeof subKey);
	crypto_wipe(authKey, sizeof authKey);
	crypto_wipe(realMac, sizeof realMac);
	return mismatch;
}

int64_t msChacha20SealInto(int64_t keyHandle, const uint8_t *plainText, int64_t plainTextLen,
		const uint8_t *aad, int64_t aadLen, uint8_t *out) {
	const msChachaKey *key = (const msChachaKey *)(uintptr_t)keyHandle;
	if (key == NULL) return 0;

	if (ms_random_fill(out, NONCE_SIZE) != 0) return 0;

	size_t pt_len = plainTextLen > 0 ? (size_t)plainTextLen : 0;

	/* Layout: nonce(24) || cipherText || mac(16) */
	aeadLock(
		out + NONCE_SIZE,                /* cipher_text */
		out + NONCE_SIZE + pt_len,       /* mac */
		key->bytes,                      /* key */
		out,                             /* nonce */
		aadLen > 0 ? aad : NULL, aadLen > 0 ? (size_t)aadLen : 0,
		pt_len ? plainText : NULL, pt_len);
	return 1;
}

int64_t msChacha20OpenInto(int64_t keyHandle, const uint8_t *sealed, int64_t sealedLen,
		const uint8_t *aad, int64_t aadLen, uint8_t *out) {
	const msChachaKey *key = (const msChachaKey *)(uintptr_t)keyHandle;
	if (key == NULL) return 0;
	if (sealedLen < NONCE_SIZE + MAC_SIZE) return 0;

	const uint8_t *data = sealed;
	size_t ct_len = (size_t)sealedLen - NONCE_SIZE - MAC_SIZE;

	int r = aeadUnlock(
		out,                             /* plain_text */
		data + NONCE_SIZE + ct_len,      /* mac */
		key->bytes,                      /* key */
		data,                            /* nonce */
		aadLen > 0 ? aad : NULL, aadLen > 0 ? (size_t)aadLen : 0,
		data + NONCE_SIZE, ct_len);
	return r == 0 ? 1 : 0;
}
