/*
 * MetaScript AES Runtime — AES-GCM and AES-CBC on the vendored mbedTLS
 */

#include "runtime/crypto/ciphers/aes.h"
#include "runtime/crypto/ciphers/aesGcmHw.h"
#include "runtime/core/system.h"
#include "runtime/crypto/randomFill.h"
#include <stdlib.h>
#include <string.h>

#include "mbedtls/private/aes.h"
#include "mbedtls/private/gcm.h"
#include "mbedtls/constant_time.h"
#include "mbedtls/platform_util.h"

#define GCM_NONCE_SIZE 12
#define GCM_TAG_SIZE   16

/* One key's bytes, owned by a std/crypto/aes AesKey; the handle given to MetaScript is its address. */
typedef struct {
	size_t len;
	uint8_t bytes[32];
} msAesKey;

static int64_t liveKeys = 0;

static const msAesKey* keyOf(int64_t handle) {
	return (const msAesKey*)(uintptr_t)handle;
}

int64_t msCryptoAesKeyNew(msString raw) {
	if (raw.len != 16 && raw.len != 32) return 0;
	msAesKey* key = (msAesKey*)calloc(1, sizeof(msAesKey));
	if (key == NULL) return 0;
	key->len = (size_t)raw.len;
	memcpy(key->bytes, msStringToCString(raw), key->len);
	__atomic_add_fetch(&liveKeys, 1, __ATOMIC_RELAXED);
	return (int64_t)(uintptr_t)key;
}

/* 0 for a size other than 16 or 32, -1 when the OS random source failed. */
int64_t msCryptoAesKeyGenerate(int32_t byteLength) {
	if (byteLength != 16 && byteLength != 32) return 0;
	msAesKey* key = (msAesKey*)calloc(1, sizeof(msAesKey));
	if (key == NULL) return 0;
	key->len = (size_t)byteLength;
	if (ms_random_fill(key->bytes, key->len) != 0) {
		mbedtls_platform_zeroize(key, sizeof(msAesKey));
		free(key);
		return -1;
	}
	__atomic_add_fetch(&liveKeys, 1, __ATOMIC_RELAXED);
	return (int64_t)(uintptr_t)key;
}

msString msCryptoAesKeyExport(int64_t handle) {
	const msAesKey* key = keyOf(handle);
	if (key == NULL) return MS_EMPTY_STRING;
	return msStringNew((const char*)key->bytes, (int64_t)key->len);
}

void msCryptoAesKeyFree(int64_t handle) {
	msAesKey* key = (msAesKey*)(uintptr_t)handle;
	if (key == NULL) return;
	mbedtls_platform_zeroize(key, sizeof(msAesKey));
	free(key);
	__atomic_sub_fetch(&liveKeys, 1, __ATOMIC_RELAXED);
}

int64_t msCryptoAesKeysLive(void) {
	return __atomic_load_n(&liveKeys, __ATOMIC_RELAXED);
}

/* Constant time over the last block: a pad byte of 1..16 repeated that many times. Returns the
 * plain length, or -1 for a bad padding. */
static int64_t removePkcs7Padding(const uint8_t* data, size_t dataLen) {
	uint32_t pad = data[dataLen - 1];
	uint32_t bad = ((pad - 1) >> 31) | ((16 - pad) >> 31);
	for (uint32_t i = 0; i < 16; i++) {
		uint32_t inPad = ((i - pad) >> 31) & 1;
		bad |= (0u - inPad) & (data[dataLen - 1 - i] ^ pad);
	}
	return bad != 0 ? -1 : (int64_t)(dataLen - pad);
}

/* ===== AES-GCM ===== */

/* The SP 800-38D limits mbedtls gcm.c enforces (update: total 2^36 - 32 bytes; update_ad: AAD under
 * 2^61 bytes), checked before dispatch so the hardware and the generic path answer alike. */
static int gcmLengthsOk(uint64_t aadLen, uint64_t dataLen) {
	return dataLen <= 0xFFFFFFFE0ull && (aadLen >> 61) == 0;
}

