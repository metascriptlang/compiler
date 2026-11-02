/*
 * Four-block ChaCha20 on NEON: register i holds word i of four consecutive blocks.
 */

#include "runtime/crypto/ciphers/chacha20Simd.h"

#ifdef MS_CHACHA20_SIMD

#include <arm_neon.h>
#include <string.h>

#define ROTL(x, n) vsriq_n_u32(vshlq_n_u32(x, n), x, 32 - (n))
#define QR(a, b, c, d)                                                                   \
	a = vaddq_u32(a, b);                                                                 \
	d = vreinterpretq_u32_u16(vrev32q_u16(vreinterpretq_u16_u32(veorq_u32(d, a))));      \
	c = vaddq_u32(c, d);                                                                 \
	b = ROTL(veorq_u32(b, c), 12);                                                       \
	a = vaddq_u32(a, b);                                                                 \
	d = ROTL(veorq_u32(d, a), 8);                                                        \
	c = vaddq_u32(c, d);                                                                 \
	b = ROTL(veorq_u32(b, c), 7)

static void wipe(void *p, size_t n) {
	memset(p, 0, n);
	__asm__ volatile("" : : "r"(p) : "memory");
}

size_t msChacha20SimdXor(uint8_t *out, const uint8_t *in, size_t n, const uint8_t key[32],
                         const uint8_t nonce[8], uint64_t *ctr) {
	static const uint32_t lanes[4] = {0, 1, 2, 3};
	uint32_t base[16];
	memcpy(base, "expand 32-byte k", 16);
	memcpy(base + 4, key, 32);
	memcpy(base + 14, nonce, 8);
	const uint32x4_t lane = vld1q_u32(lanes);
	size_t done = 0;

	uint32x4_t s[16], x[16];

	while (n - done >= 256) {
		/* the vector add wraps the low counter word; a chunk that would carry into the high word is left to the scalar caller */
		if ((uint32_t)*ctr > 0xfffffffbu) break;
		base[12] = (uint32_t)*ctr;
		base[13] = (uint32_t)(*ctr >> 32);

		for (int i = 0; i < 16; i++) s[i] = vdupq_n_u32(base[i]);
		s[12] = vaddq_u32(s[12], lane);
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
		for (int i = 0; i < 16; i++) x[i] = vaddq_u32(x[i], s[i]);

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
				uint8x16_t v = veorq_u8(vreinterpretq_u8_u64(rows[k]), vld1q_u8(in + done + k * 64 + g * 16));
				vst1q_u8(out + done + k * 64 + g * 16, v);
			}
		}
		done += 256;
		*ctr += 4;
	}

	wipe(base, sizeof base);
	wipe(s, sizeof s);
	wipe(x, sizeof x);
	return done;
}

#endif
