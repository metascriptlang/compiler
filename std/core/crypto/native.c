/*
 * MetaScript Crypto Runtime — C Implementation
 *
 * Phase 1: Hashing, HMAC, random, timing-safe comparison.
 * Uses mbedTLS legacy MD API.
 */

#include "native.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* ===== mbedTLS Configuration ===== */

#ifndef MBEDTLS_DECLARE_PRIVATE_IDENTIFIERS
#define MBEDTLS_DECLARE_PRIVATE_IDENTIFIERS
#endif
#ifndef MBEDTLS_PLATFORM_C
#define MBEDTLS_PLATFORM_C
#endif
#ifndef MBEDTLS_MD_C
#define MBEDTLS_MD_C
#endif
#ifndef MBEDTLS_SHA256_C
#define MBEDTLS_SHA256_C
#endif
#ifndef MBEDTLS_SHA512_C
#define MBEDTLS_SHA512_C
#endif
#ifndef MBEDTLS_SHA1_C
#define MBEDTLS_SHA1_C
#endif
#ifndef MBEDTLS_MD5_C
#define MBEDTLS_MD5_C
#endif
#ifndef MBEDTLS_SHA3_C
#define MBEDTLS_SHA3_C
#endif
#ifndef MBEDTLS_RIPEMD160_C
#define MBEDTLS_RIPEMD160_C
#endif

#include "mbedtls/md.h"

/* ===== Internal State ===== */

static int ms_crypto_initialized = 0;

/* ===== Encoding Helpers ===== */

static const char hex_chars[] = "0123456789abcdef";

static msString encode_to_hex(const uint8_t* data, size_t len) {
	if (len == 0) return MS_EMPTY_STRING;

	int64_t hexLen = (int64_t)(len * 2);
	msStrPayload* p = (msStrPayload*)calloc(1, sizeof(msStrPayload) + hexLen + 1);
	if (!p) return MS_EMPTY_STRING;

	p->cap = hexLen;
	for (size_t i = 0; i < len; i++) {
		p->data[i * 2] = hex_chars[(data[i] >> 4) & 0x0f];
		p->data[i * 2 + 1] = hex_chars[data[i] & 0x0f];
	}
	p->data[hexLen] = '\0';

	msString result;
	result.len = hexLen;
	result.p = p;
	return result;
}

static const char b64_table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static msString encode_to_base64(const uint8_t* data, size_t len) {
	if (len == 0) return MS_EMPTY_STRING;

	size_t outLen = ((len + 2) / 3) * 4;
	msStrPayload* p = (msStrPayload*)calloc(1, sizeof(msStrPayload) + outLen + 1);
	if (!p) return MS_EMPTY_STRING;

	p->cap = (int64_t)outLen;
	size_t i = 0, j = 0;
	while (i < len) {
		uint32_t a = i < len ? data[i++] : 0;
		uint32_t b = i < len ? data[i++] : 0;
		uint32_t c = i < len ? data[i++] : 0;
		uint32_t triple = (a << 16) | (b << 8) | c;

		p->data[j++] = b64_table[(triple >> 18) & 0x3f];
		p->data[j++] = b64_table[(triple >> 12) & 0x3f];
		p->data[j++] = (i > len + 1) ? '=' : b64_table[(triple >> 6) & 0x3f];
		p->data[j++] = (i > len) ? '=' : b64_table[triple & 0x3f];
	}
	p->data[outLen] = '\0';

	msString result;
	result.len = (int64_t)outLen;
	result.p = p;
	return result;
}

static msString encode_hash(const uint8_t* data, size_t len, msString encoding) {
	const char* enc = msCStr(encoding);
	if (encoding.len == 3 && memcmp(enc, "hex", 3) == 0) {
		return encode_to_hex(data, len);
	}
	if (encoding.len == 6 && memcmp(enc, "base64", 6) == 0) {
		return encode_to_base64(data, len);
	}
	/* Default: hex */
	return encode_to_hex(data, len);
}

/* Wrap raw hash bytes into an msString (binary buffer) */
static msString raw_to_buffer(const uint8_t* data, size_t len) {
	if (len == 0) return MS_EMPTY_STRING;

	msStrPayload* p = (msStrPayload*)calloc(1, sizeof(msStrPayload) + len + 1);
	if (!p) return MS_EMPTY_STRING;

	p->cap = (int64_t)len;
	memcpy(p->data, data, len);
	p->data[len] = '\0';

	msString result;
	result.len = (int64_t)len;
	result.p = p;
	return result;
}

/* ===== Algorithm Mapping ===== */