/* Hardware path: 1 done, 0 refused (open: tag mismatch, out zeroed), -1 unavailable, use the generic gcm. */
static int sealHw(const msAesKey* key, const uint8_t* iv, msString aad, msString plainText, uint8_t* out) {
	mbedtls_aes_context aes;
	mbedtls_aes_init(&aes);
	uint8_t tag[16];
	int done = mbedtls_aes_setkey_enc(&aes, (const uint8_t*)key->bytes, (unsigned int)key->len * 8) == 0
		&& msAesGcmHw(&aes, iv, (const uint8_t*)msStringToCString(aad), (size_t)aad.len,
			(const uint8_t*)msStringToCString(plainText), (size_t)plainText.len, out + GCM_NONCE_SIZE, tag, 0);
	mbedtls_aes_free(&aes);
	if (done) memcpy(out + GCM_NONCE_SIZE + plainText.len, tag, GCM_TAG_SIZE);
	return done ? 1 : -1;
}

static int openHw(const msAesKey* key, msString aad, const uint8_t* data, size_t ctLen, uint8_t* out) {
	mbedtls_aes_context aes;
	mbedtls_aes_init(&aes);
	uint8_t tag[16];
	int done = mbedtls_aes_setkey_enc(&aes, (const uint8_t*)key->bytes, (unsigned int)key->len * 8) == 0
		&& msAesGcmHw(&aes, data, (const uint8_t*)msStringToCString(aad), (size_t)aad.len,
			data + GCM_NONCE_SIZE, ctLen, out, tag, 1);
	mbedtls_aes_free(&aes);
	if (!done) return -1;
	if (mbedtls_ct_memcmp(tag, data + GCM_NONCE_SIZE + ctLen, GCM_TAG_SIZE) == 0) return 1;
	mbedtls_platform_zeroize(out, ctLen);
	return 0;
}

/* out already holds the nonce in its first 12 bytes. */
static int64_t sealWithNonceInOut(const msAesKey* key, msString plainText, msString aad, uint8_t* out) {
	if (key == NULL || !gcmLengthsOk((uint64_t)aad.len, (uint64_t)plainText.len)) return 0;
	size_t ptLen = (size_t)plainText.len;
	if (sealHw(key, out, aad, plainText, out) == 1) return 1;

	mbedtls_gcm_context gcm;
	mbedtls_gcm_init(&gcm);
	int ok = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, (const uint8_t*)key->bytes, (unsigned int)key->len * 8) == 0
		&& mbedtls_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_ENCRYPT, ptLen, out, GCM_NONCE_SIZE,
			(const uint8_t*)msStringToCString(aad), (size_t)aad.len,
			(const uint8_t*)msStringToCString(plainText), out + GCM_NONCE_SIZE,
			GCM_TAG_SIZE, out + GCM_NONCE_SIZE + ptLen) == 0;
	mbedtls_gcm_free(&gcm);
	return ok ? 1 : 0;
}

/* Layout: nonce(12) || cipherText || tag(16) */
int64_t msCryptoAesSealInto(int64_t keyHandle, msString plainText, msString aad, uint8_t* out) {
	const msAesKey* key = keyOf(keyHandle);
	if (key == NULL || !gcmLengthsOk((uint64_t)aad.len, (uint64_t)plainText.len)) return 0;
	if (ms_random_fill(out, GCM_NONCE_SIZE) != 0) return -1;
	return sealWithNonceInOut(key, plainText, aad, out);
}

int64_t msCryptoAesSealWithNonceInto(int64_t keyHandle, msString nonce, msString plainText, msString aad, uint8_t* out) {
	const msAesKey* key = keyOf(keyHandle);
	if (nonce.len != GCM_NONCE_SIZE) return 0;
	memcpy(out, msStringToCString(nonce), GCM_NONCE_SIZE);
	return sealWithNonceInOut(key, plainText, aad, out);
}

