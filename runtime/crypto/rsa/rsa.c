/*
 * MetaScript Asymmetric Crypto — RSA + ECDSA + ECDH
 *
 * Ported from reference ~/projects/metascript/std/crypto/crypto.c
 * Adapted: ms_crypto_* → msCrypto*, msBool → double, msOptionalString → msString
 */

#include "runtime/crypto/rsa/rsa.h"
#include "runtime/core/system.h"
#include <stdlib.h>
#include <string.h>

/* mbedTLS PK + PSA APIs */
#include "mbedtls/pk.h"
#include "mbedtls/md.h"
#include "psa/crypto.h"

/* ===== Handle ↔ Pointer Cast ===== */
/* Public API uses int64_t handles. Internal functions use typed pointers. */
#include <stdint.h>
#define RSA_TO_HANDLE(p) ((int64_t)(intptr_t)(p))
#define RSA_FROM_HANDLE(h) ((msCryptoRsaKeyPair*)(intptr_t)(h))
#define EC_TO_HANDLE(p) ((int64_t)(intptr_t)(p))
#define EC_FROM_HANDLE(h) ((msCryptoEcKeyPair*)(intptr_t)(h))

/* ===== Key Pair Structs ===== */

struct msCryptoRsaKeyPair {
	mbedtls_pk_context pk;
};

struct msCryptoEcKeyPair {
	mbedtls_pk_context pk;
};

/* ===== PSA Init ===== */

static int psaInitialized = 0;
static int ensurePsa(void) {
	if (psaInitialized) return 0;
	psa_status_t status = psa_crypto_init();
	if (status != PSA_SUCCESS) return -1;
	psaInitialized = 1;
	return 0;
}

/* ===== MD Type Mapping ===== */

static mbedtls_md_type_t getMdType(const char* algo, size_t len) {
	if (len == 6 && memcmp(algo, "sha256", 6) == 0) return MBEDTLS_MD_SHA256;
	if (len == 6 && memcmp(algo, "sha384", 6) == 0) return MBEDTLS_MD_SHA384;
	if (len == 6 && memcmp(algo, "sha512", 6) == 0) return MBEDTLS_MD_SHA512;
	if (len == 4 && memcmp(algo, "sha1", 4) == 0) return MBEDTLS_MD_SHA1;
	return MBEDTLS_MD_NONE;
}

/* ===== RSA ===== */

int64_t msCryptoRsaGenerate(int32_t bits) {
	if (ensurePsa() != 0) return 0;
	psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
	psa_set_key_usage_flags(&attributes,
		PSA_KEY_USAGE_SIGN_HASH | PSA_KEY_USAGE_VERIFY_HASH |
		PSA_KEY_USAGE_ENCRYPT | PSA_KEY_USAGE_DECRYPT |
		PSA_KEY_USAGE_EXPORT);
	psa_set_key_algorithm(&attributes, PSA_ALG_RSA_PKCS1V15_SIGN(PSA_ALG_ANY_HASH));
	psa_set_key_type(&attributes, PSA_KEY_TYPE_RSA_KEY_PAIR);
	psa_set_key_bits(&attributes, (size_t)bits);
	mbedtls_svc_key_id_t keyId;
	psa_status_t status = psa_generate_key(&attributes, &keyId);
	if (status != PSA_SUCCESS) return 0;
	msCryptoRsaKeyPair* kp = (msCryptoRsaKeyPair*)calloc(1, sizeof(msCryptoRsaKeyPair));
	if (!kp) { psa_destroy_key(keyId); return 0; }
	mbedtls_pk_init(&kp->pk);
	int ret = mbedtls_pk_copy_from_psa(keyId, &kp->pk);
	psa_destroy_key(keyId);
	if (ret != 0) { mbedtls_pk_free(&kp->pk); free(kp); return 0; }
	return RSA_TO_HANDLE(kp);
}

int64_t msCryptoRsaImportPrivatePem(msString pem) {
	msCryptoRsaKeyPair* kp = (msCryptoRsaKeyPair*)calloc(1, sizeof(msCryptoRsaKeyPair));
	if (!kp) return 0;
	mbedtls_pk_init(&kp->pk);
	const char* pemStr = msStringToCString(pem);
	int ret = mbedtls_pk_parse_key(&kp->pk, (const unsigned char*)pemStr,
	                                strlen(pemStr) + 1, NULL, 0);
	if (ret != 0) { mbedtls_pk_free(&kp->pk); free(kp); return 0; }
	return RSA_TO_HANDLE(kp);
}

