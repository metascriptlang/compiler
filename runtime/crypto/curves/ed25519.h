/*
 * MetaScript Ed25519 Runtime — Monocypher wrapper
 *
 * EdDSA signatures on Edwards25519 curve. A key is an opaque handle to a native block that the
 * owning class frees with msEd25519KeyFree (it wipes the block first). Signatures are 64 bytes and
 * deterministic.
 */

#ifndef MS_CRYPTO_ED25519_H
#define MS_CRYPTO_ED25519_H

#include "runtime/core/string.h"
#include <stdint.h>

/* Private keys. A handle is 0 on failure. The public half is derived from the seed once, here. */
int64_t msEd25519KeyGenerate(void);
int64_t msEd25519KeyFromSeed(const uint8_t* seed, int64_t seedLen);
msString msEd25519KeySeed(int64_t key);
msString msEd25519KeyPublicRaw(int64_t key);
msString msEd25519KeySign(int64_t key, const uint8_t* message, int64_t messageLen);

/* Public keys: 32 raw bytes. Verify is strict. */
int64_t msEd25519PublicFromRaw(const uint8_t* raw, int64_t rawLen);
msString msEd25519PublicRaw(int64_t key);
int32_t msEd25519PublicVerify(int64_t key, const uint8_t* signature, int64_t signatureLen, const uint8_t* message, int64_t messageLen);

/* Wipes and frees a private or public key. */
void msEd25519KeyFree(int64_t key);

#endif /* MS_CRYPTO_ED25519_H */