int64_t msCryptoAesOpenInto(int64_t keyHandle, msString sealed, msString aad, uint8_t* out) {
	const msAesKey* key = keyOf(keyHandle);
	if (key == NULL) return 0;
	if (sealed.len < GCM_NONCE_SIZE + GCM_TAG_SIZE) return 0;

	const uint8_t* data = (const uint8_t*)msStringToCString(sealed);
	size_t ctLen = (size_t)sealed.len - GCM_NONCE_SIZE - GCM_TAG_SIZE;
	if (!gcmLengthsOk((uint64_t)aad.len, (uint64_t)ctLen)) return 0;
	uint8_t none = 0;
	if (out == NULL) out = &none;
	int hw = openHw(key, aad, data, ctLen, out);
	if (hw >= 0) return hw;

	mbedtls_gcm_context gcm;
	mbedtls_gcm_init(&gcm);
	int ok = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, (const uint8_t*)key->bytes, (unsigned int)key->len * 8) == 0
		&& mbedtls_gcm_auth_decrypt(&gcm, ctLen, data, GCM_NONCE_SIZE,
			(const uint8_t*)msStringToCString(aad), (size_t)aad.len,
			data + GCM_NONCE_SIZE + ctLen, GCM_TAG_SIZE,
			data + GCM_NONCE_SIZE, out) == 0;
	mbedtls_gcm_free(&gcm);
	return ok ? 1 : 0;
}

/* ===== AES-CBC ===== */

msString msCryptoAesCbcEncrypt(int64_t keyHandle, msString plainText, msString iv) {
	const msAesKey* key = keyOf(keyHandle);
	if (key == NULL) return MS_EMPTY_STRING;
	if (iv.len != 16) return MS_EMPTY_STRING;

	size_t ptLen = (size_t)plainText.len;
	size_t paddedLen = ptLen + (16 - (ptLen % 16));
	uint8_t* padded = (uint8_t*)msMemAlloc(paddedLen);
	memcpy(padded, msStringToCString(plainText), ptLen);
	memset(padded + ptLen, (int)(paddedLen - ptLen), paddedLen - ptLen);

	uint8_t ivCopy[16];
	memcpy(ivCopy, msStringToCString(iv), 16);

	mbedtls_aes_context aes;
	mbedtls_aes_init(&aes);
	uint8_t* out = (uint8_t*)msMemAlloc(paddedLen);
	msString result = MS_EMPTY_STRING;
	if (mbedtls_aes_setkey_enc(&aes, (const uint8_t*)key->bytes, (unsigned int)key->len * 8) == 0
		&& mbedtls_aes_crypt_cbc(&aes, MBEDTLS_AES_ENCRYPT, paddedLen, ivCopy, padded, out) == 0) {
		result = msStringNew((const char*)out, (int64_t)paddedLen);
	}
	mbedtls_aes_free(&aes);
	free(padded);
	free(out);
	return result;
}

int64_t msCryptoAesCbcDecrypt(int64_t keyHandle, msString cipherText, msString iv, msString* plainTextOut) {
	const msAesKey* key = keyOf(keyHandle);
	if (key == NULL) return 0;
	if (iv.len != 16) return 0;
	if (cipherText.len == 0 || cipherText.len % 16 != 0) return 0;

	size_t ctLen = (size_t)cipherText.len;
	uint8_t ivCopy[16];
	memcpy(ivCopy, msStringToCString(iv), 16);

	mbedtls_aes_context aes;
	mbedtls_aes_init(&aes);
	uint8_t* out = (uint8_t*)msMemAlloc(ctLen);
	int64_t plainLen = -1;
	if (mbedtls_aes_setkey_dec(&aes, (const uint8_t*)key->bytes, (unsigned int)key->len * 8) == 0
		&& mbedtls_aes_crypt_cbc(&aes, MBEDTLS_AES_DECRYPT, ctLen, ivCopy,
			(const uint8_t*)msStringToCString(cipherText), out) == 0) {
		plainLen = removePkcs7Padding(out, ctLen);
	}
	mbedtls_aes_free(&aes);

	if (plainLen >= 0) {
		msStringDestroy(*plainTextOut);
		*plainTextOut = msStringNew((const char*)out, plainLen);
	}
	free(out);
	return plainLen >= 0 ? 1 : 0;
}
