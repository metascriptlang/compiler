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

static int validKeyBits(msString key) {
	return key.len == 16 || key.len == 32;
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

/* Hardware path: 1 done, 0 refused (open: tag mismatch, out zeroed), -1 unavailable, use the generic gcm. */
static int sealHw(msString key, const uint8_t* iv, msString aad, msString plainText, uint8_t* out) {
	mbedtls_aes_context aes;
	mbedtls_aes_init(&aes);
	uint8_t tag[16];
	int done = mbedtls_aes_setkey_enc(&aes, (const uint8_t*)msStringToCString(key), (unsigned int)key.len * 8) == 0
		&& msAesGcmHw(&aes, iv, (const uint8_t*)msStringToCString(aad), (size_t)aad.len,
			(const uint8_t*)msStringToCString(plainText), (size_t)plainText.len, out + GCM_NONCE_SIZE, tag, 0);
	mbedtls_aes_free(&aes);
	if (done) memcpy(out + GCM_NONCE_SIZE + plainText.len, tag, GCM_TAG_SIZE);
	return done ? 1 : -1;
}

static int openHw(msString key, msString aad, const uint8_t* data, size_t ctLen, uint8_t* out) {
	mbedtls_aes_context aes;
	mbedtls_aes_init(&aes);
	uint8_t tag[16];
	int done = mbedtls_aes_setkey_enc(&aes, (const uint8_t*)msStringToCString(key), (unsigned int)key.len * 8) == 0
		&& msAesGcmHw(&aes, data, (const uint8_t*)msStringToCString(aad), (size_t)aad.len,
			data + GCM_NONCE_SIZE, ctLen, out, tag, 1);
	mbedtls_aes_free(&aes);
	if (!done) return -1;
	if (mbedtls_ct_memcmp(tag, data + GCM_NONCE_SIZE + ctLen, GCM_TAG_SIZE) == 0) return 1;
	mbedtls_platform_zeroize(out, ctLen);
	return 0;
}

int64_t msCryptoAesSealInto(msString key, msString plainText, msString aad, uint8_t* out) {
	if (!validKeyBits(key)) return 0;
	size_t ptLen = (size_t)plainText.len;

	/* Layout: nonce(12) || cipherText || tag(16) */
	if (ms_random_fill(out, GCM_NONCE_SIZE) != 0) return -1;
	if (sealHw(key, out, aad, plainText, out) == 1) return 1;

	mbedtls_gcm_context gcm;
	mbedtls_gcm_init(&gcm);
	int ok = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, (const uint8_t*)msStringToCString(key), (unsigned int)key.len * 8) == 0
		&& mbedtls_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_ENCRYPT, ptLen, out, GCM_NONCE_SIZE,
			(const uint8_t*)msStringToCString(aad), (size_t)aad.len,
			(const uint8_t*)msStringToCString(plainText), out + GCM_NONCE_SIZE,
			GCM_TAG_SIZE, out + GCM_NONCE_SIZE + ptLen) == 0;
	mbedtls_gcm_free(&gcm);
	return ok ? 1 : 0;
}

int64_t msCryptoAesOpenInto(msString key, msString sealed, msString aad, uint8_t* out) {
	if (!validKeyBits(key)) return 0;
	if (sealed.len < GCM_NONCE_SIZE + GCM_TAG_SIZE) return 0;

	const uint8_t* data = (const uint8_t*)msStringToCString(sealed);
	size_t ctLen = (size_t)sealed.len - GCM_NONCE_SIZE - GCM_TAG_SIZE;
	uint8_t none = 0;
	if (out == NULL) out = &none;
	int hw = openHw(key, aad, data, ctLen, out);
	if (hw >= 0) return hw;

	mbedtls_gcm_context gcm;
	mbedtls_gcm_init(&gcm);
	int ok = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, (const uint8_t*)msStringToCString(key), (unsigned int)key.len * 8) == 0
		&& mbedtls_gcm_auth_decrypt(&gcm, ctLen, data, GCM_NONCE_SIZE,
			(const uint8_t*)msStringToCString(aad), (size_t)aad.len,
			data + GCM_NONCE_SIZE + ctLen, GCM_TAG_SIZE,
			data + GCM_NONCE_SIZE, out) == 0;
	mbedtls_gcm_free(&gcm);
	return ok ? 1 : 0;
}

/* ===== AES-CBC ===== */

msString msCryptoAesCbcEncrypt(msString key, msString plainText, msString iv) {
	if (!validKeyBits(key)) return MS_EMPTY_STRING;
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
	if (mbedtls_aes_setkey_enc(&aes, (const uint8_t*)msStringToCString(key), (unsigned int)key.len * 8) == 0
		&& mbedtls_aes_crypt_cbc(&aes, MBEDTLS_AES_ENCRYPT, paddedLen, ivCopy, padded, out) == 0) {
		result = msStringNew((const char*)out, (int64_t)paddedLen);
	}
	mbedtls_aes_free(&aes);
	free(padded);
	free(out);
	return result;
}

int64_t msCryptoAesCbcDecrypt(msString key, msString cipherText, msString iv, msString* plainTextOut) {
	if (!validKeyBits(key)) return 0;
	if (iv.len != 16) return 0;
	if (cipherText.len == 0 || cipherText.len % 16 != 0) return 0;

	size_t ctLen = (size_t)cipherText.len;
	uint8_t ivCopy[16];
	memcpy(ivCopy, msStringToCString(iv), 16);

	mbedtls_aes_context aes;
	mbedtls_aes_init(&aes);
	uint8_t* out = (uint8_t*)msMemAlloc(ctLen);
	int64_t plainLen = -1;
	if (mbedtls_aes_setkey_dec(&aes, (const uint8_t*)msStringToCString(key), (unsigned int)key.len * 8) == 0
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
