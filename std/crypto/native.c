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
	const char* enc = msStringToCString(encoding);
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
	const mbedtls_md_info_t* md_info = get_md_info(msStringToCString(algorithm), algorithm.len);
	if (!md_info) return MS_EMPTY_STRING;

	size_t hashLen = mbedtls_md_get_size(md_info);
	uint8_t hash[64]; /* max hash size is 64 bytes (SHA-512) */

	const unsigned char* input = (const unsigned char*)(data.p ? data.p->data : "");
	int ret = mbedtls_md(md_info, input, (size_t)data.len, hash);
	if (ret != 0) return MS_EMPTY_STRING;

	return encode_hash(hash, hashLen, encoding);
}

msString msCryptoHashBuffer(msString algorithm, msString data) {
	const mbedtls_md_info_t* md_info = get_md_info(msStringToCString(algorithm), algorithm.len);
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
	const mbedtls_md_info_t* md_info = get_md_info(msStringToCString(algorithm), algorithm.len);
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
	const mbedtls_md_info_t* md_info = get_md_info(msStringToCString(algorithm), algorithm.len);
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
	const mbedtls_md_info_t* md_info = get_md_info(msStringToCString(algorithm), algorithm.len);
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
	const mbedtls_md_info_t* md_info = get_md_info(msStringToCString(algorithm), algorithm.len);
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
	const mbedtls_md_info_t* info = get_md_info(msStringToCString(algorithm), algorithm.len);
	return info ? 1.0 : 0.0;
}

/* ===== Decode Helpers ===== */

