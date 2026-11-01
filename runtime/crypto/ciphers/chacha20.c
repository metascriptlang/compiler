/*
 * MetaScript ChaCha20-Poly1305 Runtime — Monocypher wrapper
 */

#include "runtime/crypto/ciphers/chacha20.h"
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
	if (raw.len != 32 || !raw.p) return 0;
	msChachaKey *key = (msChachaKey *)calloc(1, sizeof(msChachaKey));
	if (key == NULL) return 0;
	memcpy(key->bytes, raw.p->data, 32);
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

int64_t msChacha20SealInto(int64_t keyHandle, msString plainText, msString aad, uint8_t *out) {
	const msChachaKey *key = (const msChachaKey *)(uintptr_t)keyHandle;
	if (key == NULL) return 0;

	if (ms_random_fill(out, NONCE_SIZE) != 0) return 0;

	size_t pt_len = plainText.p ? (size_t)plainText.len : 0;

	/* Layout: nonce(24) || cipherText || mac(16) */
	crypto_aead_lock(
		out + NONCE_SIZE,                /* cipher_text */
		out + NONCE_SIZE + pt_len,       /* mac */
		key->bytes,                      /* key */
		out,                             /* nonce */
		aad.p ? (const uint8_t *)aad.p->data : NULL, aad.p ? (size_t)aad.len : 0,
		plainText.p ? (const uint8_t *)plainText.p->data : NULL, pt_len);
	return 1;
}

int64_t msChacha20OpenInto(int64_t keyHandle, msString sealed, msString aad, uint8_t *out) {
	const msChachaKey *key = (const msChachaKey *)(uintptr_t)keyHandle;
	if (key == NULL) return 0;
	if (!sealed.p || sealed.len < NONCE_SIZE + MAC_SIZE) return 0;

	const uint8_t *data = (const uint8_t *)sealed.p->data;
	size_t ct_len = (size_t)sealed.len - NONCE_SIZE - MAC_SIZE;

	int r = crypto_aead_unlock(
		out,                             /* plain_text */
		data + NONCE_SIZE + ct_len,      /* mac */
		key->bytes,                      /* key */
		data,                            /* nonce */
		aad.p ? (const uint8_t *)aad.p->data : NULL, aad.p ? (size_t)aad.len : 0,
		data + NONCE_SIZE, ct_len);
	return r == 0 ? 1 : 0;
}
