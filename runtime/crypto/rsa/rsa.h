/*
 * MetaScript Asymmetric Crypto Runtime — RSA + ECDSA + ECDH
 *
 * Uses mbedTLS 4.x PK API for key operations, PSA API for key generation.
 * Key pairs are opaque handles — managed via create/free lifecycle.
 */
#ifndef MS_CRYPTO_RSA_H
#define MS_CRYPTO_RSA_H

#include "runtime/core/string.h"
#include <stdint.h>

/* Opaque key pair handles */
typedef struct msCryptoRsaKeyPair msCryptoRsaKeyPair;
typedef struct msCryptoEcKeyPair msCryptoEcKeyPair;

/* ===== RSA ===== */

/* Generate RSA key pair (2048/3072/4096 bits). Returns handle (int64) or 0 on error. */
int64_t msCryptoRsaGenerate(int32_t bits);

/* Import from PEM strings. Returns handle (int64) or 0 on error. */
int64_t msCryptoRsaImportPrivatePem(msString pem);
int64_t msCryptoRsaImportPublicPem(msString pem);

/* Export to PEM strings. Returns empty string on error. */
msString msCryptoRsaExportPrivatePem(int64_t handle);
msString msCryptoRsaExportPublicPem(int64_t handle);

/* Sign data with private key. Returns signature bytes. */
msString msCryptoRsaSign(int64_t handle, msString algorithm, msString data);

/* Verify signature with public key. Returns 1 if valid, 0 if not. */
double msCryptoRsaVerify(int64_t handle, msString algorithm, msString data, msString signature);

/* RSA-OAEP encrypt/decrypt. */
msString msCryptoRsaEncrypt(int64_t handle, msString data);
msString msCryptoRsaDecrypt(int64_t handle, msString data);

/* Free key pair. */
void msCryptoRsaFree(int64_t handle);

/* ===== ECDSA ===== */

/* Generate EC key pair. curve: "p256", "p384", "p521", "secp256k1". */
int64_t msCryptoEcGenerate(msString curve);

/* Import from PEM strings. */
int64_t msCryptoEcImportPrivatePem(msString pem);
int64_t msCryptoEcImportPublicPem(msString pem);

/* Export to PEM strings. */
msString msCryptoEcExportPrivatePem(int64_t handle);
msString msCryptoEcExportPublicPem(int64_t handle);

/* ECDSA sign/verify. */
msString msCryptoEcdsaSign(int64_t handle, msString algorithm, msString data);
double msCryptoEcdsaVerify(int64_t handle, msString algorithm, msString data, msString signature);

/* ECDH key agreement — derive shared secret from private + peer public. */
msString msCryptoEcdhDerive(int64_t privateHandle, int64_t publicHandle);

/* Free EC key pair. */
void msCryptoEcFree(int64_t handle);

#endif /* MS_CRYPTO_RSA_H */
