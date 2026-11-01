/*
 * MetaScript EC — ECDSA and ECDH on P-256 and P-384
 */

#include "runtime/crypto/curves/ec.h"
#include "runtime/crypto/rsa/pkCommon.h"
#include <stdlib.h>

#define EC_TO_HANDLE(p) ((int64_t)(intptr_t)(p))
#define EC_FROM_HANDLE(h) ((msCryptoEcKey*)(intptr_t)(h))

/* pubRaw is the uncompressed public point, taken once when the key is made, so ECDH imports only
 * the private half and never rebuilds the peer's. */
struct msCryptoEcKey {
	mbedtls_pk_context pk;
	uint8_t pubRaw[133];
	size_t pubLen;
	int32_t bits;
};

static int64_t discard(msCryptoEcKey* kp) {
	mbedtls_pk_free(&kp->pk);
	free(kp);
	return 0;
}

/* Accepts only a secp_r1 key of 256 or 384 bits and records its bits and public point. */
static int64_t finish(msCryptoEcKey* kp) {
	psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
	if (mbedtls_pk_get_psa_attributes(&kp->pk, PSA_KEY_USAGE_VERIFY_HASH, &attributes) != 0) return discard(kp);
	psa_key_type_t type = psa_get_key_type(&attributes);
	size_t bits = psa_get_key_bits(&attributes);
	if (!PSA_KEY_TYPE_IS_ECC(type) || PSA_KEY_TYPE_ECC_GET_FAMILY(type) != PSA_ECC_FAMILY_SECP_R1
		|| (bits != 256 && bits != 384)) return discard(kp);
	mbedtls_svc_key_id_t keyId;
	if (mbedtls_pk_import_into_psa(&kp->pk, &attributes, &keyId) != 0) return discard(kp);
	psa_status_t status = psa_export_public_key(keyId, kp->pubRaw, sizeof(kp->pubRaw), &kp->pubLen);
	psa_destroy_key(keyId);
	if (status != PSA_SUCCESS) return discard(kp);
	kp->bits = (int32_t)bits;
	return EC_TO_HANDLE(kp);
}

static msCryptoEcKey* newKey(void) {
	msCryptoEcKey* kp = (msCryptoEcKey*)msMemAlloc0(sizeof(msCryptoEcKey));
	mbedtls_pk_init(&kp->pk);
	return kp;
}

static int64_t implEcGenerate(msString curve) {
	size_t bits = 0;
	if (curve.len == 4 && memcmp(msStringToCString(curve), "p256", 4) == 0) bits = 256;
	if (curve.len == 4 && memcmp(msStringToCString(curve), "p384", 4) == 0) bits = 384;
	if (bits == 0) return 0;
	/* Exported once into the PK context and destroyed at once, so it needs the export usage. */
	psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
	psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_EXPORT);
	psa_set_key_algorithm(&attributes, PSA_ALG_ECDSA(PSA_ALG_ANY_HASH));
	psa_set_key_type(&attributes, PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_SECP_R1));
	psa_set_key_bits(&attributes, bits);
	mbedtls_svc_key_id_t keyId;
	if (psa_generate_key(&attributes, &keyId) != PSA_SUCCESS) return 0;
	msCryptoEcKey* kp = newKey();
	int ret = mbedtls_pk_copy_from_psa(keyId, &kp->pk);
	psa_destroy_key(keyId);
	return ret != 0 ? discard(kp) : finish(kp);
}

static int64_t implEcImportPrivatePem(msString pem) {
	msCryptoEcKey* kp = newKey();
	const char* pemStr = msStringToCString(pem);
	int ret = mbedtls_pk_parse_key(&kp->pk, (const unsigned char*)pemStr, strlen(pemStr) + 1, NULL, 0);
	return ret != 0 ? discard(kp) : finish(kp);
}

static int64_t implEcImportPublicPem(msString pem) {
	msCryptoEcKey* kp = newKey();
	const char* pemStr = msStringToCString(pem);
	int ret = mbedtls_pk_parse_public_key(&kp->pk, (const unsigned char*)pemStr, strlen(pemStr) + 1);
	return ret != 0 ? discard(kp) : finish(kp);
}

static msString implEcExportPrivatePem(int64_t handle) {
	return pkWritePem(&EC_FROM_HANDLE(handle)->pk, mbedtls_pk_write_key_pem);
}

static msString implEcExportPublicPem(int64_t handle) {
	return pkWritePem(&EC_FROM_HANDLE(handle)->pk, mbedtls_pk_write_pubkey_pem);
}