static const mbedtls_md_info_t* get_md_info(const char* algo, size_t len) {
	mbedtls_md_type_t md_type = MBEDTLS_MD_NONE;

	/* SHA-2 family */
	if (len == 6 && memcmp(algo, "sha256", 6) == 0) md_type = MBEDTLS_MD_SHA256;
	else if (len == 6 && memcmp(algo, "sha512", 6) == 0) md_type = MBEDTLS_MD_SHA512;
	else if (len == 6 && memcmp(algo, "sha384", 6) == 0) md_type = MBEDTLS_MD_SHA384;
	else if (len == 6 && memcmp(algo, "sha224", 6) == 0) md_type = MBEDTLS_MD_SHA224;
	/* SHA-3 family */
	else if (len == 8 && memcmp(algo, "sha3-256", 8) == 0) md_type = MBEDTLS_MD_SHA3_256;
	else if (len == 8 && memcmp(algo, "sha3-384", 8) == 0) md_type = MBEDTLS_MD_SHA3_384;
	else if (len == 8 && memcmp(algo, "sha3-512", 8) == 0) md_type = MBEDTLS_MD_SHA3_512;
	else if (len == 8 && memcmp(algo, "sha3-224", 8) == 0) md_type = MBEDTLS_MD_SHA3_224;
	/* Legacy */
	else if (len == 4 && memcmp(algo, "sha1", 4) == 0) md_type = MBEDTLS_MD_SHA1;
	else if (len == 3 && memcmp(algo, "md5", 3) == 0) md_type = MBEDTLS_MD_MD5;
	else if (len == 9 && memcmp(algo, "ripemd160", 9) == 0) md_type = MBEDTLS_MD_RIPEMD160;
	else return NULL;

	return mbedtls_md_info_from_type(md_type);
}

/* ===== Initialization ===== */

double msCryptoInit(void) {
	if (ms_crypto_initialized) return 1.0;
	ms_crypto_initialized = 1;
	return 1.0;
}

void msCryptoCleanup(void) {
	ms_crypto_initialized = 0;
}

/* ===== Hashing ===== */

msString msCryptoHashString(msString algorithm, msString data, msString encoding) {
	const mbedtls_md_info_t* md_info = get_md_info(msCStr(algorithm), algorithm.len);
	if (!md_info) return MS_EMPTY_STRING;

	size_t hashLen = mbedtls_md_get_size(md_info);
	uint8_t hash[64]; /* max hash size is 64 bytes (SHA-512) */

	const unsigned char* input = (const unsigned char*)(data.p ? data.p->data : "");
	int ret = mbedtls_md(md_info, input, (size_t)data.len, hash);
	if (ret != 0) return MS_EMPTY_STRING;

	return encode_hash(hash, hashLen, encoding);
}

msString msCryptoHashBuffer(msString algorithm, msString data) {
	const mbedtls_md_info_t* md_info = get_md_info(msCStr(algorithm), algorithm.len);
	if (!md_info) return MS_EMPTY_STRING;

	size_t hashLen = mbedtls_md_get_size(md_info);
	uint8_t hash[64];

	const unsigned char* input = (const unsigned char*)(data.p ? data.p->data : "");
	int ret = mbedtls_md(md_info, input, (size_t)data.len, hash);
	if (ret != 0) return MS_EMPTY_STRING;

	return raw_to_buffer(hash, hashLen);
}

/* ===== HMAC ===== */

msString msCryptoHmacString(msString algorithm, msString key, msString data, msString encoding) {
	const mbedtls_md_info_t* md_info = get_md_info(msCStr(algorithm), algorithm.len);
	if (!md_info) return MS_EMPTY_STRING;

	size_t hashLen = mbedtls_md_get_size(md_info);
	uint8_t hash[64];

	const unsigned char* keyData = (const unsigned char*)(key.p ? key.p->data : "");
	const unsigned char* input = (const unsigned char*)(data.p ? data.p->data : "");

	int ret = mbedtls_md_hmac(md_info, keyData, (size_t)key.len, input, (size_t)data.len, hash);
	if (ret != 0) return MS_EMPTY_STRING;

	return encode_hash(hash, hashLen, encoding);
}

msString msCryptoHmacBuffer(msString algorithm, msString key, msString data) {
	const mbedtls_md_info_t* md_info = get_md_info(msCStr(algorithm), algorithm.len);
	if (!md_info) return MS_EMPTY_STRING;

	size_t hashLen = mbedtls_md_get_size(md_info);
	uint8_t hash[64];

	const unsigned char* keyData = (const unsigned char*)(key.p ? key.p->data : "");
	const unsigned char* input = (const unsigned char*)(data.p ? data.p->data : "");

	int ret = mbedtls_md_hmac(md_info, keyData, (size_t)key.len, input, (size_t)data.len, hash);
	if (ret != 0) return MS_EMPTY_STRING;

	return raw_to_buffer(hash, hashLen);
}

