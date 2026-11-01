/*
 * MetaScript RSA — PKCS#1 v1.5 and PSS signatures, OAEP encryption
 *
 * Ported from reference ~/projects/metascript/std/crypto/crypto.c
 * Adapted: ms_crypto_* → msCrypto*, msBool → double, msOptionalString → msString
 */

#include "runtime/crypto/rsa/rsa.h"
#include "runtime/crypto/rsa/pkCommon.h"
#include <stdlib.h>

#define RSA_TO_HANDLE(p) ((int64_t)(intptr_t)(p))
#define RSA_FROM_HANDLE(h) ((msCryptoRsaKeyPair*)(intptr_t)(h))

struct msCryptoRsaKeyPair {
	mbedtls_pk_context pk;
};

#define RSA_MIN_BITS 2048

static int64_t keyToHandle(msCryptoRsaKeyPair* kp) {
	return RSA_TO_HANDLE(kp);
}

static int64_t discard(msCryptoRsaKeyPair* kp) {
	mbedtls_pk_free(&kp->pk);
	free(kp);
	return 0;
}

static int64_t implRsaGenerate(int32_t bits) {
	/* The key is exported once into the PK context and destroyed at once, so it needs the export usage;
	 * the PK context is what the handle keeps. */
	psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
	psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_EXPORT);
	psa_set_key_algorithm(&attributes, PSA_ALG_RSA_PKCS1V15_SIGN(PSA_ALG_ANY_HASH));
	psa_set_key_type(&attributes, PSA_KEY_TYPE_RSA_KEY_PAIR);
	psa_set_key_bits(&attributes, (size_t)bits);
	mbedtls_svc_key_id_t keyId;
	if (psa_generate_key(&attributes, &keyId) != PSA_SUCCESS) return 0;
	msCryptoRsaKeyPair* kp = (msCryptoRsaKeyPair*)msMemAlloc0(sizeof(msCryptoRsaKeyPair));
	mbedtls_pk_init(&kp->pk);
	int ret = mbedtls_pk_copy_from_psa(keyId, &kp->pk);
	psa_destroy_key(keyId);
	return ret != 0 ? discard(kp) : keyToHandle(kp);
}

static int rebuildWithPublicHalf(mbedtls_pk_context* pk) {
	psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
	mbedtls_svc_key_id_t keyId;
	int ret = mbedtls_pk_get_psa_attributes(pk, PSA_KEY_USAGE_SIGN_HASH, &attributes);
	if (ret == 0) ret = mbedtls_pk_import_into_psa(pk, &attributes, &keyId);
	if (ret != 0) return ret;
	mbedtls_pk_free(pk);
	mbedtls_pk_init(pk);
	ret = mbedtls_pk_copy_from_psa(keyId, pk);
	psa_destroy_key(keyId);
	return ret;
}

static int64_t implRsaImportPrivatePem(msString pem) {
	msCryptoRsaKeyPair* kp = (msCryptoRsaKeyPair*)msMemAlloc0(sizeof(msCryptoRsaKeyPair));
	mbedtls_pk_init(&kp->pk);
	const char* pemStr = msStringToCString(pem);
	int ret = mbedtls_pk_parse_key(&kp->pk, (const unsigned char*)pemStr,
	                                strlen(pemStr) + 1, NULL, 0);
	if (ret != 0 || mbedtls_pk_get_bitlen(&kp->pk) < RSA_MIN_BITS) return discard(kp);
	if (rebuildWithPublicHalf(&kp->pk) != 0) return discard(kp);
	return keyToHandle(kp);
}

static int64_t implRsaImportPublicPem(msString pem) {
	msCryptoRsaKeyPair* kp = (msCryptoRsaKeyPair*)msMemAlloc0(sizeof(msCryptoRsaKeyPair));
	mbedtls_pk_init(&kp->pk);
	const char* pemStr = msStringToCString(pem);
	int ret = mbedtls_pk_parse_public_key(&kp->pk, (const unsigned char*)pemStr,
	                                       strlen(pemStr) + 1);
	if (ret != 0 || mbedtls_pk_get_bitlen(&kp->pk) < RSA_MIN_BITS) return discard(kp);
	return keyToHandle(kp);
}

static msString implRsaExportPrivatePem(int64_t handle) {
	return pkWritePem(&RSA_FROM_HANDLE(handle)->pk, mbedtls_pk_write_key_pem);
}

static msString implRsaExportPublicPem(int64_t handle) {
	return pkWritePem(&RSA_FROM_HANDLE(handle)->pk, mbedtls_pk_write_pubkey_pem);
}

/* A new key that holds only the public half of the given one. */
static int64_t implRsaPublicOf(int64_t handle) {
	msString pem = implRsaExportPublicPem(handle);
	if (pem.len == 0) return 0;
	return implRsaImportPublicPem(pem);
}

static msString implRsaSign(int64_t handle, msString algorithm, int32_t pss, msString data) {
	msCryptoRsaKeyPair* key = RSA_FROM_HANDLE(handle);
	mbedtls_md_type_t mdType;
	unsigned char hash[MBEDTLS_MD_MAX_SIZE];
	int hashLen = pkHash(algorithm, 1, data, &mdType, hash);
	if (hashLen == 0) return MS_EMPTY_STRING;
	unsigned char sig[MBEDTLS_PK_SIGNATURE_MAX_SIZE];
	size_t sigLen = 0;
	int ret = mbedtls_pk_sign_ext(pss ? MBEDTLS_PK_SIGALG_RSA_PSS : MBEDTLS_PK_SIGALG_RSA_PKCS1V15,
		&key->pk, mdType, hash, hashLen, sig, sizeof(sig), &sigLen);
	if (ret != 0) return MS_EMPTY_STRING;
	return msStringNew((const char*)sig, (int64_t)sigLen);
}

