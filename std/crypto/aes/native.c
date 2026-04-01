/*
 * MetaScript AES Runtime — AES-GCM and AES-CBC implementation
 *
 * GCM: manual implementation using AES-ECB + GHASH counter mode.
 * CBC: uses mbedTLS AES-CBC directly with PKCS7 padding.
 * Random IV: uses arc4random_buf (macOS) / getrandom (Linux).
 */

#include "std/crypto/aes/native.h"
#include "std/core/system/native.h"
#include <stdlib.h>
#include <string.h>

/* mbedTLS AES — only need the core AES module */
#include "mbedtls/aes.h"

/* ===== Random IV Generation ===== */

#if defined(__APPLE__)
#include <stdlib.h>
static void generateRandomBytes(uint8_t* buf, size_t len) {
	arc4random_buf(buf, len);
}
#elif defined(__linux__)
#include <sys/random.h>
static void generateRandomBytes(uint8_t* buf, size_t len) {
	getrandom(buf, len, 0);
}
#else
#include <stdio.h>
static void generateRandomBytes(uint8_t* buf, size_t len) {
	FILE* f = fopen("/dev/urandom", "rb");
	if (f) { fread(buf, 1, len, f); fclose(f); }
}
#endif

/* ===== PKCS7 Padding (for CBC) ===== */

static size_t addPkcs7Padding(uint8_t* data, size_t dataLen, size_t blockSize) {
	size_t paddingLen = blockSize - (dataLen % blockSize);
	for (size_t i = 0; i < paddingLen; i++) {
		data[dataLen + i] = (uint8_t)paddingLen;
	}
	return dataLen + paddingLen;
}

static size_t removePkcs7Padding(const uint8_t* data, size_t dataLen) {
	if (dataLen == 0 || dataLen % 16 != 0) return 0;
	uint8_t pad = data[dataLen - 1];
	if (pad == 0 || pad > 16) return 0;
	for (size_t i = 0; i < pad; i++) {
		if (data[dataLen - 1 - i] != pad) return 0;
	}
	return dataLen - pad;
}

/* ===== GCM: Galois Field Multiplication for GHASH ===== */

static void gfMultiply(const uint8_t X[16], const uint8_t Y[16], uint8_t result[16]) {
	uint8_t V[16];
	memcpy(V, Y, 16);
	memset(result, 0, 16);

	for (int i = 0; i < 128; i++) {
		if (X[i / 8] & (1 << (7 - (i % 8)))) {
			for (int j = 0; j < 16; j++) result[j] ^= V[j];
		}
		int lsb = V[15] & 1;
		for (int j = 15; j > 0; j--) {
			V[j] = (V[j] >> 1) | (V[j - 1] << 7);
		}
		V[0] >>= 1;
		if (lsb) V[0] ^= 0xe1; /* R polynomial for GCM */
	}
}

/* GHASH: hash blocks using GF multiplication */
static void ghash(const uint8_t H[16], const uint8_t* data, size_t dataLen,
                  const uint8_t* aad, size_t aadLen, uint8_t result[16]) {
	memset(result, 0, 16);

	/* Process AAD blocks */
	size_t i;
	for (i = 0; i + 16 <= aadLen; i += 16) {
		for (int j = 0; j < 16; j++) result[j] ^= aad[i + j];
		uint8_t tmp[16]; gfMultiply(result, H, tmp); memcpy(result, tmp, 16);
	}
	if (i < aadLen) {
		uint8_t block[16] = {0};
		memcpy(block, aad + i, aadLen - i);
		for (int j = 0; j < 16; j++) result[j] ^= block[j];
		uint8_t tmp[16]; gfMultiply(result, H, tmp); memcpy(result, tmp, 16);
	}

	/* Process cipherText blocks */
	for (i = 0; i + 16 <= dataLen; i += 16) {
		for (int j = 0; j < 16; j++) result[j] ^= data[i + j];
		uint8_t tmp[16]; gfMultiply(result, H, tmp); memcpy(result, tmp, 16);
	}
	if (i < dataLen) {
		uint8_t block[16] = {0};
		memcpy(block, data + i, dataLen - i);
		for (int j = 0; j < 16; j++) result[j] ^= block[j];
		uint8_t tmp[16]; gfMultiply(result, H, tmp); memcpy(result, tmp, 16);
	}

	/* Length block: aadLen || dataLen in bits, big-endian 64-bit */
	uint8_t lenBlock[16] = {0};
	uint64_t aadBits = (uint64_t)aadLen * 8;
	uint64_t dataBits = (uint64_t)dataLen * 8;
	for (int j = 0; j < 8; j++) {
		lenBlock[7 - j] = (uint8_t)(aadBits >> (j * 8));
		lenBlock[15 - j] = (uint8_t)(dataBits >> (j * 8));
	}
	for (int j = 0; j < 16; j++) result[j] ^= lenBlock[j];
	uint8_t tmp[16]; gfMultiply(result, H, tmp); memcpy(result, tmp, 16);
}

