/*
 * MetaScript RSA runtime — PKCS#1 v1.5 and PSS signatures, OAEP encryption
 *
 * Uses mbedTLS 4.x PK API for key operations, PSA API for key generation.
 * A key is an opaque handle owned by an RsaPrivateKey or RsaPublicKey class, which frees it.
 */
#ifndef MS_CRYPTO_RSA_H
#define MS_CRYPTO_RSA_H

#include "runtime/core/string.h"
#include <stdint.h>

typedef struct msCryptoRsaKeyPair msCryptoRsaKeyPair;

/* Generate RSA key pair (2048/3072/4096 bits). Returns handle (int64) or 0 on error. */
int64_t msCryptoRsaGenerate(int32_t bits);

/* Import from PEM strings (a key under 2048 bits is refused). Returns handle (int64) or 0 on error. */
int64_t msCryptoRsaImportPrivatePem(msString pem);
int64_t msCryptoRsaImportPublicPem(msString pem);

/* Export to PEM strings. Returns empty string on error. */
msString msCryptoRsaExportPrivatePem(int64_t handle);
msString msCryptoRsaExportPublicPem(int64_t handle);

/* A new handle holding only the public half. */
int64_t msCryptoRsaPublicOf(int64_t handle);

/* Sign data with private key; pss is 1 for PSS and 0 for PKCS#1 v1.5. sha1 is refused. */
msString msCryptoRsaSign(int64_t handle, msString algorithm, int32_t pss, msString data);

/* Verify signature with public key. Returns 1 if valid, 0 if not. */
double msCryptoRsaVerify(int64_t handle, msString algorithm, int32_t pss, msString data, msString signature);

/* RSA-OAEP (SHA-256) encrypt/decrypt. */
msString msCryptoRsaEncrypt(int64_t handle, msString data);
msString msCryptoRsaDecrypt(int64_t handle, msString data);

/* Free a key. */
void msCryptoRsaFree(int64_t handle);

#endif /* MS_CRYPTO_RSA_H */