static double implRsaVerify(int64_t handle, msString algorithm, int32_t pss, msString data, msString signature) {
	msCryptoRsaKeyPair* key = RSA_FROM_HANDLE(handle);
	mbedtls_md_type_t mdType;
	unsigned char hash[MBEDTLS_MD_MAX_SIZE];
	int hashLen = pkHash(algorithm, 0, data, &mdType, hash);
	if (hashLen == 0) return 0.0;
	int ret = mbedtls_pk_verify_ext(pss ? MBEDTLS_PK_SIGALG_RSA_PSS : MBEDTLS_PK_SIGALG_RSA_PKCS1V15,
		&key->pk, mdType, hash, hashLen,
		(const unsigned char*)msStringToCString(signature), signature.len);
	return (ret == 0) ? 1.0 : 0.0;
}

/* A PSA key slot holds one algorithm, and the process has 32 slots for every key and TLS session,
 * so a key object keeps no slot of its own: OAEP imports the PK context for the call and destroys it. */
static msString implRsaEncrypt(int64_t handle, msString data) {
	msCryptoRsaKeyPair* key = RSA_FROM_HANDLE(handle);
	psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
	mbedtls_pk_get_psa_attributes(&key->pk, PSA_KEY_USAGE_ENCRYPT, &attributes);
	psa_set_key_algorithm(&attributes, PSA_ALG_RSA_OAEP(PSA_ALG_SHA_256));
	psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_ENCRYPT);
	mbedtls_svc_key_id_t keyId;
	int ret = mbedtls_pk_import_into_psa(&key->pk, &attributes, &keyId);
	if (ret != 0) return MS_EMPTY_STRING;
	size_t outSize = (mbedtls_pk_get_bitlen(&key->pk) + 7) / 8;
	unsigned char* output = (unsigned char*)msMemAlloc(outSize);
	size_t olen = 0;
	psa_status_t status = psa_asymmetric_encrypt(keyId, PSA_ALG_RSA_OAEP(PSA_ALG_SHA_256),
		(const uint8_t*)msStringToCString(data), data.len, NULL, 0, output, outSize, &olen);
	psa_destroy_key(keyId);
	if (status != PSA_SUCCESS) { free(output); return MS_EMPTY_STRING; }
	msString result = msStringNew((const char*)output, (int64_t)olen);
	free(output);
	return result;
}

static msString implRsaDecrypt(int64_t handle, msString data) {
	msCryptoRsaKeyPair* key = RSA_FROM_HANDLE(handle);
	psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
	mbedtls_pk_get_psa_attributes(&key->pk, PSA_KEY_USAGE_DECRYPT, &attributes);
	psa_set_key_algorithm(&attributes, PSA_ALG_RSA_OAEP(PSA_ALG_SHA_256));
	psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_DECRYPT);
	mbedtls_svc_key_id_t keyId;
	int ret = mbedtls_pk_import_into_psa(&key->pk, &attributes, &keyId);
	if (ret != 0) return MS_EMPTY_STRING;
	size_t outSize = (mbedtls_pk_get_bitlen(&key->pk) + 7) / 8;
	unsigned char* output = (unsigned char*)msMemAlloc(outSize);
	size_t olen = 0;
	psa_status_t status = psa_asymmetric_decrypt(keyId, PSA_ALG_RSA_OAEP(PSA_ALG_SHA_256),
		(const uint8_t*)msStringToCString(data), data.len, NULL, 0, output, outSize, &olen);
	psa_destroy_key(keyId);
	if (status != PSA_SUCCESS) { mbedtls_platform_zeroize(output, outSize); free(output); return MS_EMPTY_STRING; }
	msString result = msStringNew((const char*)output, (int64_t)olen);
	mbedtls_platform_zeroize(output, outSize);
	free(output);
	return result;
}

LOCKED(int64_t, RsaGenerate, (int32_t bits), (bits), 0)
LOCKED(int64_t, RsaImportPrivatePem, (msString pem), (pem), 0)
LOCKED(int64_t, RsaImportPublicPem, (msString pem), (pem), 0)
LOCKED(msString, RsaExportPrivatePem, (int64_t handle), (handle), MS_EMPTY_STRING)
LOCKED(msString, RsaExportPublicPem, (int64_t handle), (handle), MS_EMPTY_STRING)
LOCKED(int64_t, RsaPublicOf, (int64_t handle), (handle), 0)
LOCKED(msString, RsaSign, (int64_t handle, msString algorithm, int32_t pss, msString data), (handle, algorithm, pss, data), MS_EMPTY_STRING)
LOCKED(double, RsaVerify, (int64_t handle, msString algorithm, int32_t pss, msString data, msString signature), (handle, algorithm, pss, data, signature), 0.0)
LOCKED(msString, RsaEncrypt, (int64_t handle, msString data), (handle, data), MS_EMPTY_STRING)
LOCKED(msString, RsaDecrypt, (int64_t handle, msString data), (handle, data), MS_EMPTY_STRING)

void msCryptoRsaFree(int64_t handle) {
	msCryptoRsaKeyPair* key = RSA_FROM_HANDLE(handle);
	if (!key) return;
	msPsaLock();
	mbedtls_pk_free(&key->pk);
	msPsaUnlock();
	free(key);
}