static int64_t implEcPublicOf(int64_t handle) {
	msString pem = implEcExportPublicPem(handle);
	if (pem.len == 0) return 0;
	return implEcImportPublicPem(pem);
}

static int32_t implEcBits(int64_t handle) {
	return EC_FROM_HANDLE(handle)->bits;
}

static msString implEcdsaSign(int64_t handle, msString algorithm, msString data) {
	msCryptoEcKey* key = EC_FROM_HANDLE(handle);
	mbedtls_md_type_t mdType;
	unsigned char hash[MBEDTLS_MD_MAX_SIZE];
	int hashLen = pkHash(algorithm, 1, data, &mdType, hash);
	if (hashLen == 0) return MS_EMPTY_STRING;
	unsigned char sig[MBEDTLS_PK_SIGNATURE_MAX_SIZE];
	size_t sigLen = 0;
	if (mbedtls_pk_sign(&key->pk, mdType, hash, hashLen, sig, sizeof(sig), &sigLen) != 0) return MS_EMPTY_STRING;
	return msStringNew((const char*)sig, (int64_t)sigLen);
}

static double implEcdsaVerify(int64_t handle, msString algorithm, msString data, msString signature) {
	msCryptoEcKey* key = EC_FROM_HANDLE(handle);
	mbedtls_md_type_t mdType;
	unsigned char hash[MBEDTLS_MD_MAX_SIZE];
	int hashLen = pkHash(algorithm, 0, data, &mdType, hash);
	if (hashLen == 0) return 0.0;
	int ret = mbedtls_pk_verify(&key->pk, mdType, hash, hashLen,
	                             (const unsigned char*)msStringToCString(signature), signature.len);
	return (ret == 0) ? 1.0 : 0.0;
}

static msString implEcdhDerive(int64_t privateHandle, int64_t publicHandle) {
	msCryptoEcKey* privateKey = EC_FROM_HANDLE(privateHandle);
	msCryptoEcKey* publicKey = EC_FROM_HANDLE(publicHandle);
	psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
	mbedtls_pk_get_psa_attributes(&privateKey->pk, PSA_KEY_USAGE_DERIVE, &attributes);
	psa_set_key_algorithm(&attributes, PSA_ALG_ECDH);
	psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_DERIVE);
	mbedtls_svc_key_id_t keyId;
	if (mbedtls_pk_import_into_psa(&privateKey->pk, &attributes, &keyId) != 0) return MS_EMPTY_STRING;
	uint8_t shared[PSA_RAW_KEY_AGREEMENT_OUTPUT_MAX_SIZE];
	size_t sharedLen = 0;
	psa_status_t status = psa_raw_key_agreement(PSA_ALG_ECDH, keyId, publicKey->pubRaw, publicKey->pubLen,
	                                             shared, sizeof(shared), &sharedLen);
	psa_destroy_key(keyId);
	msString out = status != PSA_SUCCESS ? MS_EMPTY_STRING : msStringNew((const char*)shared, (int64_t)sharedLen);
	mbedtls_platform_zeroize(shared, sizeof(shared));
	return out;
}

LOCKED(int64_t, EcGenerate, (msString curve), (curve), 0)
LOCKED(int64_t, EcImportPrivatePem, (msString pem), (pem), 0)
LOCKED(int64_t, EcImportPublicPem, (msString pem), (pem), 0)
LOCKED(msString, EcExportPrivatePem, (int64_t handle), (handle), MS_EMPTY_STRING)
LOCKED(msString, EcExportPublicPem, (int64_t handle), (handle), MS_EMPTY_STRING)
LOCKED(int64_t, EcPublicOf, (int64_t handle), (handle), 0)
LOCKED(int32_t, EcBits, (int64_t handle), (handle), 0)
LOCKED(msString, EcdsaSign, (int64_t handle, msString algorithm, msString data), (handle, algorithm, data), MS_EMPTY_STRING)
LOCKED(double, EcdsaVerify, (int64_t handle, msString algorithm, msString data, msString signature), (handle, algorithm, data, signature), 0.0)
LOCKED(msString, EcdhDerive, (int64_t privateHandle, int64_t publicHandle), (privateHandle, publicHandle), MS_EMPTY_STRING)

void msCryptoEcFree(int64_t handle) {
	msCryptoEcKey* key = EC_FROM_HANDLE(handle);
	if (!key) return;
	msPsaLock();
	mbedtls_pk_free(&key->pk);
	msPsaUnlock();
	free(key);
}
