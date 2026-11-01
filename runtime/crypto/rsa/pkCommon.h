/*
 * What rsa.c and curves/ec.c share: the PSA lock wrapper, the hash-name mapping and the PEM writer.
 * Every PSA or PK call runs under the one lock of psaOnce.h, because MBEDTLS_THREADING_C is off.
 */
#ifndef MS_CRYPTO_PK_COMMON_H
#define MS_CRYPTO_PK_COMMON_H

#include "runtime/core/string.h"
#include "runtime/core/system.h"
#include "runtime/crypto/psaOnce.h"
#include <stdint.h>
#include <string.h>

#include "mbedtls/pk.h"
#include "mbedtls/md.h"
#include "mbedtls/platform_util.h"
#include "psa/crypto.h"

/* Defines msCrypto<name> as the lock, a PSA init and impl<name>; `fail` is returned when init fails. */
#define LOCKED(T, name, params, args, fail) \
	T msCrypto##name params { \
		msPsaLock(); \
		T result = msPsaEnsure() != 0 ? (fail) : impl##name args; \
		msPsaUnlock(); \
		return result; \
	}

static inline mbedtls_md_type_t pkMdType(msString algorithm) {
	const char* algo = msStringToCString(algorithm);
	size_t len = (size_t)algorithm.len;
	if (len == 6 && memcmp(algo, "sha256", 6) == 0) return MBEDTLS_MD_SHA256;
	if (len == 6 && memcmp(algo, "sha384", 6) == 0) return MBEDTLS_MD_SHA384;
	if (len == 6 && memcmp(algo, "sha512", 6) == 0) return MBEDTLS_MD_SHA512;
	if (len == 4 && memcmp(algo, "sha1", 4) == 0) return MBEDTLS_MD_SHA1;
	return MBEDTLS_MD_NONE;
}

/* Hashes data with the named algorithm into hash; returns the hash length, 0 when the name is
 * unknown, or when it is sha1 and forSigning (sha1 signatures are refused, verifying one is not). */
static inline int pkHash(msString algorithm, int forSigning, msString data, mbedtls_md_type_t* mdType, unsigned char* hash) {
	*mdType = pkMdType(algorithm);
	if (*mdType == MBEDTLS_MD_NONE || (forSigning && *mdType == MBEDTLS_MD_SHA1)) return 0;
	const mbedtls_md_info_t* mdInfo = mbedtls_md_info_from_type(*mdType);
	if (!mdInfo) return 0;
	if (mbedtls_md(mdInfo, (const unsigned char*)msStringToCString(data), data.len, hash) != 0) return 0;
	return mbedtls_md_get_size(mdInfo);
}

typedef int (*pkPemWriter)(const mbedtls_pk_context*, unsigned char*, size_t);

static inline msString pkWritePem(const mbedtls_pk_context* pk, pkPemWriter writer) {
	unsigned char buf[4096];
	int ret = writer(pk, buf, sizeof(buf));
	msString out = ret != 0 ? MS_EMPTY_STRING : msStringNew((const char*)buf, (int64_t)strlen((const char*)buf));
	mbedtls_platform_zeroize(buf, sizeof(buf));
	return out;
}

#endif /* MS_CRYPTO_PK_COMMON_H */