/* ===== Random ===== */

/*
 * OS-level CSPRNG — no mbedTLS dependency.
 * macOS/Linux: /dev/urandom
 * Fallback: arc4random_buf (macOS always has it)
 */

#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__)
#include <stdlib.h> /* arc4random_buf */
#define HAS_ARC4RANDOM 1
#else
#define HAS_ARC4RANDOM 0
#endif

static int fill_random(uint8_t* buf, size_t len) {
#if HAS_ARC4RANDOM
	arc4random_buf(buf, len);
	return 0;
#else
	FILE* f = fopen("/dev/urandom", "rb");
	if (!f) return -1;
	size_t got = fread(buf, 1, len, f);
	fclose(f);
	return (got == len) ? 0 : -1;
#endif
}

msString msCryptoRandomBytes(int64_t size) {
	if (size <= 0) return MS_EMPTY_STRING;

	msStrPayload* p = (msStrPayload*)calloc(1, sizeof(msStrPayload) + size + 1);
	if (!p) return MS_EMPTY_STRING;

	p->cap = size;
	if (fill_random((uint8_t*)p->data, (size_t)size) != 0) {
		free(p);
		return MS_EMPTY_STRING;
	}
	p->data[size] = '\0';

	msString result;
	result.len = size;
	result.p = p;
	return result;
}

double msCryptoRandomInt(double min, double max) {
	if (min >= max) return -1.0;

	int64_t lo = (int64_t)min;
	int64_t hi = (int64_t)max;
	int64_t range = hi - lo;
	if (range <= 0) return -1.0;

	uint64_t r;
	if (fill_random((uint8_t*)&r, sizeof(r)) != 0) return -1.0;

	return (double)(lo + (int64_t)(r % (uint64_t)range));
}

msString msCryptoRandomUuid(void) {
	uint8_t bytes[16];
	if (fill_random(bytes, 16) != 0) return MS_EMPTY_STRING;

	/* RFC 4122 version 4 UUID */
	bytes[6] = (bytes[6] & 0x0F) | 0x40; /* version 4 */
	bytes[8] = (bytes[8] & 0x3F) | 0x80; /* variant 10xx */

	/* Format: 8-4-4-4-12 hex */
	char buf[37];
	snprintf(buf, sizeof(buf),
		"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
		bytes[0], bytes[1], bytes[2], bytes[3],
		bytes[4], bytes[5],
		bytes[6], bytes[7],
		bytes[8], bytes[9],
		bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]);

	return msStringNew(buf, 36);
}

/* ===== Timing-Safe Comparison ===== */

double msCryptoTimingSafeEqual(msString a, msString b) {
	if (a.len != b.len) return 0.0;
	if (a.len == 0) return 1.0;

	const unsigned char* pa = (const unsigned char*)(a.p ? a.p->data : "");
	const unsigned char* pb = (const unsigned char*)(b.p ? b.p->data : "");

	volatile unsigned char diff = 0;
	for (int64_t i = 0; i < a.len; i++) {
		diff |= pa[i] ^ pb[i];
	}
	return (diff == 0) ? 1.0 : 0.0;
}

/* ===== Streaming Hash Context ===== */

struct msCryptoHashCtx {
	mbedtls_md_context_t ctx;
	const mbedtls_md_info_t* md_info;
	int valid;
};

msCryptoHashCtx* msCryptoHashInit(msString algorithm) {
	const mbedtls_md_info_t* md_info = get_md_info(msCStr(algorithm), algorithm.len);
	if (!md_info) return NULL;

	msCryptoHashCtx* ctx = (msCryptoHashCtx*)calloc(1, sizeof(msCryptoHashCtx));
	if (!ctx) return NULL;

	mbedtls_md_init(&ctx->ctx);
	if (mbedtls_md_setup(&ctx->ctx, md_info, 0) != 0) {
		free(ctx);
		return NULL;
	}
	if (mbedtls_md_starts(&ctx->ctx) != 0) {
		mbedtls_md_free(&ctx->ctx);
		free(ctx);
		return NULL;
	}

	ctx->md_info = md_info;
	ctx->valid = 1;
	return ctx;
}

void msCryptoHashUpdate(msCryptoHashCtx* ctx, msString data) {
	if (!ctx || !ctx->valid) return;
	const unsigned char* input = (const unsigned char*)(data.p ? data.p->data : "");
	mbedtls_md_update(&ctx->ctx, input, (size_t)data.len);
}

