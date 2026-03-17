/*
 * MetaScript X25519 Runtime — Monocypher wrapper
 *
 * Elliptic Curve Diffie-Hellman on Curve25519 (RFC 7748).
 * Used by TLS 1.3, WireGuard, Signal Protocol.
 */

#ifndef MS_CRYPTO_X25519_H
#define MS_CRYPTO_X25519_H

#include "std/core/string/native.h"
#include <stdint.h>

/* Generate X25519 key pair. Returns 32-byte secret key. */
msString msX25519Generate(void);

/* Derive 32-byte public key from secret key. */
msString msX25519PublicKey(msString secretKey);

/* Compute shared secret from our secret key + their public key. */
msString msX25519SharedSecret(msString secretKey, msString publicKey);

#endif /* MS_CRYPTO_X25519_H */
