/*
 * MetaScript Ed25519 Runtime — Monocypher Ed25519 wrapper
 *
 * Uses Monocypher's crypto_ed25519_* (SHA-512 based, RFC 8032 compatible).
 * RNG via arc4random_buf (macOS/BSD) or getrandom (Linux).
 */

#include "runtime/crypto/curves/ed25519.h"
#include "vendor/monocypher/src/optional/monocypher-ed25519.h"

#include <stdlib.h>
#include <string.h>

#include "runtime/crypto/randomFill.h"

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

	uint8_t sk[64];
	uint8_t pk[32];
	uint8_t seed[32];
	memcpy(seed, secretKey.p->data, 32);
	crypto_ed25519_key_pair(sk, pk, seed);
	crypto_wipe(seed, 32);
	crypto_wipe(sk, 64);
	return msStringNew((const char *)pk, 32);
}

msString msEd25519Sign(msString secretKey, msString message) {
	if (secretKey.len != 64 || !secretKey.p) return MS_EMPTY_STRING;

	/* RFC 8032 5.1.6 signs from the seed alone and derives A itself; the stored
	 * public half is never trusted, because a wrong A gives two signatures with
	 * the same R and different S, which reveal the private scalar. */
	uint8_t sk[64];
	uint8_t pk[32];
	uint8_t seed[32];
	memcpy(seed, secretKey.p->data, 32);
	crypto_ed25519_key_pair(sk, pk, seed);
	crypto_wipe(seed, 32);

	uint8_t sig[64];
	crypto_ed25519_sign(sig, sk,
		message.p ? (const uint8_t *)message.p->data : (const uint8_t *)"",
		message.len);
	crypto_wipe(sk, 64);

	return msStringNew((const char *)sig, 64);
}

/* Encodings of the eight small-order points, with the sign bit cleared, plus the
 * non-canonical aliases (y = p, p + 1) that Monocypher's decoder accepts. */
static int isSmallOrderPoint(const uint8_t enc[32]) {
	static const uint8_t ys[7][32] = {
		{0x00},
		{0x01},
		{0xec, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
		 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f},
		{0xed, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
		 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f},
		{0xee, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
		 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f},
		{0xc7, 0x17, 0x6a, 0x70, 0x3d, 0x4d, 0xd8, 0x4f, 0xba, 0x3c, 0x0b, 0x76, 0x0d, 0x10, 0x67, 0x0f,
		 0x2a, 0x20, 0x53, 0xfa, 0x2c, 0x39, 0xcc, 0xc6, 0x4e, 0xc7, 0xfd, 0x77, 0x92, 0xac, 0x03, 0x7a},
		{0x26, 0xe8, 0x95, 0x8f, 0xc2, 0xb2, 0x27, 0xb0, 0x45, 0xc3, 0xf4, 0x89, 0xf2, 0xef, 0x98, 0xf0,
		 0xd5, 0xdf, 0xac, 0x05, 0xd3, 0xc6, 0x33, 0x39, 0xb1, 0x38, 0x02, 0x88, 0x6d, 0x53, 0xfc, 0x05},
	};
	uint8_t y[32];
	memcpy(y, enc, 32);
	y[31] &= 0x7f;
	for (int i = 0; i < 7; i++) {
		if (memcmp(y, ys[i], 32) == 0) return 1;
	}
	return 0;
}

/* Strict verify: RFC 8032 5.1.7 (Monocypher's check also enforces S < L) plus a
 * refusal of small-order A or R, which Monocypher documents it allows and which
 * lets an identity key accept every message. */
int32_t msEd25519Verify(msString signature, msString publicKey, msString message) {
	if (signature.len != 64 || !signature.p) return 0;
	if (publicKey.len != 32 || !publicKey.p) return 0;
	if (isSmallOrderPoint((const uint8_t *)publicKey.p->data)) return 0;
	if (isSmallOrderPoint((const uint8_t *)signature.p->data)) return 0;

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