msString msCryptoHashFinal(msCryptoHashCtx* ctx, msString encoding) {
	if (!ctx || !ctx->valid) return MS_EMPTY_STRING;

	size_t hashLen = mbedtls_md_get_size(ctx->md_info);
	uint8_t hash[64];

	int ret = mbedtls_md_finish(&ctx->ctx, hash);
	mbedtls_md_free(&ctx->ctx);
	ctx->valid = 0;

	msString result = (ret == 0) ? encode_hash(hash, hashLen, encoding) : MS_EMPTY_STRING;

	free(ctx);
	return result;
}

msString msCryptoHashFinalBuffer(msCryptoHashCtx* ctx) {
	if (!ctx || !ctx->valid) return MS_EMPTY_STRING;

	size_t hashLen = mbedtls_md_get_size(ctx->md_info);
	uint8_t hash[64];

	int ret = mbedtls_md_finish(&ctx->ctx, hash);
	mbedtls_md_free(&ctx->ctx);
	ctx->valid = 0;

	msString result = (ret == 0) ? raw_to_buffer(hash, hashLen) : MS_EMPTY_STRING;

	free(ctx);
	return result;
}

void msCryptoHashFree(msCryptoHashCtx* ctx) {
	if (!ctx) return;
	if (ctx->valid) {
		mbedtls_md_free(&ctx->ctx);
		ctx->valid = 0;
	}
	free(ctx);
}

/* ===== Streaming HMAC Context ===== */

struct msCryptoHmacCtx {
	mbedtls_md_context_t ctx;
	const mbedtls_md_info_t* md_info;
	int valid;
};

msCryptoHmacCtx* msCryptoHmacInit(msString algorithm, msString key) {
	const mbedtls_md_info_t* md_info = get_md_info(msCStr(algorithm), algorithm.len);
	if (!md_info) return NULL;

	msCryptoHmacCtx* ctx = (msCryptoHmacCtx*)calloc(1, sizeof(msCryptoHmacCtx));
	if (!ctx) return NULL;

	mbedtls_md_init(&ctx->ctx);
	if (mbedtls_md_setup(&ctx->ctx, md_info, 1) != 0) { /* 1 = HMAC mode */
		free(ctx);
		return NULL;
	}

	const unsigned char* keyData = (const unsigned char*)(key.p ? key.p->data : "");
	if (mbedtls_md_hmac_starts(&ctx->ctx, keyData, (size_t)key.len) != 0) {
		mbedtls_md_free(&ctx->ctx);
		free(ctx);
		return NULL;
	}

	ctx->md_info = md_info;
	ctx->valid = 1;
	return ctx;
}

void msCryptoHmacUpdate(msCryptoHmacCtx* ctx, msString data) {
	if (!ctx || !ctx->valid) return;
	const unsigned char* input = (const unsigned char*)(data.p ? data.p->data : "");
	mbedtls_md_hmac_update(&ctx->ctx, input, (size_t)data.len);
}

msString msCryptoHmacFinal(msCryptoHmacCtx* ctx, msString encoding) {
	if (!ctx || !ctx->valid) return MS_EMPTY_STRING;

	size_t hashLen = mbedtls_md_get_size(ctx->md_info);
	uint8_t hash[64];

	int ret = mbedtls_md_hmac_finish(&ctx->ctx, hash);
	mbedtls_md_free(&ctx->ctx);
	ctx->valid = 0;

	msString result = (ret == 0) ? encode_hash(hash, hashLen, encoding) : MS_EMPTY_STRING;

	free(ctx);
	return result;
}

msString msCryptoHmacFinalBuffer(msCryptoHmacCtx* ctx) {
	if (!ctx || !ctx->valid) return MS_EMPTY_STRING;

	size_t hashLen = mbedtls_md_get_size(ctx->md_info);
	uint8_t hash[64];

	int ret = mbedtls_md_hmac_finish(&ctx->ctx, hash);
	mbedtls_md_free(&ctx->ctx);
	ctx->valid = 0;

	msString result = (ret == 0) ? raw_to_buffer(hash, hashLen) : MS_EMPTY_STRING;

	free(ctx);
	return result;
}

void msCryptoHmacFree(msCryptoHmacCtx* ctx) {
	if (!ctx) return;
	if (ctx->valid) {
		mbedtls_md_free(&ctx->ctx);
		ctx->valid = 0;
	}
	free(ctx);
}

/* ===== Utility ===== */

double msCryptoIsHashSupported(msString algorithm) {
	const mbedtls_md_info_t* info = get_md_info(msCStr(algorithm), algorithm.len);
	return info ? 1.0 : 0.0;
}
