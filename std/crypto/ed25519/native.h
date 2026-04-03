/*
 * MetaScript Ed25519 Runtime — Monocypher wrapper
 *
 * EdDSA signatures on Edwards25519 curve.
 * Key pair: 32-byte seed → 64-byte secret key + 32-byte public key.
 * Signature: 64 bytes, deterministic (no random nonce needed).
 */

#ifndef MS_CRYPTO_ED25519_H
#define MS_CRYPTO_ED25519_H

#include "runtime/system/string.h"
#include <stdint.h>

/* Generate Ed25519 key pair from random seed.
 * Returns 64-byte secret key as binary string, or empty on failure.
 * Public key is derived from secret key via ed25519PublicKey(). */
msString msEd25519Generate(void);

/* Extract 32-byte public key from 64-byte secret key. */
msString msEd25519PublicKey(msString secretKey);

/* Sign message with secret key. Returns 64-byte signature. */
msString msEd25519Sign(msString secretKey, msString message);

/* Verify signature against public key and message. */
int32_t msEd25519Verify(msString signature, msString publicKey, msString message);

/* Import secret key from 32-byte seed (expand to 64-byte internal format). */
msString msEd25519FromSeed(msString seed);

/* Export 32-byte seed from 64-byte secret key (first 32 bytes). */
msString msEd25519ToSeed(msString secretKey);

#endif /* MS_CRYPTO_ED25519_H */