/* Increment counter (last 4 bytes, big-endian) */
static void incrementCounter(uint8_t counter[16]) {
	for (int i = 15; i >= 12; i--) {
		if (++counter[i] != 0) break;
	}
}

/* ===== AES-GCM Core ===== */

static int aesGcmCrypt(
	int keyBits, const uint8_t* key,
	const uint8_t* input, size_t inputLen,
	const uint8_t* iv, size_t ivLen,
	const uint8_t* aad, size_t aadLen,
	uint8_t* output, uint8_t tag[16],
	int encrypting
) {
	mbedtls_aes_context aes;
	mbedtls_aes_init(&aes);
	if (mbedtls_aes_setkey_enc(&aes, key, keyBits) != 0) {
		mbedtls_aes_free(&aes);
		return 0;
	}

	/* H = AES_K(0^128) */
	uint8_t H[16], zeroBlock[16] = {0};
	mbedtls_aes_crypt_ecb(&aes, MBEDTLS_AES_ENCRYPT, zeroBlock, H);

	/* J0: initial counter from IV */
	uint8_t J0[16] = {0};
	if (ivLen == 12) {
		memcpy(J0, iv, 12);
		J0[15] = 1;
	} else {
		ghash(H, iv, ivLen, NULL, 0, J0);
	}

	/* Counter starts at J0 + 1 */
	uint8_t counter[16];
	memcpy(counter, J0, 16);
	incrementCounter(counter);

	/* CTR mode */
	for (size_t i = 0; i < inputLen; i += 16) {
		uint8_t keyStream[16];
		mbedtls_aes_crypt_ecb(&aes, MBEDTLS_AES_ENCRYPT, counter, keyStream);
		size_t blockLen = (inputLen - i < 16) ? inputLen - i : 16;
		for (size_t j = 0; j < blockLen; j++) {
			output[i + j] = input[i + j] ^ keyStream[j];
		}
		incrementCounter(counter);
	}

	/* Compute auth tag */
	const uint8_t* hashData = encrypting ? output : input;
	uint8_t ghashResult[16];
	ghash(H, hashData, inputLen, aad, aadLen, ghashResult);

	/* Tag = GHASH XOR AES_K(J0) */
	uint8_t encJ0[16];
	mbedtls_aes_crypt_ecb(&aes, MBEDTLS_AES_ENCRYPT, J0, encJ0);
	for (int i = 0; i < 16; i++) {
		tag[i] = ghashResult[i] ^ encJ0[i];
	}

	mbedtls_aes_free(&aes);
	return 1;
}

/* ===== Public API ===== */

msString msCryptoAesSeal(msString key, msString plainText, msString aad) {
	int keyBits = (int)key.len * 8;
	if (keyBits != 128 && keyBits != 256) return MS_EMPTY_STRING;

	const uint8_t* keyData = (const uint8_t*)msStringToCString(key);
	const uint8_t* ptData = (const uint8_t*)msStringToCString(plainText);
	size_t ptLen = (size_t)plainText.len;
	const uint8_t* aadData = aad.len > 0 ? (const uint8_t*)msStringToCString(aad) : NULL;
	size_t aadLen = (size_t)aad.len;

	/* Generate 12-byte random nonce */
	uint8_t nonce[12];
	generateRandomBytes(nonce, 12);

	/* Allocate output: nonce(12) + cipherText + tag(16) */
	size_t outLen = 12 + ptLen + 16;
	uint8_t* out = (uint8_t*)malloc(outLen);
	if (!out) return MS_EMPTY_STRING;

	memcpy(out, nonce, 12);
	uint8_t tag[16];

	if (!aesGcmCrypt(keyBits, keyData, ptData, ptLen, nonce, 12,
	                 aadData, aadLen, out + 12, tag, 1)) {
		free(out);
		return MS_EMPTY_STRING;
	}

	memcpy(out + 12 + ptLen, tag, 16);
	msString result = msStringNew((const char*)out, (int64_t)outLen);
	free(out);
	return result;
}

