/*
 * MetaScript X25519 Runtime — Monocypher wrapper
 */

#include "std/crypto/x25519/native.h"
#include "vendor/monocypher/src/monocypher.h"

#include <stdlib.h>
#include <string.h>

#include "std/crypto/random_fill.h"

msString msX25519Generate(void) {
	uint8_t sk[32];
	if (ms_random_fill(sk, 32) != 0) return MS_EMPTY_STRING;

	msString result = msStringNew((const char *)sk, 32);
	crypto_wipe(sk, 32);
	return result;
}

msString msX25519PublicKey(msString secretKey) {
	if (secretKey.len != 32 || !secretKey.p) return MS_EMPTY_STRING;

	uint8_t pk[32];
	crypto_x25519_public_key(pk, (const uint8_t *)secretKey.p->data);

	return msStringNew((const char *)pk, 32);
}

msString msX25519SharedSecret(msString secretKey, msString publicKey) {
	if (secretKey.len != 32 || !secretKey.p) return MS_EMPTY_STRING;
	if (publicKey.len != 32 || !publicKey.p) return MS_EMPTY_STRING;

	uint8_t shared[32];
	crypto_x25519(shared,
		(const uint8_t *)secretKey.p->data,
		(const uint8_t *)publicKey.p->data);

	msString result = msStringNew((const char *)shared, 32);
	crypto_wipe(shared, 32);
	return result;
}
