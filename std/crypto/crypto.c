/**
 * MetaScript Crypto Runtime (C Backend)
 *
 * Phase 1: Hash, HMAC, Random, PBKDF2, HKDF, Encoding, Timing-Safe.
 * Uses mbedTLS 4.0 legacy MD API for hashing and HMAC.
 */

#include "native.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

/* --- mbedTLS feature macros (define before headers) --- */
#ifndef MBEDTLS_DECLARE_PRIVATE_IDENTIFIERS
#define MBEDTLS_DECLARE_PRIVATE_IDENTIFIERS
#endif
#ifndef MBEDTLS_PLATFORM_C
#define MBEDTLS_PLATFORM_C
#endif
#ifndef MBEDTLS_HAVE_ASM
#define MBEDTLS_HAVE_ASM
#endif
#ifndef MBEDTLS_HAVE_TIME
#define MBEDTLS_HAVE_TIME
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

/* mbedTLS headers */
#include "mbedtls/md.h"
#include "mbedtls/platform_util.h"

/* Platform-specific random */
#ifdef __APPLE__
#include <stdlib.h>  /* arc4random_buf */
#elif defined(__linux__)
#include <sys/random.h>  /* getrandom */
#else
#include <time.h>
#endif

/* ========================================================================= */
/* Algorithm Mapping                                                          */
/* ========================================================================= */

static const mbedtls_md_info_t* get_md_info(const char* algo, int64_t len) {
    mbedtls_md_type_t md_type = MBEDTLS_MD_NONE;

    if (len == 6 && memcmp(algo, "sha256", 6) == 0) md_type = MBEDTLS_MD_SHA256;
    else if (len == 6 && memcmp(algo, "sha512", 6) == 0) md_type = MBEDTLS_MD_SHA512;
    else if (len == 6 && memcmp(algo, "sha384", 6) == 0) md_type = MBEDTLS_MD_SHA384;
    else if (len == 6 && memcmp(algo, "sha224", 6) == 0) md_type = MBEDTLS_MD_SHA224;
    else if (len == 8 && memcmp(algo, "sha3-256", 8) == 0) md_type = MBEDTLS_MD_SHA3_256;
    else if (len == 8 && memcmp(algo, "sha3-384", 8) == 0) md_type = MBEDTLS_MD_SHA3_384;
    else if (len == 8 && memcmp(algo, "sha3-512", 8) == 0) md_type = MBEDTLS_MD_SHA3_512;
    else if (len == 4 && memcmp(algo, "sha1", 4) == 0) md_type = MBEDTLS_MD_SHA1;
    else if (len == 3 && memcmp(algo, "md5", 3) == 0) md_type = MBEDTLS_MD_MD5;
    else if (len == 9 && memcmp(algo, "ripemd160", 9) == 0) md_type = MBEDTLS_MD_RIPEMD160;
    else return NULL;

    return mbedtls_md_info_from_type(md_type);
}

/* ========================================================================= */
/* Encoding Helpers                                                           */
/* ========================================================================= */

static const char hex_chars[] = "0123456789abcdef";

static msString encode_to_hex(const uint8_t* data, size_t len) {
    if (len == 0) return MS_EMPTY_STRING;

    size_t out_len = len * 2;
    char* buf = (char*)malloc(out_len);
    if (!buf) return MS_EMPTY_STRING;

    for (size_t i = 0; i < len; i++) {
        buf[i * 2]     = hex_chars[(data[i] >> 4) & 0x0f];
        buf[i * 2 + 1] = hex_chars[data[i] & 0x0f];
    }

    msString result = msStringNew(buf, (int64_t)out_len);
    free(buf);
    return result;
}

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

