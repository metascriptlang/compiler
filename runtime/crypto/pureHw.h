/*
 * The hardware kernels the portable std/crypto modules dispatch to on C (std/crypto/pure/hw.cms). Each entry
 * checks msPureCpuFeatures first and returns 0, having touched nothing, when the CPU lacks the extension or
 * MS_CRYPTO_PORTABLE forces the portable code; the caller then runs its own .ms code for everything. Offsets
 * and lengths come from the caller's checked spans.
 */

#ifndef MS_CRYPTO_PURE_HW_H
#define MS_CRYPTO_PURE_HW_H

#include <stdint.h>
#include <string.h>
#include "runtime/crypto/cpuFeatures.h"
#include "runtime/crypto/sha256HwKernel.h"
#include "runtime/crypto/sha512HwKernel.h"
#include "runtime/crypto/ciphers/aesHw.h"
#include "runtime/crypto/ciphers/chacha20Simd.h"
#include "runtime/crypto/ciphers/poly1305x64.h"

static inline void msPureHwWipe(void *p, size_t n) {
	if (n == 0) return;
	memset(p, 0, n);
	__asm__ __volatile__("" : : "r"(p) : "memory");
}

/* Compresses `blocks` 64-byte blocks of data[off..] into the eight SHA-256 words at state; returns the blocks done. */
static inline int64_t msPureSha256Blocks(uint32_t *state, int64_t stateLen, const uint8_t *data, int64_t dataLen,
		int64_t off, int64_t blocks) {
	(void)stateLen; (void)dataLen;
#ifdef MS_SHA256_HW_KERNEL
	if (!(msPureCpuFeatures() & MS_CPU_SHA256)) return 0;
	return (int64_t)(msSha256HwKernel(state, data + off, (size_t)blocks * 64) / 64);
#else
	(void)state; (void)data; (void)off; (void)blocks;
	return 0;
#endif
}

/* Compresses `blocks` 128-byte blocks into the SHA-512 state held as sixteen words, high word first in each pair. */
static inline int64_t msPureSha512Blocks(uint32_t *pairs, int64_t pairsLen, const uint8_t *data, int64_t dataLen,
		int64_t off, int64_t blocks) {
	(void)pairsLen; (void)dataLen;
#ifdef MS_SHA512_HW_KERNEL
	if (!(msPureCpuFeatures() & MS_CPU_SHA512)) return 0;
	uint64_t st[8];
	for (int i = 0; i < 8; i++) st[i] = ((uint64_t)pairs[2 * i] << 32) | pairs[2 * i + 1];
	const size_t done = msSha512HwKernel(st, data + off, (size_t)blocks * 128);
	for (int i = 0; i < 8; i++) {
		pairs[2 * i] = (uint32_t)(st[i] >> 32);
		pairs[2 * i + 1] = (uint32_t)st[i];
	}
	msPureHwWipe(st, sizeof(st));
	return (int64_t)(done / 128);
#else
	(void)pairs; (void)data; (void)off; (void)blocks;
	return 0;
#endif
}

/* The portable AES key schedule ends with the FIPS 197 round keys, two 64-bit words per 16-byte round key, then
 * the round count (std/crypto/pure/aes.ms putHwKeys). */
static inline const uint8_t *msPureAesRoundKeys(const uint64_t *keys, int64_t keysLen, int *nr) {
	*nr = (int)keys[keysLen - 1];
	return (const uint8_t *)(keys + keysLen - 1 - 2 * (*nr + 1));
}

static inline int32_t msPureAesAvailable(void) {
	return (msPureCpuFeatures() & MS_CPU_AES) != 0 && msAesHwAvailable();
}

static inline void msPureAesGcmSeal(const uint64_t *keys, int64_t keysLen, const uint8_t *nonce, int64_t nonceLen,
		const uint8_t *aad, int64_t aadLen, const uint8_t *src, int64_t srcLen, int64_t srcAt, int64_t length,
		uint8_t *dst, int64_t dstLen, int64_t dstAt, uint8_t *tag, int64_t tagLen, int64_t tagAt) {
	(void)nonceLen; (void)srcLen; (void)dstLen; (void)tagLen;
	int nr;
	const uint8_t *rk = msPureAesRoundKeys(keys, keysLen, &nr);
	msAesGcmHwRun(rk, nr, nonce, aad, (size_t)aadLen, src + srcAt, (size_t)length, dst + dstAt, tag + tagAt, 0);
}

static inline int32_t msPureAesGcmOpen(const uint64_t *keys, int64_t keysLen, const uint8_t *nonce, int64_t nonceLen,
		const uint8_t *aad, int64_t aadLen, const uint8_t *src, int64_t srcLen, int64_t srcAt, int64_t length,
		const uint8_t *tag, int64_t tagLen, int64_t tagAt, uint8_t *dst, int64_t dstLen, int64_t dstAt) {
	(void)nonceLen; (void)srcLen; (void)dstLen; (void)tagLen;
	int nr;
	const uint8_t *rk = msPureAesRoundKeys(keys, keysLen, &nr);
	return msAesGcmHwOpen(rk, nr, nonce, aad, (size_t)aadLen, src + srcAt, (size_t)length, tag + tagAt, dst + dstAt);
}

