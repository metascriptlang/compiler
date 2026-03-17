/*
 * MetaScript Ed25519 Runtime — Monocypher Ed25519 wrapper
 *
 * Uses Monocypher's crypto_ed25519_* (SHA-512 based, RFC 8032 compatible).
 * RNG via arc4random_buf (macOS/BSD) or getrandom (Linux).
 */

#include "std/crypto/ed25519/native.h"
#include "vendor/monocypher/src/optional/monocypher-ed25519.h"

#include <stdlib.h>
#include <string.h>

#include "std/crypto/random_fill.h"

/* ===== Public API ===== */

msString msEd25519Generate(void) {
	uint8_t seed[32];
	if (ms_random_fill(seed, 32) != 0) return MS_EMPTY_STRING;

	uint8_t sk[64];
	uint8_t pk[32];
	crypto_ed25519_key_pair(sk, pk, seed);

	/* Wipe seed from stack */
	crypto_wipe(seed, 32);

	msString result = msStringNew((const char *)sk, 64);
	crypto_wipe(sk, 64);
	return result;
}

msString msEd25519PublicKey(msString secretKey) {
	if (secretKey.len != 64 || !secretKey.p) return MS_EMPTY_STRING;

	/* Public key is the last 32 bytes of the 64-byte secret key */
	return msStringNew((const char *)secretKey.p->data + 32, 32);
}

msString msEd25519Sign(msString secretKey, msString message) {
	if (secretKey.len != 64 || !secretKey.p) return MS_EMPTY_STRING;

	uint8_t sig[64];
	crypto_ed25519_sign(sig,
		(const uint8_t *)secretKey.p->data,
		message.p ? (const uint8_t *)message.p->data : (const uint8_t *)"",
		message.len);

	return msStringNew((const char *)sig, 64);
}

int32_t msEd25519Verify(msString signature, msString publicKey, msString message) {
	if (signature.len != 64 || !signature.p) return 0;
	if (publicKey.len != 32 || !publicKey.p) return 0;

	int r = crypto_ed25519_check(
		(const uint8_t *)signature.p->data,
		(const uint8_t *)publicKey.p->data,
		message.p ? (const uint8_t *)message.p->data : (const uint8_t *)"",
		message.len);

	return r == 0 ? 1 : 0;
}

msString msEd25519FromSeed(msString seed) {
	if (seed.len != 32 || !seed.p) return MS_EMPTY_STRING;

	uint8_t sk[64];
	uint8_t pk[32];
	uint8_t seedCopy[32];
	memcpy(seedCopy, seed.p->data, 32);
	crypto_ed25519_key_pair(sk, pk, seedCopy);
	crypto_wipe(seedCopy, 32);

	msString result = msStringNew((const char *)sk, 64);
	crypto_wipe(sk, 64);
	return result;
}

msString msEd25519ToSeed(msString secretKey) {
	if (secretKey.len != 64 || !secretKey.p) return MS_EMPTY_STRING;

	/* First 32 bytes of the 64-byte secret key is the seed */
	return msStringNew((const char *)secretKey.p->data, 32);
}
