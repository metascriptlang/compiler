#ifndef MS_TEST_AEAD_ORACLE_H
#define MS_TEST_AEAD_ORACLE_H

#include <stdint.h>

int64_t msTestXChachaSealRef(const uint8_t *key, int64_t keyLen, const uint8_t *nonce, int64_t nonceLen,
		const uint8_t *plainText, int64_t plainTextLen, const uint8_t *aad, int64_t aadLen, uint8_t *out);
int64_t msTestXChachaOpenRef(const uint8_t *key, int64_t keyLen, const uint8_t *sealed, int64_t sealedLen,
		const uint8_t *aad, int64_t aadLen, uint8_t *out);
int64_t msTestGcmSealRef(const uint8_t *key, int64_t keyLen, const uint8_t *nonce, int64_t nonceLen,
		const uint8_t *plainText, int64_t plainTextLen, const uint8_t *aad, int64_t aadLen, uint8_t *out);
int64_t msTestGcmOpenRef(const uint8_t *key, int64_t keyLen, const uint8_t *sealed, int64_t sealedLen,
		const uint8_t *aad, int64_t aadLen, uint8_t *out);

#endif