/* GCM open in one pass into a buffer the caller owns alone: the plain text lands in dst before the tag is checked,
 * and a mismatch zeroes dst[dstAt, +length) and returns 0. */
static inline int32_t msPureAesGcmOpenFresh(const uint64_t *keys, int64_t keysLen, const uint8_t *nonce, int64_t nonceLen,
		const uint8_t *aad, int64_t aadLen, const uint8_t *src, int64_t srcLen, int64_t srcAt, int64_t length,
		const uint8_t *tag, int64_t tagLen, int64_t tagAt, uint8_t *dst, int64_t dstLen, int64_t dstAt) {
	(void)nonceLen; (void)srcLen; (void)dstLen; (void)tagLen;
	int nr;
	const uint8_t *rk = msPureAesRoundKeys(keys, keysLen, &nr);
	uint8_t computed[16];
	msAesGcmHwRun(rk, nr, nonce, aad, (size_t)aadLen, src + srcAt, (size_t)length, dst + dstAt, computed, 1);
	uint8_t diff = 0;
	for (int i = 0; i < 16; i++) diff |= computed[i] ^ tag[tagAt + i];
	msPureHwWipe(computed, sizeof(computed));
	if (diff != 0) {
		msPureHwWipe(dst + dstAt, (size_t)length);
		return 0;
	}
	return 1;
}

/* CBC encryption of buf (whole blocks, padding already in place) in place. */
static inline void msPureAesCbcEncrypt(const uint64_t *keys, int64_t keysLen, const uint8_t *iv, int64_t ivLen,
		uint8_t *buf, int64_t bufLen) {
	(void)ivLen;
	int nr;
	const uint8_t *rk = msPureAesRoundKeys(keys, keysLen, &nr);
	msAesCbcHwEncrypt(rk, nr, iv, buf, (size_t)bufLen, buf);
}

static inline void msPureAesCbcDecrypt(const uint64_t *keys, int64_t keysLen, const uint8_t *iv, int64_t ivLen,
		const uint8_t *src, int64_t srcLen, uint8_t *dst, int64_t dstLen) {
	(void)ivLen; (void)dstLen;
	int nr;
	const uint8_t *rk = msPureAesRoundKeys(keys, keysLen, &nr);
	msAesCbcHwDecrypt(rk, nr, iv, src, (size_t)srcLen, dst);
}

/* IETF ChaCha20 (key words, nonce words, 32-bit counter) over the leading whole blocks the vector kernel batches:
 * returns the bytes done, a multiple of 64; the caller finishes the rest from counter + done / 64. The kernel's
 * 64-bit djb counter is the IETF counter with the first nonce word above it, which the caller keeps from wrapping. */
static inline int64_t msPureChachaXor(const uint32_t *key, int64_t keyLen, const uint32_t *nonce, int64_t nonceLen,
		uint32_t counter, const uint8_t *src, int64_t srcLen, int64_t srcOff, uint8_t *dst, int64_t dstLen,
		int64_t dstOff, int64_t length) {
	(void)keyLen; (void)nonceLen; (void)srcLen; (void)dstLen;
#ifdef MS_CHACHA20_SIMD
	if (msCryptoPortableForced()) return 0;
	uint8_t keyBytes[32], nonceBytes[8];
	for (int i = 0; i < 8; i++) {
		for (int b = 0; b < 4; b++) keyBytes[4 * i + b] = (uint8_t)(key[i] >> (8 * b));
	}
	for (int i = 0; i < 2; i++) {
		for (int b = 0; b < 4; b++) nonceBytes[4 * i + b] = (uint8_t)(nonce[1 + i] >> (8 * b));
	}
	uint64_t ctr = (uint64_t)counter | ((uint64_t)nonce[0] << 32);
	const size_t done = msChacha20SimdXor(dst + dstOff, src + srcOff, (size_t)length, keyBytes, nonceBytes, &ctr);
	msPureHwWipe(keyBytes, sizeof(keyBytes));
	return (int64_t)done;
#else
	(void)key; (void)nonce; (void)counter; (void)src; (void)srcOff; (void)dst; (void)dstOff; (void)length;
	return 0;
#endif
}

/* The ChaCha20-Poly1305 tag over aad and text[off, +length) under the one-time authKey into tag; 0 when the 64-bit
 * limb kernel is not used. */
static inline int32_t msPurePoly1305Aead(uint8_t *tag, int64_t tagLen, const uint8_t *authKey, int64_t authKeyLen,
		const uint8_t *aad, int64_t aadLen, const uint8_t *text, int64_t textLen, int64_t off, int64_t length) {
	(void)tagLen; (void)authKeyLen; (void)textLen;
#ifdef MS_POLY1305_X64
	if (msCryptoPortableForced()) return 0;
	msPoly1305Aead(tag, authKey, aad, (size_t)aadLen, text + off, (size_t)length);
	return 1;
#else
	(void)tag; (void)authKey; (void)aad; (void)aadLen; (void)text; (void)off; (void)length;
	return 0;
#endif
}

#endif /* MS_CRYPTO_PURE_HW_H */