static int hex_digit(char c) {
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

static msString decode_from_hex(const char* hex, int64_t len) {
	if (len == 0 || (len % 2) != 0) return MS_EMPTY_STRING;
	int64_t out_len = len / 2;
	char* buf = (char*)malloc((size_t)out_len);
	if (!buf) return MS_EMPTY_STRING;
	for (int64_t i = 0; i < out_len; i++) {
		int hi = hex_digit(hex[i * 2]);
		int lo = hex_digit(hex[i * 2 + 1]);
		if (hi < 0 || lo < 0) { free(buf); return MS_EMPTY_STRING; }
		buf[i] = (char)((hi << 4) | lo);
	}
	msString result = msStringNew(buf, out_len);
	free(buf);
	return result;
}

static int base64_val(char c) {
	if (c >= 'A' && c <= 'Z') return c - 'A';
	if (c >= 'a' && c <= 'z') return c - 'a' + 26;
	if (c >= '0' && c <= '9') return c - '0' + 52;
	if (c == '+') return 62;
	if (c == '/') return 63;
	return -1;
}

static msString decode_from_base64(const char* b64, int64_t len) {
	if (len == 0 || (len % 4) != 0) return MS_EMPTY_STRING;
	int64_t out_len = (len / 4) * 3;
	if (len >= 1 && b64[len - 1] == '=') out_len--;
	if (len >= 2 && b64[len - 2] == '=') out_len--;
	char* buf = (char*)malloc((size_t)out_len);
	if (!buf) return MS_EMPTY_STRING;
	int64_t j = 0;
	for (int64_t i = 0; i < len; i += 4) {
		int a = base64_val(b64[i]);
		int b = base64_val(b64[i + 1]);
		int c = b64[i + 2] == '=' ? 0 : base64_val(b64[i + 2]);
		int d = b64[i + 3] == '=' ? 0 : base64_val(b64[i + 3]);
		if (a < 0 || b < 0 || c < 0 || d < 0) { free(buf); return MS_EMPTY_STRING; }
		uint32_t triple = ((uint32_t)a << 18) | ((uint32_t)b << 12) | ((uint32_t)c << 6) | (uint32_t)d;
		if (j < out_len) buf[j++] = (char)((triple >> 16) & 0xff);
		if (j < out_len) buf[j++] = (char)((triple >> 8) & 0xff);
		if (j < out_len) buf[j++] = (char)(triple & 0xff);
	}
	msString result = msStringNew(buf, out_len);
	free(buf);
	return result;
}

/* ===== Encoding Public API ===== */

msString msCryptoToHex(msString data) {
	return encode_to_hex((const uint8_t*)msStringToCString(data), (size_t)data.len);
}

msString msCryptoFromHex(msString hex) {
	return decode_from_hex(msStringToCString(hex), hex.len);
}

msString msCryptoToBase64(msString data) {
	return encode_to_base64((const uint8_t*)msStringToCString(data), (size_t)data.len);
}

msString msCryptoFromBase64(msString b64) {
	return decode_from_base64(msStringToCString(b64), b64.len);
}

/* ===== PBKDF2 (RFC 8018 — manual implementation using MD HMAC) ===== */

static void pbkdf2_hmac(
	const mbedtls_md_info_t* md_info,
	const uint8_t* password, size_t password_len,
	const uint8_t* salt, size_t salt_len,
	uint32_t iterations,
	uint8_t* output, size_t output_len
) {
	size_t hash_len = mbedtls_md_get_size(md_info);
	uint8_t* U = (uint8_t*)malloc(hash_len);
	uint8_t* T = (uint8_t*)malloc(hash_len);
	uint8_t* salt_block = (uint8_t*)malloc(salt_len + 4);
	if (!U || !T || !salt_block) { free(U); free(T); free(salt_block); return; }
	memcpy(salt_block, salt, salt_len);
	size_t output_pos = 0;
	uint32_t block_num = 1;
	while (output_pos < output_len) {
		salt_block[salt_len + 0] = (block_num >> 24) & 0xff;
		salt_block[salt_len + 1] = (block_num >> 16) & 0xff;
		salt_block[salt_len + 2] = (block_num >> 8) & 0xff;
		salt_block[salt_len + 3] = block_num & 0xff;
		mbedtls_md_hmac(md_info, password, password_len, salt_block, salt_len + 4, U);
		memcpy(T, U, hash_len);
		for (uint32_t j = 1; j < iterations; j++) {
			mbedtls_md_hmac(md_info, password, password_len, U, hash_len, U);
			for (size_t k = 0; k < hash_len; k++) T[k] ^= U[k];
		}
		size_t copy_len = output_len - output_pos;
		if (copy_len > hash_len) copy_len = hash_len;
		memcpy(output + output_pos, T, copy_len);
		output_pos += copy_len;
		block_num++;
	}
	free(U); free(T); free(salt_block);
}

msString msCryptoPbkdf2(msString password, msString salt,
                        int32_t iterations, int32_t keyLength, msString digest) {
	const mbedtls_md_info_t* md_info = get_md_info(msStringToCString(digest), digest.len);
	if (md_info == NULL || keyLength <= 0) return MS_EMPTY_STRING;
	uint8_t* output = (uint8_t*)malloc((size_t)keyLength);
	if (!output) return MS_EMPTY_STRING;
	pbkdf2_hmac(md_info,
		(const uint8_t*)msStringToCString(password), (size_t)password.len,
		(const uint8_t*)msStringToCString(salt), (size_t)salt.len,
		(uint32_t)iterations, output, (size_t)keyLength);
	msString result = msStringNew((const char*)output, (int64_t)keyLength);
	free(output);
	return result;
}

/* ===== HKDF (RFC 5869 — manual implementation using MD HMAC) ===== */

static msString hkdf_extract(const mbedtls_md_info_t* md_info,
	const uint8_t* salt, size_t salt_len, const uint8_t* ikm, size_t ikm_len) {
	size_t hash_size = mbedtls_md_get_size(md_info);
	uint8_t prk[64];
	uint8_t zero_salt[64] = {0};
	const uint8_t* actual_salt = salt_len > 0 ? salt : zero_salt;
	size_t actual_salt_len = salt_len > 0 ? salt_len : hash_size;
	int ret = mbedtls_md_hmac(md_info, actual_salt, actual_salt_len, ikm, ikm_len, prk);
	if (ret != 0) return MS_EMPTY_STRING;
	return msStringNew((const char*)prk, (int64_t)hash_size);
}

static msString hkdf_expand(const mbedtls_md_info_t* md_info,
	const uint8_t* prk, size_t prk_len, const uint8_t* info, size_t info_len, size_t length) {
	size_t hash_size = mbedtls_md_get_size(md_info);
	if (length > 255 * hash_size) return MS_EMPTY_STRING;
	uint8_t* okm = (uint8_t*)malloc(length);
	if (!okm) return MS_EMPTY_STRING;
	uint8_t T[64] = {0};
	size_t T_len = 0;
	size_t okm_offset = 0;
	uint8_t counter = 1;
	while (okm_offset < length) {
		size_t input_len = T_len + info_len + 1;
		uint8_t* input = (uint8_t*)malloc(input_len);
		if (!input) { free(okm); return MS_EMPTY_STRING; }
		size_t pos = 0;
		if (T_len > 0) { memcpy(input + pos, T, T_len); pos += T_len; }
		if (info_len > 0) { memcpy(input + pos, info, info_len); pos += info_len; }
		input[pos] = counter;
		int ret = mbedtls_md_hmac(md_info, prk, prk_len, input, input_len, T);
		free(input);
		if (ret != 0) { free(okm); return MS_EMPTY_STRING; }
		T_len = hash_size;
		size_t copy_len = length - okm_offset;
		if (copy_len > hash_size) copy_len = hash_size;
		memcpy(okm + okm_offset, T, copy_len);
		okm_offset += copy_len;
		counter++;
	}
	msString result = msStringNew((const char*)okm, (int64_t)length);
	free(okm);
	return result;
}

msString msCryptoHkdf(msString algorithm, msString ikm, msString salt,
                      msString info, int32_t length) {
	const mbedtls_md_info_t* md_info = get_md_info(msStringToCString(algorithm), algorithm.len);
	if (md_info == NULL || length <= 0) return MS_EMPTY_STRING;
	msString prk = hkdf_extract(md_info,
		(const uint8_t*)msStringToCString(salt), (size_t)salt.len,
		(const uint8_t*)msStringToCString(ikm), (size_t)ikm.len);
	if (prk.len == 0) return MS_EMPTY_STRING;
	msString result = hkdf_expand(md_info,
		(const uint8_t*)msStringToCString(prk), (size_t)prk.len,
		(const uint8_t*)msStringToCString(info), (size_t)info.len, (size_t)length);
	msStringDestroy(prk);
	return result;
}