int64_t msCryptoRsaImportPublicPem(msString pem) {
	msCryptoRsaKeyPair* kp = (msCryptoRsaKeyPair*)calloc(1, sizeof(msCryptoRsaKeyPair));
	if (!kp) return 0;
	mbedtls_pk_init(&kp->pk);
	const char* pemStr = msStringToCString(pem);
	int ret = mbedtls_pk_parse_public_key(&kp->pk, (const unsigned char*)pemStr,
	                                       strlen(pemStr) + 1);
	if (ret != 0) { mbedtls_pk_free(&kp->pk); free(kp); return 0; }
	return RSA_TO_HANDLE(kp);
}

msString msCryptoRsaExportPrivatePem(int64_t handle) {
	msCryptoRsaKeyPair* key = RSA_FROM_HANDLE(handle); if (!key) return MS_EMPTY_STRING;
	unsigned char buf[4096];
	int ret = mbedtls_pk_write_key_pem(&key->pk, buf, sizeof(buf));
	if (ret != 0) return MS_EMPTY_STRING;
	return msStringNew((const char*)buf, (int64_t)strlen((const char*)buf));
}

msString msCryptoRsaExportPublicPem(int64_t handle) {
	msCryptoRsaKeyPair* key = RSA_FROM_HANDLE(handle); if (!key) return MS_EMPTY_STRING;
	unsigned char buf[4096];
	int ret = mbedtls_pk_write_pubkey_pem(&key->pk, buf, sizeof(buf));
	if (ret != 0) return MS_EMPTY_STRING;
	return msStringNew((const char*)buf, (int64_t)strlen((const char*)buf));
}

msString msCryptoRsaSign(int64_t handle, msString algorithm, msString data) {
	msCryptoRsaKeyPair* key = RSA_FROM_HANDLE(handle); if (!key) return MS_EMPTY_STRING;
	mbedtls_md_type_t mdType = getMdType(msStringToCString(algorithm), algorithm.len);
	if (mdType == MBEDTLS_MD_NONE) return MS_EMPTY_STRING;
	const mbedtls_md_info_t* mdInfo = mbedtls_md_info_from_type(mdType);
	if (!mdInfo) return MS_EMPTY_STRING;
	unsigned char hash[MBEDTLS_MD_MAX_SIZE];
	int hashLen = mbedtls_md_get_size(mdInfo);
	int ret = mbedtls_md(mdInfo, (const unsigned char*)msStringToCString(data), data.len, hash);
	if (ret != 0) return MS_EMPTY_STRING;
	unsigned char sig[MBEDTLS_PK_SIGNATURE_MAX_SIZE];
	size_t sigLen = 0;
	ret = mbedtls_pk_sign(&key->pk, mdType, hash, hashLen, sig, sizeof(sig), &sigLen);
	if (ret != 0) return MS_EMPTY_STRING;
	return msStringNew((const char*)sig, (int64_t)sigLen);
}

double msCryptoRsaVerify(int64_t handle, msString algorithm, msString data, msString signature) {
	msCryptoRsaKeyPair* key = RSA_FROM_HANDLE(handle); if (!key) return 0.0;
	mbedtls_md_type_t mdType = getMdType(msStringToCString(algorithm), algorithm.len);
	if (mdType == MBEDTLS_MD_NONE) return 0.0;
	const mbedtls_md_info_t* mdInfo = mbedtls_md_info_from_type(mdType);
	if (!mdInfo) return 0.0;
	unsigned char hash[MBEDTLS_MD_MAX_SIZE];
	int hashLen = mbedtls_md_get_size(mdInfo);
	int ret = mbedtls_md(mdInfo, (const unsigned char*)msStringToCString(data), data.len, hash);
	if (ret != 0) return 0.0;
	ret = mbedtls_pk_verify(&key->pk, mdType, hash, hashLen,
	                         (const unsigned char*)msStringToCString(signature), signature.len);
	return (ret == 0) ? 1.0 : 0.0;
}