static const char base64_table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static msString encode_to_base64(const uint8_t* data, size_t len) {
    if (len == 0) return MS_EMPTY_STRING;

    size_t out_len = ((len + 2) / 3) * 4;
    char* buf = (char*)malloc(out_len);
    if (!buf) return MS_EMPTY_STRING;

    size_t j = 0;
    for (size_t i = 0; i < len; i += 3) {
        uint32_t a = data[i];
        uint32_t b = (i + 1 < len) ? data[i + 1] : 0;
        uint32_t c = (i + 2 < len) ? data[i + 2] : 0;
        uint32_t triple = (a << 16) | (b << 8) | c;

        buf[j++] = base64_table[(triple >> 18) & 0x3f];
        buf[j++] = base64_table[(triple >> 12) & 0x3f];
        buf[j++] = (i + 1 < len) ? base64_table[(triple >> 6) & 0x3f] : '=';
        buf[j++] = (i + 2 < len) ? base64_table[triple & 0x3f] : '=';
    }

    msString result = msStringNew(buf, (int64_t)out_len);
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

static msString encode_buffer(const uint8_t* data, size_t len, msString encoding) {
    const char* enc = msCStr(encoding);

    if (encoding.len == 3 && memcmp(enc, "hex", 3) == 0) {
        return encode_to_hex(data, len);
    }
    if (encoding.len == 6 && memcmp(enc, "base64", 6) == 0) {
        return encode_to_base64(data, len);
    }
    if (encoding.len == 6 && memcmp(enc, "binary", 6) == 0) {
        return msStringNew((const char*)data, (int64_t)len);
    }
    /* Default: hex */
    return encode_to_hex(data, len);
}

/* ========================================================================= */
/* Random                                                                     */
/* ========================================================================= */

static void fill_random_bytes(uint8_t* buf, size_t len) {
#ifdef __APPLE__
    arc4random_buf(buf, len);
#elif defined(__linux__)
    /* getrandom may return short reads; loop until filled */
    size_t done = 0;
    while (done < len) {
        ssize_t ret = getrandom(buf + done, len - done, 0);
        if (ret < 0) break;
        done += (size_t)ret;
    }
#else
    /* Fallback — NOT cryptographically secure */
    static int seeded = 0;
    if (!seeded) { srand((unsigned)time(NULL)); seeded = 1; }
    for (size_t i = 0; i < len; i++) buf[i] = (uint8_t)(rand() & 0xff);
#endif
}

/* ========================================================================= */
/* Init                                                                       */
/* ========================================================================= */

static int crypto_initialized = 0;

double msCryptoInit(void) {
    if (crypto_initialized) return 1.0;
    crypto_initialized = 1;
    return 1.0;
}

void msCryptoCleanup(void) {
    crypto_initialized = 0;
}

/* ========================================================================= */
/* Hash                                                                       */
/* ========================================================================= */

msString msCryptoHash(msString algorithm, msString data, msString encoding) {
    const mbedtls_md_info_t* md_info = get_md_info(msCStr(algorithm), algorithm.len);
    if (md_info == NULL) return MS_EMPTY_STRING;

    size_t hash_size = mbedtls_md_get_size(md_info);
    uint8_t hash[64]; /* max hash size (SHA-512) */

    int ret = mbedtls_md(
        md_info,
        (const uint8_t*)msCStr(data), (size_t)data.len,
        hash
    );

    if (ret != 0) return MS_EMPTY_STRING;

    return encode_buffer(hash, hash_size, encoding);
}

/* ========================================================================= */
/* HMAC                                                                       */
/* ========================================================================= */

msString msCryptoHmac(msString algorithm, msString key, msString data, msString encoding) {
    const mbedtls_md_info_t* md_info = get_md_info(msCStr(algorithm), algorithm.len);
    if (md_info == NULL) return MS_EMPTY_STRING;

    size_t hash_size = mbedtls_md_get_size(md_info);
    uint8_t hmac[64];

    int ret = mbedtls_md_hmac(
        md_info,
        (const uint8_t*)msCStr(key), (size_t)key.len,
        (const uint8_t*)msCStr(data), (size_t)data.len,
        hmac
    );

    if (ret != 0) return MS_EMPTY_STRING;

    return encode_buffer(hmac, hash_size, encoding);
}

/* ========================================================================= */
/* Random Functions                                                           */
/* ========================================================================= */

msString msCryptoRandomBytes(int32_t size) {
    if (size <= 0) return MS_EMPTY_STRING;

    uint8_t* buf = (uint8_t*)malloc((size_t)size);
    if (!buf) return MS_EMPTY_STRING;

    fill_random_bytes(buf, (size_t)size);

    msString result = msStringNew((const char*)buf, (int64_t)size);
    free(buf);
    return result;
}

int32_t msCryptoRandomInt(int32_t min, int32_t max) {
    if (min >= max) return min;

    uint32_t range = (uint32_t)(max - min);
    uint8_t bytes[4];
    fill_random_bytes(bytes, 4);

    uint32_t val = ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
                   ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];

    return min + (int32_t)(val % range);
}

msString msCryptoRandomUUID(void) {
    uint8_t bytes[16];
    fill_random_bytes(bytes, 16);

    /* UUID v4: set version (4) and variant (10xx) */
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    char uuid[37];
    snprintf(uuid, sizeof(uuid),
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]);

    return msStringNew(uuid, 36);
}