msString msCryptoAesOpen(msString key, msString sealed, msString aad) {
	int keyBits = (int)key.len * 8;
	if (keyBits != 128 && keyBits != 256) return MS_EMPTY_STRING;
	if (sealed.len < 28) return MS_EMPTY_STRING; /* minimum: 12 nonce + 0 ct + 16 tag */

	const uint8_t* keyData = (const uint8_t*)msStringToCString(key);
	const uint8_t* sealedData = (const uint8_t*)msStringToCString(sealed);
	size_t sealedLen = (size_t)sealed.len;
	const uint8_t* aadData = aad.len > 0 ? (const uint8_t*)msStringToCString(aad) : NULL;
	size_t aadLen = (size_t)aad.len;

	const uint8_t* nonce = sealedData;
	size_t ctLen = sealedLen - 12 - 16;
	const uint8_t* ct = sealedData + 12;
	const uint8_t* expectedTag = sealedData + 12 + ctLen;

	uint8_t* plainText = (uint8_t*)malloc(ctLen);
	if (!plainText) return MS_EMPTY_STRING;

	uint8_t computedTag[16];
	if (!aesGcmCrypt(keyBits, keyData, ct, ctLen, nonce, 12,
	                 aadData, aadLen, plainText, computedTag, 0)) {
		free(plainText);
		return MS_EMPTY_STRING;
	}

	/* Constant-time tag comparison */
	volatile uint8_t diff = 0;
	for (int i = 0; i < 16; i++) diff |= computedTag[i] ^ expectedTag[i];
	if (diff != 0) {
		free(plainText);
		return MS_EMPTY_STRING;
	}

	msString result = msStringNew((const char*)plainText, (int64_t)ctLen);
	free(plainText);
	return result;
}

msString msCryptoAesGcmEncrypt(msString key, msString plainText, msString iv, msString aad, msString* tagOut) {
	int keyBits = (int)key.len * 8;
	if (keyBits != 128 && keyBits != 256) return MS_EMPTY_STRING;

	const uint8_t* keyData = (const uint8_t*)msStringToCString(key);
	const uint8_t* ptData = (const uint8_t*)msStringToCString(plainText);
	size_t ptLen = (size_t)plainText.len;
	const uint8_t* ivData = (const uint8_t*)msStringToCString(iv);
	size_t ivLen = (size_t)iv.len;
	const uint8_t* aadData = aad.len > 0 ? (const uint8_t*)msStringToCString(aad) : NULL;
	size_t aadLen = (size_t)aad.len;

	uint8_t* ct = (uint8_t*)malloc(ptLen);
	if (!ct) return MS_EMPTY_STRING;

	uint8_t tag[16];
	if (!aesGcmCrypt(keyBits, keyData, ptData, ptLen, ivData, ivLen,
	                 aadData, aadLen, ct, tag, 1)) {
		free(ct);
		return MS_EMPTY_STRING;
	}

	*tagOut = msStringNew((const char*)tag, 16);
	msString result = msStringNew((const char*)ct, (int64_t)ptLen);
	free(ct);
	return result;
}

