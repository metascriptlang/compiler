/*
 * ChaCha20 with 128-bit vectors: register i holds word i of four consecutive blocks. On NEON two such
 * sets run side by side, and a ninth block in scalar registers beside them, because one set alone leaves
 * the vector pipes waiting on each round's dependency chain.
 */

#include "runtime/crypto/ciphers/chacha20Simd.h"

#ifdef MS_CHACHA20_SIMD

#include <string.h>

static void wipe(void *p, size_t n) {
	memset(p, 0, n);
	__asm__ volatile("" : : "r"(p) : "memory");
}

#ifdef __aarch64__

#include <arm_neon.h>

#define ROTL(x, n) vsriq_n_u32(vshlq_n_u32(x, n), x, 32 - (n))
#define QR(a, b, c, d)                                                                   \
	a = vaddq_u32(a, b);                                                                 \
	d = vreinterpretq_u32_u16(vrev32q_u16(vreinterpretq_u16_u32(veorq_u32(d, a))));      \
	c = vaddq_u32(c, d);                                                                 \
	b = ROTL(veorq_u32(b, c), 12);                                                       \
	a = vaddq_u32(a, b);                                                                 \
	d = vreinterpretq_u32_u8(vqtbl1q_u8(vreinterpretq_u8_u32(veorq_u32(d, a)), rot8));   \
	c = vaddq_u32(c, d);                                                                 \
	b = ROTL(veorq_u32(b, c), 7)

#define DOUBLE_ROUND(x)                                                                  \
	QR(x[0], x[4], x[8], x[12]);                                                         \
	QR(x[1], x[5], x[9], x[13]);                                                         \
	QR(x[2], x[6], x[10], x[14]);                                                        \
	QR(x[3], x[7], x[11], x[15]);                                                        \
	QR(x[0], x[5], x[10], x[15]);                                                        \
	QR(x[1], x[6], x[11], x[12]);                                                        \
	QR(x[2], x[7], x[8], x[13]);                                                         \
	QR(x[3], x[4], x[9], x[14])

#define ROTR32(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define SQR(a, b, c, d)                                                                  \
	a += b; d = ROTR32(d ^ a, 16);                                                       \
	c += d; b = ROTR32(b ^ c, 20);                                                       \
	a += b; d = ROTR32(d ^ a, 24);                                                       \
	c += d; b = ROTR32(b ^ c, 25)

#define SCALAR_DOUBLE_ROUND(z)                                                           \
	SQR(z[0], z[4], z[8], z[12]);                                                        \
	SQR(z[1], z[5], z[9], z[13]);                                                        \
	SQR(z[2], z[6], z[10], z[14]);                                                       \
	SQR(z[3], z[7], z[11], z[15]);                                                       \
	SQR(z[0], z[5], z[10], z[15]);                                                       \
	SQR(z[1], z[6], z[11], z[12]);                                                       \
	SQR(z[2], z[7], z[8], z[13]);                                                        \
	SQR(z[3], z[4], z[9], z[14])

static void storeSet(const uint32x4_t *x, uint8_t *out, const uint8_t *in) {
	for (int g = 0; g < 4; g++) {
		uint32x4x2_t a = vtrnq_u32(x[4 * g], x[4 * g + 1]);
		uint32x4x2_t b = vtrnq_u32(x[4 * g + 2], x[4 * g + 3]);
		uint64x2_t a0 = vreinterpretq_u64_u32(a.val[0]), a1 = vreinterpretq_u64_u32(a.val[1]);
		uint64x2_t b0 = vreinterpretq_u64_u32(b.val[0]), b1 = vreinterpretq_u64_u32(b.val[1]);
		uint64x2_t rows[4] = {vcombine_u64(vget_low_u64(a0), vget_low_u64(b0)),
		                      vcombine_u64(vget_low_u64(a1), vget_low_u64(b1)),
		                      vcombine_u64(vget_high_u64(a0), vget_high_u64(b0)),
		                      vcombine_u64(vget_high_u64(a1), vget_high_u64(b1))};
		for (int k = 0; k < 4; k++) {
			uint8x16_t v = veorq_u8(vreinterpretq_u8_u64(rows[k]), vld1q_u8(in + k * 64 + g * 16));
			vst1q_u8(out + k * 64 + g * 16, v);
		}
	}
}