/* ========================================================================= */
/* PBKDF2 (manual implementation using MD HMAC)                               */
/* ========================================================================= */

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

    if (!U || !T || !salt_block) {
        free(U); free(T); free(salt_block);
        return;
    }

    memcpy(salt_block, salt, salt_len);

    size_t output_pos = 0;
    uint32_t block_num = 1;

    while (output_pos < output_len) {
        /* INT(i) - big endian block number */
        salt_block[salt_len + 0] = (block_num >> 24) & 0xff;
        salt_block[salt_len + 1] = (block_num >> 16) & 0xff;
        salt_block[salt_len + 2] = (block_num >> 8) & 0xff;
        salt_block[salt_len + 3] = block_num & 0xff;

        /* U1 = PRF(Password, Salt || INT(i)) */
        mbedtls_md_hmac(md_info, password, password_len, salt_block, salt_len + 4, U);
        memcpy(T, U, hash_len);

        /* U2 ... Uc */
        for (uint32_t j = 1; j < iterations; j++) {
            mbedtls_md_hmac(md_info, password, password_len, U, hash_len, U);
            for (size_t k = 0; k < hash_len; k++) {
                T[k] ^= U[k];
            }
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
    const mbedtls_md_info_t* md_info = get_md_info(msCStr(digest), digest.len);
    if (md_info == NULL) return MS_EMPTY_STRING;
    if (keyLength <= 0) return MS_EMPTY_STRING;

    uint8_t* output = (uint8_t*)malloc((size_t)keyLength);
    if (!output) return MS_EMPTY_STRING;

    pbkdf2_hmac(
        md_info,
        (const uint8_t*)msCStr(password), (size_t)password.len,
        (const uint8_t*)msCStr(salt), (size_t)salt.len,
        (uint32_t)iterations,
        output, (size_t)keyLength
    );

    msString result = msStringNew((const char*)output, (int64_t)keyLength);
    free(output);
    return result;
}

/* ========================================================================= */
/* HKDF (RFC 5869 — manual implementation using MD HMAC)                      */
/* ========================================================================= */

static msString hkdf_extract(
    const mbedtls_md_info_t* md_info,
    const uint8_t* salt, size_t salt_len,
    const uint8_t* ikm, size_t ikm_len
) {
    size_t hash_size = mbedtls_md_get_size(md_info);
    uint8_t prk[64];

    /* Empty salt → hash-length zeros (RFC 5869 §2.2) */
    uint8_t zero_salt[64] = {0};
    const uint8_t* actual_salt = salt_len > 0 ? salt : zero_salt;
    size_t actual_salt_len = salt_len > 0 ? salt_len : hash_size;

    int ret = mbedtls_md_hmac(md_info, actual_salt, actual_salt_len, ikm, ikm_len, prk);
    if (ret != 0) return MS_EMPTY_STRING;

    return msStringNew((const char*)prk, (int64_t)hash_size);
}

static msString hkdf_expand(
    const mbedtls_md_info_t* md_info,
    const uint8_t* prk, size_t prk_len,
    const uint8_t* info, size_t info_len,
    size_t length
) {
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
    const mbedtls_md_info_t* md_info = get_md_info(msCStr(algorithm), algorithm.len);
    if (md_info == NULL) return MS_EMPTY_STRING;
    if (length <= 0) return MS_EMPTY_STRING;

    /* Extract */
    msString prk = hkdf_extract(
        md_info,
        (const uint8_t*)msCStr(salt), (size_t)salt.len,
        (const uint8_t*)msCStr(ikm), (size_t)ikm.len
    );
    if (prk.len == 0) return MS_EMPTY_STRING;

    /* Expand */
    msString result = hkdf_expand(
        md_info,
        (const uint8_t*)msCStr(prk), (size_t)prk.len,
        (const uint8_t*)msCStr(info), (size_t)info.len,
        (size_t)length
    );

    /* prk is a fresh allocation — free it */
    msStringDestroy(prk);

    return result;
}

/* ========================================================================= */
/* Encoding (public API)                                                      */
/* ========================================================================= */

msString msCryptoToHex(msString data) {
    return encode_to_hex((const uint8_t*)msCStr(data), (size_t)data.len);
}

msString msCryptoFromHex(msString hex) {
    return decode_from_hex(msCStr(hex), hex.len);
}

msString msCryptoToBase64(msString data) {
    return encode_to_base64((const uint8_t*)msCStr(data), (size_t)data.len);
}

msString msCryptoFromBase64(msString b64) {
    return decode_from_base64(msCStr(b64), b64.len);
}

/* ========================================================================= */
/* Timing-Safe Comparison                                                     */
/* ========================================================================= */

double msCryptoTimingSafeEqual(msString a, msString b) {
    if (a.len != b.len) return 0.0;
    if (a.len == 0) return 1.0;

    const uint8_t* pa = (const uint8_t*)msCStr(a);
    const uint8_t* pb = (const uint8_t*)msCStr(b);

    volatile uint8_t diff = 0;
    for (int64_t i = 0; i < a.len; i++) {
        diff |= pa[i] ^ pb[i];
    }

    return diff == 0 ? 1.0 : 0.0;
}