msString msCryptoAesGcmDecrypt(msString key, msString cipherText, msString iv, msString aad, msString authTag) {
	int keyBits = (int)key.len * 8;
	if (keyBits != 128 && keyBits != 256) return MS_EMPTY_STRING;
	if (authTag.len != 16) return MS_EMPTY_STRING;

	const uint8_t* keyData = (const uint8_t*)msStringToCString(key);
	const uint8_t* ctData = (const uint8_t*)msStringToCString(cipherText);
	size_t ctLen = (size_t)cipherText.len;
	const uint8_t* ivData = (const uint8_t*)msStringToCString(iv);
	size_t ivLen = (size_t)iv.len;
	const uint8_t* aadData = aad.len > 0 ? (const uint8_t*)msStringToCString(aad) : NULL;
	size_t aadLen = (size_t)aad.len;

	uint8_t* pt = (uint8_t*)malloc(ctLen);
	if (!pt) return MS_EMPTY_STRING;

	uint8_t computedTag[16];
	if (!aesGcmCrypt(keyBits, keyData, ctData, ctLen, ivData, ivLen,
	                 aadData, aadLen, pt, computedTag, 0)) {
		free(pt);
		return MS_EMPTY_STRING;
	}

	volatile uint8_t diff = 0;
	const uint8_t* expectedTag = (const uint8_t*)msStringToCString(authTag);
	for (int i = 0; i < 16; i++) diff |= computedTag[i] ^ expectedTag[i];
	if (diff != 0) {
		free(pt);
		return MS_EMPTY_STRING;
	}

	msString result = msStringNew((const char*)pt, (int64_t)ctLen);
	free(pt);
	return result;
}

msString msCryptoAesCbcEncrypt(msString key, msString plainText, msString iv) {
	int keyBits = (int)key.len * 8;
	if (keyBits != 128 && keyBits != 256) return MS_EMPTY_STRING;
	if (iv.len != 16) return MS_EMPTY_STRING;

	size_t ptLen = (size_t)plainText.len;
	size_t paddedLen = ptLen + (16 - (ptLen % 16));
	uint8_t* padded = (uint8_t*)calloc(1, paddedLen);
	if (!padded) return MS_EMPTY_STRING;
	memcpy(padded, msStringToCString(plainText), ptLen);
	paddedLen = addPkcs7Padding(padded, ptLen, 16);

	uint8_t ivCopy[16];
	memcpy(ivCopy, msStringToCString(iv), 16);

	mbedtls_aes_context aes;
	mbedtls_aes_init(&aes);
	if (mbedtls_aes_setkey_enc(&aes, (const uint8_t*)msStringToCString(key), keyBits) != 0) {
		mbedtls_aes_free(&aes);
		free(padded);
		return MS_EMPTY_STRING;
	}

	uint8_t* out = (uint8_t*)malloc(paddedLen);
	if (!out) { mbedtls_aes_free(&aes); free(padded); return MS_EMPTY_STRING; }

	mbedtls_aes_crypt_cbc(&aes, MBEDTLS_AES_ENCRYPT, paddedLen, ivCopy, padded, out);
	mbedtls_aes_free(&aes);
	free(padded);

	msString result = msStringNew((const char*)out, (int64_t)paddedLen);
	free(out);
	return result;
}

msString msCryptoAesCbcDecrypt(msString key, msString cipherText, msString iv) {
	int keyBits = (int)key.len * 8;
	if (keyBits != 128 && keyBits != 256) return MS_EMPTY_STRING;
	if (iv.len != 16) return MS_EMPTY_STRING;
	if (cipherText.len == 0 || cipherText.len % 16 != 0) return MS_EMPTY_STRING;

	size_t ctLen = (size_t)cipherText.len;
	uint8_t ivCopy[16];
	memcpy(ivCopy, msStringToCString(iv), 16);

	mbedtls_aes_context aes;
	mbedtls_aes_init(&aes);
	if (mbedtls_aes_setkey_dec(&aes, (const uint8_t*)msStringToCString(key), keyBits) != 0) {
		mbedtls_aes_free(&aes);
		return MS_EMPTY_STRING;
	}

	uint8_t* out = (uint8_t*)malloc(ctLen);
	if (!out) { mbedtls_aes_free(&aes); return MS_EMPTY_STRING; }

	mbedtls_aes_crypt_cbc(&aes, MBEDTLS_AES_DECRYPT, ctLen, ivCopy,
	                       (const uint8_t*)msStringToCString(cipherText), out);
	mbedtls_aes_free(&aes);

	size_t plainLen = removePkcs7Padding(out, ctLen);
	if (plainLen == 0 && ctLen > 0) { free(out); return MS_EMPTY_STRING; }

	msString result = msStringNew((const char*)out, (int64_t)plainLen);
	free(out);
	return result;
}
