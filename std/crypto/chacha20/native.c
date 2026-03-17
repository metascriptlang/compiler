/*
 * MetaScript ChaCha20-Poly1305 Runtime — Monocypher wrapper
 */

#include "std/crypto/chacha20/native.h"
#include "vendor/monocypher/src/monocypher.h"

#include <stdlib.h>
#include <string.h>

#include "std/crypto/random_fill.h"

#define NONCE_SIZE 24
#define MAC_SIZE   16

msString msChacha20Seal(msString key, msString plainText, msString aad) {
	if (key.len != 32 || !key.p) return MS_EMPTY_STRING;

	uint8_t nonce[NONCE_SIZE];
	if (ms_random_fill(nonce, NONCE_SIZE) != 0) return MS_EMPTY_STRING;

	size_t pt_len = plainText.p ? (size_t)plainText.len : 0;
	size_t out_len = NONCE_SIZE + pt_len + MAC_SIZE;

	uint8_t *out = (uint8_t *)malloc(out_len);
	if (!out) return MS_EMPTY_STRING;

	/* Layout: nonce(24) || cipherText || mac(16) */
	memcpy(out, nonce, NONCE_SIZE);

	crypto_aead_lock(
		out + NONCE_SIZE,                /* cipher_text */
		out + NONCE_SIZE + pt_len,       /* mac */
		(const uint8_t *)key.p->data,    /* key */
		nonce,                           /* nonce */
		aad.p ? (const uint8_t *)aad.p->data : NULL, aad.p ? (size_t)aad.len : 0,
		plainText.p ? (const uint8_t *)plainText.p->data : NULL, pt_len);

	msString result = msStringNew((const char *)out, (int64_t)out_len);
	free(out);
	return result;
}

msString msChacha20Open(msString key, msString sealed, msString aad) {
	if (key.len != 32 || !key.p) return MS_EMPTY_STRING;
	if (!sealed.p || sealed.len < NONCE_SIZE + MAC_SIZE) return MS_EMPTY_STRING;

	const uint8_t *data = (const uint8_t *)sealed.p->data;
	const uint8_t *nonce = data;
	size_t ct_len = (size_t)sealed.len - NONCE_SIZE - MAC_SIZE;
	const uint8_t *ct = data + NONCE_SIZE;
	const uint8_t *mac = data + NONCE_SIZE + ct_len;

	uint8_t *pt = (uint8_t *)malloc(ct_len > 0 ? ct_len : 1);
	if (!pt) return MS_EMPTY_STRING;

	int r = crypto_aead_unlock(
		pt,                              /* plain_text */
		mac,                             /* mac */
		(const uint8_t *)key.p->data,    /* key */
		nonce,                           /* nonce */
		aad.p ? (const uint8_t *)aad.p->data : NULL, aad.p ? (size_t)aad.len : 0,
		ct, ct_len);

	if (r != 0) {
		free(pt);
		return MS_EMPTY_STRING;
	}

	msString result = msStringNew((const char *)pt, (int64_t)ct_len);
	free(pt);
	return result;
}