msString msCryptoRsaEncrypt(int64_t handle, msString data) {
	msCryptoRsaKeyPair* key = RSA_FROM_HANDLE(handle); if (!key) return MS_EMPTY_STRING;
	if (ensurePsa() != 0) return MS_EMPTY_STRING;
	psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
	mbedtls_pk_get_psa_attributes(&key->pk, PSA_KEY_USAGE_ENCRYPT, &attributes);
	psa_set_key_algorithm(&attributes, PSA_ALG_RSA_OAEP(PSA_ALG_SHA_256));
	psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_ENCRYPT);
	mbedtls_svc_key_id_t keyId;
	int ret = mbedtls_pk_import_into_psa(&key->pk, &attributes, &keyId);
	if (ret != 0) return MS_EMPTY_STRING;
	size_t keyBits = mbedtls_pk_get_bitlen(&key->pk);
	size_t outSize = (keyBits + 7) / 8;
	unsigned char* output = (unsigned char*)malloc(outSize);
	if (!output) { psa_destroy_key(keyId); return MS_EMPTY_STRING; }
	size_t olen = 0;
	psa_status_t status = psa_asymmetric_encrypt(keyId, PSA_ALG_RSA_OAEP(PSA_ALG_SHA_256),
		(const uint8_t*)msStringToCString(data), data.len, NULL, 0, output, outSize, &olen);
	psa_destroy_key(keyId);
	if (status != PSA_SUCCESS) { free(output); return MS_EMPTY_STRING; }
	msString result = msStringNew((const char*)output, (int64_t)olen);
	free(output);
	return result;
}

msString msCryptoRsaDecrypt(int64_t handle, msString data) {
	msCryptoRsaKeyPair* key = RSA_FROM_HANDLE(handle); if (!key) return MS_EMPTY_STRING;
	if (ensurePsa() != 0) return MS_EMPTY_STRING;
	psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
	mbedtls_pk_get_psa_attributes(&key->pk, PSA_KEY_USAGE_DECRYPT, &attributes);
	psa_set_key_algorithm(&attributes, PSA_ALG_RSA_OAEP(PSA_ALG_SHA_256));
	psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_DECRYPT | PSA_KEY_USAGE_EXPORT);
	mbedtls_svc_key_id_t keyId;
	int ret = mbedtls_pk_import_into_psa(&key->pk, &attributes, &keyId);
	if (ret != 0) return MS_EMPTY_STRING;
	size_t keyBits = mbedtls_pk_get_bitlen(&key->pk);
	size_t outSize = (keyBits + 7) / 8;
	unsigned char* output = (unsigned char*)malloc(outSize);
	if (!output) { psa_destroy_key(keyId); return MS_EMPTY_STRING; }
	size_t olen = 0;
	psa_status_t status = psa_asymmetric_decrypt(keyId, PSA_ALG_RSA_OAEP(PSA_ALG_SHA_256),
		(const uint8_t*)msStringToCString(data), data.len, NULL, 0, output, outSize, &olen);
	psa_destroy_key(keyId);
	if (status != PSA_SUCCESS) { free(output); return MS_EMPTY_STRING; }
	msString result = msStringNew((const char*)output, (int64_t)olen);
	free(output);
	return result;
}

void msCryptoRsaFree(int64_t handle) {
	msCryptoRsaKeyPair* key = RSA_FROM_HANDLE(handle); if (key) { mbedtls_pk_free(&key->pk); free(key); }
}

/* ===== ECDSA / ECDH ===== */

static int getPsaCurve(const char* curve, size_t len,
                       psa_ecc_family_t* family, size_t* bits) {
	if (len == 4 && memcmp(curve, "p256", 4) == 0) { *family = PSA_ECC_FAMILY_SECP_R1; *bits = 256; return 0; }
	if (len == 4 && memcmp(curve, "p384", 4) == 0) { *family = PSA_ECC_FAMILY_SECP_R1; *bits = 384; return 0; }
	if (len == 4 && memcmp(curve, "p521", 4) == 0) { *family = PSA_ECC_FAMILY_SECP_R1; *bits = 521; return 0; }
	if (len == 9 && memcmp(curve, "secp256k1", 9) == 0) { *family = PSA_ECC_FAMILY_SECP_K1; *bits = 256; return 0; }
	return -1;
}