size_t msChacha20SimdXor(uint8_t *out, const uint8_t *in, size_t n, const uint8_t key[32],
                         const uint8_t nonce[8], uint64_t *ctr) {
	static const uint32_t lanes[4] = {0, 1, 2, 3};
	static const uint8_t rot8Idx[16] = {3, 0, 1, 2, 7, 4, 5, 6, 11, 8, 9, 10, 15, 12, 13, 14};
	uint32_t base[16];
	memcpy(base, "expand 32-byte k", 16);
	memcpy(base + 4, key, 32);
	memcpy(base + 14, nonce, 8);
	const uint32x4_t lane = vld1q_u32(lanes);
	const uint8x16_t rot8 = vld1q_u8(rot8Idx);
	const uint32x4_t four = vdupq_n_u32(4);
	size_t done = 0;

	uint32x4_t s[16], x[16], y[16];
	uint32_t z[16], k[16];

	/* nine blocks: two vector sets and one scalar block. The vector add wraps the low counter word, so a
	 * chunk whose lanes would carry into the high word is left to a smaller chunk or the scalar caller. */
	while (n - done >= 576 && (uint32_t)*ctr <= 0xfffffff6u) {
		base[12] = (uint32_t)*ctr;
		base[13] = (uint32_t)(*ctr >> 32);
		for (int i = 0; i < 16; i++) s[i] = vdupq_n_u32(base[i]);
		s[12] = vaddq_u32(s[12], lane);
		for (int i = 0; i < 16; i++) x[i] = y[i] = s[i];
		y[12] = vaddq_u32(y[12], four);
		memcpy(z, base, sizeof z);
		z[12] = (uint32_t)(*ctr + 8);
		z[13] = (uint32_t)((*ctr + 8) >> 32);
		for (int r = 0; r < 10; r++) {
			DOUBLE_ROUND(x);
			DOUBLE_ROUND(y);
			SCALAR_DOUBLE_ROUND(z);
		}
		for (int i = 0; i < 16; i++) x[i] = vaddq_u32(x[i], s[i]);
		s[12] = vaddq_u32(s[12], four);
		for (int i = 0; i < 16; i++) y[i] = vaddq_u32(y[i], s[i]);
		memcpy(k, base, sizeof k);
		k[12] = (uint32_t)(*ctr + 8);
		k[13] = (uint32_t)((*ctr + 8) >> 32);
		for (int i = 0; i < 16; i++) k[i] += z[i];
		storeSet(x, out + done, in + done);
		storeSet(y, out + done + 256, in + done + 256);
		for (int g = 0; g < 4; g++) {
			uint8x16_t v = veorq_u8(vld1q_u8((const uint8_t *)k + g * 16), vld1q_u8(in + done + 512 + g * 16));
			vst1q_u8(out + done + 512 + g * 16, v);
		}
		done += 576;
		*ctr += 9;
	}

	while (n - done >= 256 && (uint32_t)*ctr <= 0xfffffffbu) {
		base[12] = (uint32_t)*ctr;
		base[13] = (uint32_t)(*ctr >> 32);
		for (int i = 0; i < 16; i++) s[i] = vdupq_n_u32(base[i]);
		s[12] = vaddq_u32(s[12], lane);
		for (int i = 0; i < 16; i++) x[i] = s[i];
		for (int r = 0; r < 10; r++) {
			DOUBLE_ROUND(x);
		}
		for (int i = 0; i < 16; i++) x[i] = vaddq_u32(x[i], s[i]);
		storeSet(x, out + done, in + done);
		done += 256;
		*ctr += 4;
	}

	wipe(base, sizeof base);
	wipe(s, sizeof s);
	wipe(x, sizeof x);
	wipe(y, sizeof y);
	wipe(z, sizeof z);
	wipe(k, sizeof k);
	return done;
}

