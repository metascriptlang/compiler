/*
 * MetaScript Argon2 Runtime — wraps PHC winner reference implementation.
 */

#include "runtime/crypto/kdf/argon2.h"
#include "runtime/core/system.h"
#include "vendor/argon2/include/argon2.h"
#include <stdlib.h>
#include <string.h>

msString msCryptoArgon2Check(int32_t timeCost, int32_t memoryCost,
                             int32_t parallelism, int32_t hashLen,
                             int64_t saltLen) {
	int code = ARGON2_OK;
	if (hashLen < (int64_t)ARGON2_MIN_OUTLEN) code = ARGON2_OUTPUT_TOO_SHORT;
	else if (saltLen < (int64_t)ARGON2_MIN_SALT_LENGTH) code = ARGON2_SALT_TOO_SHORT;
	else if (timeCost < (int64_t)ARGON2_MIN_TIME) code = ARGON2_TIME_TOO_SMALL;
	else if (parallelism < (int64_t)ARGON2_MIN_LANES) code = ARGON2_LANES_TOO_FEW;
	else if (parallelism > (int64_t)ARGON2_MAX_LANES) code = ARGON2_LANES_TOO_MANY;
	else if (memoryCost < (int64_t)ARGON2_MIN_MEMORY
	         || memoryCost < 8 * (int64_t)parallelism) code = ARGON2_MEMORY_TOO_LITTLE;
	else if ((int64_t)memoryCost > (int64_t)ARGON2_MAX_MEMORY) code = ARGON2_MEMORY_TOO_MUCH;
	if (code == ARGON2_OK) return MS_EMPTY_STRING;
	const char* message = argon2_error_message(code);
	return msStringNew(message, (int64_t)strlen(message));
}

msString msCryptoArgon2Hash(msString password, msString salt,
                            int32_t timeCost, int32_t memoryCost,
                            int32_t parallelism, int32_t hashLen) {
	size_t encodedLen = argon2_encodedlen(
		(uint32_t)timeCost, (uint32_t)memoryCost, (uint32_t)parallelism,
		(uint32_t)msStrLen(salt), (uint32_t)hashLen, Argon2_id);
	char* encoded = (char*)malloc(encodedLen + 1);
	if (encoded == NULL) return MS_EMPTY_STRING;

	int ret = argon2id_hash_encoded(
		(uint32_t)timeCost, (uint32_t)memoryCost, (uint32_t)parallelism,
		msStringToCString(password), (size_t)msStrLen(password),
		msStringToCString(salt), (size_t)msStrLen(salt),
		(size_t)hashLen, encoded, encodedLen + 1);

	if (ret != ARGON2_OK) { free(encoded); return MS_EMPTY_STRING; }
	msString result = msStringNew(encoded, (int64_t)strlen(encoded));
	free(encoded);
	return result;
}

double msCryptoArgon2Verify(msString encoded, msString password) {
	int ret = argon2id_verify(
		msStringToCString(encoded),
		msStringToCString(password), (size_t)msStrLen(password));
	return (ret == ARGON2_OK) ? 1.0 : 0.0;
}

msString msCryptoArgon2HashRaw(msString password, msString salt,
                               int32_t timeCost, int32_t memoryCost,
                               int32_t parallelism, int32_t hashLen) {
	uint8_t* hash = (uint8_t*)malloc((size_t)hashLen);
	if (hash == NULL) return MS_EMPTY_STRING;

	int ret = argon2id_hash_raw(
		(uint32_t)timeCost, (uint32_t)memoryCost, (uint32_t)parallelism,
		msStringToCString(password), (size_t)msStrLen(password),
		msStringToCString(salt), (size_t)msStrLen(salt),
		hash, (size_t)hashLen);

	if (ret != ARGON2_OK) { free(hash); return MS_EMPTY_STRING; }
	msString result = msStringNew((const char*)hash, (int64_t)hashLen);
	free(hash);
	return result;
}
