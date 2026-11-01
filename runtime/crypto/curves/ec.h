/*
 * MetaScript EC runtime — ECDSA and ECDH on P-256 and P-384
 *
 * Uses mbedTLS 4.x PK API for key operations, PSA API for key generation and agreement.
 * A key is an opaque handle owned by an EcPrivateKey or EcPublicKey class, which frees it.
 */
#ifndef MS_CRYPTO_EC_H
#define MS_CRYPTO_EC_H

#include "runtime/core/string.h"
#include <stdint.h>

typedef struct msCryptoEcKey msCryptoEcKey;

/* Generate an EC key pair. curve: "p256" or "p384". Returns handle (int64) or 0 on error. */
int64_t msCryptoEcGenerate(msString curve);

/* Import from PEM strings; a key that is not P-256 or P-384 is refused. Returns handle or 0. */
int64_t msCryptoEcImportPrivatePem(msString pem);
int64_t msCryptoEcImportPublicPem(msString pem);

/* Export to PEM strings. Returns empty string on error. */
msString msCryptoEcExportPrivatePem(int64_t handle);
msString msCryptoEcExportPublicPem(int64_t handle);

/* A new handle holding only the public half. */
int64_t msCryptoEcPublicOf(int64_t handle);

/* 256 or 384. */
int32_t msCryptoEcBits(int64_t handle);

/* ECDSA sign/verify over the hash of data; signatures are DER. sha1 is refused for signing. */
msString msCryptoEcdsaSign(int64_t handle, msString algorithm, msString data);
double msCryptoEcdsaVerify(int64_t handle, msString algorithm, msString data, msString signature);

/* ECDH: shared secret of a private key and a peer public key; empty on failure (curves differ). */
msString msCryptoEcdhDerive(int64_t privateHandle, int64_t publicHandle);

/* Free a key. */
void msCryptoEcFree(int64_t handle);

#endif /* MS_CRYPTO_EC_H */
