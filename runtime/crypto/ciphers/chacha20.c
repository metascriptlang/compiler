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

int64_t msChacha20SealInto(msString key, msString plainText, msString aad, uint8_t *out) {
	if (key.len != 32 || !key.p) return 0;

	if (ms_random_fill(out, NONCE_SIZE) != 0) return 0;

	size_t pt_len = plainText.p ? (size_t)plainText.len : 0;

	/* Layout: nonce(24) || cipherText || mac(16) */
	crypto_aead_lock(
		out + NONCE_SIZE,                /* cipher_text */
		out + NONCE_SIZE + pt_len,       /* mac */
		(const uint8_t *)key.p->data,    /* key */
		out,                             /* nonce */
		aad.p ? (const uint8_t *)aad.p->data : NULL, aad.p ? (size_t)aad.len : 0,
		plainText.p ? (const uint8_t *)plainText.p->data : NULL, pt_len);
	return 1;
}

int64_t msChacha20OpenInto(msString key, msString sealed, msString aad, uint8_t *out) {
	if (key.len != 32 || !key.p) return 0;
	if (!sealed.p || sealed.len < NONCE_SIZE + MAC_SIZE) return 0;

	const uint8_t *data = (const uint8_t *)sealed.p->data;
	size_t ct_len = (size_t)sealed.len - NONCE_SIZE - MAC_SIZE;

	int r = crypto_aead_unlock(
		out,                             /* plain_text */
		data + NONCE_SIZE + ct_len,      /* mac */
		(const uint8_t *)key.p->data,    /* key */
		data,                            /* nonce */
		aad.p ? (const uint8_t *)aad.p->data : NULL, aad.p ? (size_t)aad.len : 0,
		data + NONCE_SIZE, ct_len);
	return r == 0 ? 1 : 0;
}
