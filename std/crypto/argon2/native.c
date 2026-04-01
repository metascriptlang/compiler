/*
 * MetaScript Argon2 Runtime — wraps PHC winner reference implementation.
 */

#include "std/crypto/argon2/native.h"
#include "std/core/system/native.h"
#include "argon2.h"
#include <stdlib.h>
#include <string.h>

msString msCryptoArgon2Hash(msString password, msString salt,
                            int32_t timeCost, int32_t memoryCost,
                            int32_t parallelism, int32_t hashLen) {
	size_t encodedLen = argon2_encodedlen(
		(uint32_t)timeCost, (uint32_t)memoryCost, (uint32_t)parallelism,
		(uint32_t)salt.len, (uint32_t)hashLen, Argon2_id);
	char* encoded = (char*)malloc(encodedLen + 1);
	if (!encoded) return MS_EMPTY_STRING;

	int ret = argon2id_hash_encoded(
		(uint32_t)timeCost, (uint32_t)memoryCost, (uint32_t)parallelism,
		msStringToCString(password), (size_t)password.len,
		msStringToCString(salt), (size_t)salt.len,
		(size_t)hashLen, encoded, encodedLen + 1);

	if (ret != ARGON2_OK) { free(encoded); return MS_EMPTY_STRING; }
	msString result = msStringNew(encoded, (int64_t)strlen(encoded));
	free(encoded);
	return result;
}

double msCryptoArgon2Verify(msString encoded, msString password) {
	int ret = argon2id_verify(
		msStringToCString(encoded),
		msStringToCString(password), (size_t)password.len);
	return (ret == ARGON2_OK) ? 1.0 : 0.0;
}

msString msCryptoArgon2HashRaw(msString password, msString salt,
                               int32_t timeCost, int32_t memoryCost,
                               int32_t parallelism, int32_t hashLen) {
	uint8_t* hash = (uint8_t*)malloc((size_t)hashLen);
	if (!hash) return MS_EMPTY_STRING;

	int ret = argon2id_hash_raw(
		(uint32_t)timeCost, (uint32_t)memoryCost, (uint32_t)parallelism,
		msStringToCString(password), (size_t)password.len,
		msStringToCString(salt), (size_t)salt.len,
		hash, (size_t)hashLen);

	if (ret != ARGON2_OK) { free(hash); return MS_EMPTY_STRING; }
	msString result = msStringNew((const char*)hash, (int64_t)hashLen);
	free(hash);
	return result;
}
