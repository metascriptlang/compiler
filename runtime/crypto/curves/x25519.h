/*
 * MetaScript X25519 Runtime — Monocypher wrapper
 *
 * Elliptic Curve Diffie-Hellman on Curve25519 (RFC 7748).
 * Used by TLS 1.3, WireGuard, Signal Protocol. A key is an opaque handle to a native block that
 * the owning class frees with msX25519KeyFree (it wipes the block first).
 */

#ifndef MS_CRYPTO_X25519_H
#define MS_CRYPTO_X25519_H

#include "runtime/core/string.h"
#include <stdint.h>

/* Private keys. A handle is 0 on failure. The public half is derived once, here. */
int64_t msX25519KeyGenerate(void);
int64_t msX25519KeyFromRaw(msString raw);
msString msX25519KeyPublicRaw(int64_t key);

/* Public keys: 32 raw bytes. */
int64_t msX25519PublicFromRaw(msString raw);
msString msX25519PublicRaw(int64_t key);

/* Shared secret of a private and a public key, or an empty string when it is all zero (a
 * low-order public key, RFC 7748 6.1). */
msString msX25519SharedSecret(int64_t privateKey, int64_t publicKey);

/* Wipes and frees a private or public key. */
void msX25519KeyFree(int64_t key);

#endif /* MS_CRYPTO_X25519_H */