#else /* __x86_64__ */

#include <emmintrin.h>

#define ROTL(x, n) _mm_or_si128(_mm_slli_epi32(x, n), _mm_srli_epi32(x, 32 - (n)))
#define QR(a, b, c, d)                                                                   \
	a = _mm_add_epi32(a, b);                                                             \
	d = ROTL(_mm_xor_si128(d, a), 16);                                                   \
	c = _mm_add_epi32(c, d);                                                             \
	b = ROTL(_mm_xor_si128(b, c), 12);                                                   \
	a = _mm_add_epi32(a, b);                                                             \
	d = ROTL(_mm_xor_si128(d, a), 8);                                                    \
	c = _mm_add_epi32(c, d);                                                             \
	b = ROTL(_mm_xor_si128(b, c), 7)

static void storeSet(const __m128i *x, uint8_t *out, const uint8_t *in) {
	for (int g = 0; g < 4; g++) {
		__m128i a0 = _mm_unpacklo_epi32(x[4 * g], x[4 * g + 1]);
		__m128i a1 = _mm_unpackhi_epi32(x[4 * g], x[4 * g + 1]);
		__m128i b0 = _mm_unpacklo_epi32(x[4 * g + 2], x[4 * g + 3]);
		__m128i b1 = _mm_unpackhi_epi32(x[4 * g + 2], x[4 * g + 3]);
		__m128i rows[4] = {_mm_unpacklo_epi64(a0, b0), _mm_unpackhi_epi64(a0, b0),
		                   _mm_unpacklo_epi64(a1, b1), _mm_unpackhi_epi64(a1, b1)};
		for (int k = 0; k < 4; k++) {
			__m128i v = _mm_xor_si128(rows[k], _mm_loadu_si128((const __m128i *)(in + k * 64 + g * 16)));
			_mm_storeu_si128((__m128i *)(out + k * 64 + g * 16), v);
		}
	}
}

size_t msChacha20SimdXor(uint8_t *out, const uint8_t *in, size_t n, const uint8_t key[32],
                         const uint8_t nonce[8], uint64_t *ctr) {
	uint32_t base[16];
	memcpy(base, "expand 32-byte k", 16);
	memcpy(base + 4, key, 32);
	memcpy(base + 14, nonce, 8);
	const __m128i lane = _mm_set_epi32(3, 2, 1, 0);
	size_t done = 0;

	__m128i s[16], x[16];

	/* the vector add wraps the low counter word; a chunk that would carry into the high word is left to the scalar caller */
	while (n - done >= 256 && (uint32_t)*ctr <= 0xfffffffbu) {
		base[12] = (uint32_t)*ctr;
		base[13] = (uint32_t)(*ctr >> 32);
		for (int i = 0; i < 16; i++) s[i] = _mm_set1_epi32((int)base[i]);
		s[12] = _mm_add_epi32(s[12], lane);
		for (int i = 0; i < 16; i++) x[i] = s[i];
		for (int r = 0; r < 10; r++) {
			QR(x[0], x[4], x[8], x[12]);
			QR(x[1], x[5], x[9], x[13]);
			QR(x[2], x[6], x[10], x[14]);
			QR(x[3], x[7], x[11], x[15]);
			QR(x[0], x[5], x[10], x[15]);
			QR(x[1], x[6], x[11], x[12]);
			QR(x[2], x[7], x[8], x[13]);
			QR(x[3], x[4], x[9], x[14]);
		}
		for (int i = 0; i < 16; i++) x[i] = _mm_add_epi32(x[i], s[i]);
		storeSet(x, out + done, in + done);
		done += 256;
		*ctr += 4;
	}

	wipe(base, sizeof base);
	wipe(s, sizeof s);
	wipe(x, sizeof x);
	return done;
}

#endif

#endif
