#include "src/test/crypto/aeadOracle.h"

#include <stddef.h>

#include "vendor/monocypher/src/monocypher.h"
#include "mbedtls/private/gcm.h"

int64_t msTestXChachaSealRef(const uint8_t *key, int64_t keyLen, const uint8_t *nonce, int64_t nonceLen,
		const uint8_t *plainText, int64_t plainTextLen, const uint8_t *aad, int64_t aadLen, uint8_t *out) {
	if (keyLen != 32 || nonceLen != 24) return 0;
	for (int i = 0; i < 24; i++) out[i] = nonce[i];
	crypto_aead_lock(out + 24, out + 24 + plainTextLen, key, nonce, aad, (size_t)aadLen, plainText, (size_t)plainTextLen);
	return 1;
}

int64_t msTestXChachaOpenRef(const uint8_t *key, int64_t keyLen, const uint8_t *sealed, int64_t sealedLen,
		const uint8_t *aad, int64_t aadLen, uint8_t *out) {
	if (keyLen != 32 || sealedLen < 40) return 0;
	size_t textLen = (size_t)sealedLen - 40;
	return crypto_aead_unlock(out, sealed + 24 + textLen, key, sealed, aad, (size_t)aadLen, sealed + 24, textLen) == 0;
}

int64_t msTestGcmSealRef(const uint8_t *key, int64_t keyLen, const uint8_t *nonce, int64_t nonceLen,
		const uint8_t *plainText, int64_t plainTextLen, const uint8_t *aad, int64_t aadLen, uint8_t *out) {
	if (nonceLen != 12) return 0;
	for (int i = 0; i < 12; i++) out[i] = nonce[i];
	mbedtls_gcm_context gcm;
	mbedtls_gcm_init(&gcm);
	int ok = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, (unsigned int)keyLen * 8) == 0
		&& mbedtls_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_ENCRYPT, (size_t)plainTextLen, nonce, 12, aad, (size_t)aadLen,
			plainText, out + 12, 16, out + 12 + plainTextLen) == 0;
	mbedtls_gcm_free(&gcm);
	return ok;
}

int64_t msTestGcmOpenRef(const uint8_t *key, int64_t keyLen, const uint8_t *sealed, int64_t sealedLen,
		const uint8_t *aad, int64_t aadLen, uint8_t *out) {
	if (sealedLen < 28) return 0;
	size_t textLen = (size_t)sealedLen - 28;
	mbedtls_gcm_context gcm;
	mbedtls_gcm_init(&gcm);
	int ok = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, (unsigned int)keyLen * 8) == 0
		&& mbedtls_gcm_auth_decrypt(&gcm, textLen, sealed, 12, aad, (size_t)aadLen, sealed + 12 + textLen, 16,
			sealed + 12, out) == 0;
	mbedtls_gcm_free(&gcm);
	return ok;
}
