#include "src/test/crypto/argon2Oracle.h"
#include "runtime/core/system.h"
#include "vendor/argon2/include/argon2.h"
#include <stdlib.h>
#include <string.h>

msString msArgon2OracleRaw(msString password, msString salt, msString secret, msString ad,
                           int32_t mode, int32_t timeCost, int32_t memoryCost,
                           int32_t parallelism, int32_t hashLen) {
	uint8_t* out = (uint8_t*)malloc(hashLen > 0 ? (size_t)hashLen : 1);
	if (out == NULL) return MS_EMPTY_STRING;
	argon2_context ctx;
	memset(&ctx, 0, sizeof ctx);
	ctx.out = out;
	ctx.outlen = (uint32_t)hashLen;
	ctx.pwd = (uint8_t*)msStrData(&password);
	ctx.pwdlen = (uint32_t)msStrLen(password);
	ctx.salt = (uint8_t*)msStrData(&salt);
	ctx.saltlen = (uint32_t)msStrLen(salt);
	ctx.secret = msStrLen(secret) ? (uint8_t*)msStrData(&secret) : NULL;
	ctx.secretlen = (uint32_t)msStrLen(secret);
	ctx.ad = msStrLen(ad) ? (uint8_t*)msStrData(&ad) : NULL;
	ctx.adlen = (uint32_t)msStrLen(ad);
	ctx.t_cost = (uint32_t)timeCost;
	ctx.m_cost = (uint32_t)memoryCost;
	ctx.lanes = (uint32_t)parallelism;
	ctx.threads = 1;
	ctx.version = ARGON2_VERSION_13;
	int ret = argon2_ctx(&ctx, (argon2_type)mode);
	msString result = ret == ARGON2_OK ? msStringNew((const char*)out, (int64_t)hashLen) : MS_EMPTY_STRING;
	free(out);
	return result;
}

msString msArgon2OracleEncoded(msString password, msString salt, int32_t mode,
                               int32_t timeCost, int32_t memoryCost, int32_t parallelism,
                               int32_t hashLen) {
	size_t length = argon2_encodedlen((uint32_t)timeCost, (uint32_t)memoryCost, (uint32_t)parallelism,
	                                  (uint32_t)msStrLen(salt), (uint32_t)hashLen, (argon2_type)mode);
	char* encoded = (char*)malloc(length + 1);
	if (encoded == NULL) return MS_EMPTY_STRING;
	int ret = argon2_hash((uint32_t)timeCost, (uint32_t)memoryCost, (uint32_t)parallelism,
	                      msStrData(&password), (size_t)msStrLen(password),
	                      msStrData(&salt), (size_t)msStrLen(salt), NULL, (size_t)hashLen,
	                      encoded, length + 1, (argon2_type)mode, ARGON2_VERSION_13);
	msString result = ret == ARGON2_OK ? msStringNew(encoded, (int64_t)strlen(encoded)) : MS_EMPTY_STRING;
	free(encoded);
	return result;
}

int32_t msArgon2OracleVerify(msString encoded, msString password, int32_t mode) {
	return argon2_verify(msStringToCString(encoded), msStrData(&password), (size_t)msStrLen(password),
	                     (argon2_type)mode) == ARGON2_OK;
}