int64_t msCryptoEcGenerate(msString curve) {
	if (ensurePsa() != 0) return NULL;
	psa_ecc_family_t family;
	size_t bits;
	if (getPsaCurve(msStringToCString(curve), curve.len, &family, &bits) != 0) return NULL;
	psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
	psa_set_key_usage_flags(&attributes,
		PSA_KEY_USAGE_SIGN_HASH | PSA_KEY_USAGE_VERIFY_HASH |
		PSA_KEY_USAGE_DERIVE | PSA_KEY_USAGE_EXPORT);
	psa_set_key_algorithm(&attributes, PSA_ALG_ECDSA(PSA_ALG_ANY_HASH));
	psa_set_key_type(&attributes, PSA_KEY_TYPE_ECC_KEY_PAIR(family));
	psa_set_key_bits(&attributes, bits);
	mbedtls_svc_key_id_t keyId;
	psa_status_t status = psa_generate_key(&attributes, &keyId);
	if (status != PSA_SUCCESS) return 0;
	msCryptoEcKeyPair* kp = (msCryptoEcKeyPair*)calloc(1, sizeof(msCryptoEcKeyPair));
	if (!kp) { psa_destroy_key(keyId); return 0; }
	mbedtls_pk_init(&kp->pk);
	int ret = mbedtls_pk_copy_from_psa(keyId, &kp->pk);
	psa_destroy_key(keyId);
	if (ret != 0) { mbedtls_pk_free(&kp->pk); free(kp); return 0; }
	return RSA_TO_HANDLE(kp);
}

int64_t msCryptoEcImportPrivatePem(msString pem) {
	msCryptoEcKeyPair* kp = (msCryptoEcKeyPair*)calloc(1, sizeof(msCryptoEcKeyPair));
	if (!kp) return 0;
	mbedtls_pk_init(&kp->pk);
	int ret = mbedtls_pk_parse_key(&kp->pk, (const unsigned char*)msStringToCString(pem),
	                                strlen(msStringToCString(pem)) + 1, NULL, 0);
	if (ret != 0) { mbedtls_pk_free(&kp->pk); free(kp); return 0; }
	return RSA_TO_HANDLE(kp);
}

int64_t msCryptoEcImportPublicPem(msString pem) {
	msCryptoEcKeyPair* kp = (msCryptoEcKeyPair*)calloc(1, sizeof(msCryptoEcKeyPair));
	if (!kp) return 0;
	mbedtls_pk_init(&kp->pk);
	int ret = mbedtls_pk_parse_public_key(&kp->pk, (const unsigned char*)msStringToCString(pem),
	                                       strlen(msStringToCString(pem)) + 1);
	if (ret != 0) { mbedtls_pk_free(&kp->pk); free(kp); return 0; }
	return RSA_TO_HANDLE(kp);
}

msString msCryptoEcExportPrivatePem(int64_t handle) {
	msCryptoEcKeyPair* key = EC_FROM_HANDLE(handle); if (!key) return MS_EMPTY_STRING;
	unsigned char buf[4096];
	int ret = mbedtls_pk_write_key_pem(&key->pk, buf, sizeof(buf));
	if (ret != 0) return MS_EMPTY_STRING;
	return msStringNew((const char*)buf, (int64_t)strlen((const char*)buf));
}

msString msCryptoEcExportPublicPem(int64_t handle) {
	msCryptoEcKeyPair* key = EC_FROM_HANDLE(handle); if (!key) return MS_EMPTY_STRING;
	unsigned char buf[4096];
	int ret = mbedtls_pk_write_pubkey_pem(&key->pk, buf, sizeof(buf));
	if (ret != 0) return MS_EMPTY_STRING;
	return msStringNew((const char*)buf, (int64_t)strlen((const char*)buf));
}

msString msCryptoEcdsaSign(int64_t handle, msString algorithm, msString data) {
	msCryptoEcKeyPair* key = EC_FROM_HANDLE(handle); if (!key) return MS_EMPTY_STRING;
	mbedtls_md_type_t mdType = getMdType(msStringToCString(algorithm), algorithm.len);
	if (mdType == MBEDTLS_MD_NONE) return MS_EMPTY_STRING;
	const mbedtls_md_info_t* mdInfo = mbedtls_md_info_from_type(mdType);
	if (!mdInfo) return MS_EMPTY_STRING;
	unsigned char hash[MBEDTLS_MD_MAX_SIZE];
	int hashLen = mbedtls_md_get_size(mdInfo);
	int ret = mbedtls_md(mdInfo, (const unsigned char*)msStringToCString(data), data.len, hash);
	if (ret != 0) return MS_EMPTY_STRING;
	unsigned char sig[MBEDTLS_PK_SIGNATURE_MAX_SIZE];
	size_t sigLen = 0;
	ret = mbedtls_pk_sign(&key->pk, mdType, hash, hashLen, sig, sizeof(sig), &sigLen);
	if (ret != 0) return MS_EMPTY_STRING;
	return msStringNew((const char*)sig, (int64_t)sigLen);
}

