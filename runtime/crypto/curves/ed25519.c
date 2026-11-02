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

/* A key is one calloc'd 64-byte block: a private key holds the Monocypher secret key (seed || A)
 * and a public key holds A in its first 32 bytes. The block is wiped before it is freed. */
#define KEY_BLOCK 64

static int64_t newBlock(const uint8_t *bytes, size_t len) {
	uint8_t *block = (uint8_t *)calloc(1, KEY_BLOCK);
	if (!block) return 0;
	memcpy(block, bytes, len);
	return (int64_t)(intptr_t)block;
}

static uint8_t *blockOf(int64_t handle) {
	return (uint8_t *)(intptr_t)handle;
}

static int64_t keyFromSeedBytes(const uint8_t seed[32]) {
	uint8_t sk[64];
	uint8_t pk[32];
	uint8_t seedCopy[32];
	memcpy(seedCopy, seed, 32);
	crypto_ed25519_key_pair(sk, pk, seedCopy);
	crypto_wipe(seedCopy, 32);
	int64_t handle = newBlock(sk, 64);
	crypto_wipe(sk, 64);
	return handle;
}

int64_t msEd25519KeyGenerate(void) {
	uint8_t seed[32];
	if (ms_random_fill(seed, 32) != 0) return 0;
	int64_t handle = keyFromSeedBytes(seed);
	crypto_wipe(seed, 32);
	return handle;
}

int64_t msEd25519KeyFromSeed(msString seed) {
	if (msStrLen(seed) != 32) return 0;
	return keyFromSeedBytes((const uint8_t *)msStrData(&seed));
}

msString msEd25519KeySeed(int64_t key) {
	return msStringNew((const char *)blockOf(key), 32);
}

msString msEd25519KeyPublicRaw(int64_t key) {
	return msStringNew((const char *)blockOf(key) + 32, 32);
}

int64_t msEd25519PublicFromRaw(msString raw) {
	if (msStrLen(raw) != 32) return 0;
	return newBlock((const uint8_t *)msStrData(&raw), 32);
}

msString msEd25519PublicRaw(int64_t key) {
	return msStringNew((const char *)blockOf(key), 32);
}

void msEd25519KeyFree(int64_t key) {
	if (!key) return;
	crypto_wipe(blockOf(key), KEY_BLOCK);
	free(blockOf(key));
}

/* RFC 8032 5.1.6 signs from the seed and derives A itself, and an A taken from the caller lets two
 * signatures share R with different S, which reveals the private scalar. The block's A was derived
 * from its seed at construction and no API takes one from the caller, so sign never derives it again. */
msString msEd25519KeySign(int64_t key, msString message) {
	uint8_t sig[64];
	crypto_ed25519_sign(sig, blockOf(key),
		(const uint8_t *)msStrData(&message),
		msStrLen(message));
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
int32_t msEd25519PublicVerify(int64_t key, msString signature, msString message) {
	if (msStrLen(signature) != 64) return 0;
	const uint8_t *publicKey = blockOf(key);
	if (isSmallOrderPoint(publicKey)) return 0;
	if (isSmallOrderPoint((const uint8_t *)msStrData(&signature))) return 0;

	int r = crypto_ed25519_check(
		(const uint8_t *)msStrData(&signature),
		publicKey,
		(const uint8_t *)msStrData(&message),
		msStrLen(message));

	return r == 0 ? 1 : 0;
}