double msCryptoEcdsaVerify(int64_t handle, msString algorithm, msString data, msString signature) {
	msCryptoEcKeyPair* key = EC_FROM_HANDLE(handle); if (!key) return 0.0;
	mbedtls_md_type_t mdType = getMdType(msStringToCString(algorithm), algorithm.len);
	if (mdType == MBEDTLS_MD_NONE) return 0.0;
	const mbedtls_md_info_t* mdInfo = mbedtls_md_info_from_type(mdType);
	if (!mdInfo) return 0.0;
	unsigned char hash[MBEDTLS_MD_MAX_SIZE];
	int hashLen = mbedtls_md_get_size(mdInfo);
	int ret = mbedtls_md(mdInfo, (const unsigned char*)msStringToCString(data), data.len, hash);
	if (ret != 0) return 0.0;
	ret = mbedtls_pk_verify(&key->pk, mdType, hash, hashLen,
	                         (const unsigned char*)msStringToCString(signature), signature.len);
	return (ret == 0) ? 1.0 : 0.0;
}

msString msCryptoEcdhDerive(int64_t privateHandle, int64_t publicHandle) {
	msCryptoEcKeyPair* privateKey = EC_FROM_HANDLE(privateHandle); msCryptoEcKeyPair* publicKey = EC_FROM_HANDLE(publicHandle); if (!privateKey || !publicKey) return MS_EMPTY_STRING;
	if (ensurePsa() != 0) return MS_EMPTY_STRING;
	/* Import private key into PSA */
	psa_key_attributes_t privAttr = PSA_KEY_ATTRIBUTES_INIT;
	mbedtls_pk_get_psa_attributes(&privateKey->pk, PSA_KEY_USAGE_DERIVE, &privAttr);
	psa_set_key_algorithm(&privAttr, PSA_ALG_ECDH);
	psa_set_key_usage_flags(&privAttr, PSA_KEY_USAGE_DERIVE | PSA_KEY_USAGE_EXPORT);
	mbedtls_svc_key_id_t privId;
	int ret = mbedtls_pk_import_into_psa(&privateKey->pk, &privAttr, &privId);
	if (ret != 0) return MS_EMPTY_STRING;
	/* Export public key raw */
	psa_key_attributes_t pubAttr = PSA_KEY_ATTRIBUTES_INIT;
	mbedtls_pk_get_psa_attributes(&publicKey->pk, PSA_KEY_USAGE_EXPORT, &pubAttr);
	mbedtls_svc_key_id_t pubId;
	ret = mbedtls_pk_import_into_psa(&publicKey->pk, &pubAttr, &pubId);
	if (ret != 0) { psa_destroy_key(privId); return MS_EMPTY_STRING; }
	uint8_t pubKeyRaw[256];
	size_t pubKeyLen = 0;
	psa_status_t status = psa_export_public_key(pubId, pubKeyRaw, sizeof(pubKeyRaw), &pubKeyLen);
	psa_destroy_key(pubId);
	if (status != PSA_SUCCESS) { psa_destroy_key(privId); return MS_EMPTY_STRING; }
	/* Raw ECDH agreement */
	uint8_t shared[256];
	size_t sharedLen = 0;
	status = psa_raw_key_agreement(PSA_ALG_ECDH, privId, pubKeyRaw, pubKeyLen,
	                                shared, sizeof(shared), &sharedLen);
	psa_destroy_key(privId);
	if (status != PSA_SUCCESS) return MS_EMPTY_STRING;
	return msStringNew((const char*)shared, (int64_t)sharedLen);
}

void msCryptoEcFree(int64_t handle) {
	msCryptoEcKeyPair* key = EC_FROM_HANDLE(handle); if (key) { mbedtls_pk_free(&key->pk); free(key); }
}
