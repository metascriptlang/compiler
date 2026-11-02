/*
 * Poly1305 over three 44/44/42-bit limbs held in 64-bit words, products in unsigned __int128.
 */

#include "runtime/crypto/ciphers/poly1305x64.h"

#ifdef __SIZEOF_INT128__

#include <string.h>

#if defined(__x86_64__)
#include <cpuid.h>
#include <immintrin.h>
#define POLY_VEC 1
#elif defined(__aarch64__)
#include <arm_neon.h>
#define POLY_VEC 1
#endif

typedef unsigned __int128 u128;
typedef uint64_t u64;

#define MASK44 0xfffffffffffULL
#define MASK42 0x3ffffffffffULL

/* rp[k] holds r^(k+1) as limbs r0, r1, r2 and the folded multiples s1 = 20 * r1, s2 = 20 * r2. */
typedef struct {
	u64 rp[4][5];
	u64 h0, h1, h2;
} polyState;

static u64 load64(const uint8_t *p) {
	u64 v;
	memcpy(&v, p, 8);
	return v;
}

#define MULACC(d0, d1, d2, a0, a1, a2, p)                                                \
	d0 += (u128)(a0) * (p)[0] + (u128)(a1) * (p)[4] + (u128)(a2) * (p)[3];               \
	d1 += (u128)(a0) * (p)[1] + (u128)(a1) * (p)[0] + (u128)(a2) * (p)[4];               \
	d2 += (u128)(a0) * (p)[2] + (u128)(a1) * (p)[1] + (u128)(a2) * (p)[0]

#define CARRY(d0, d1, d2, h0, h1, h2)                                                    \
	do {                                                                                 \
		u64 c = (u64)((d0) >> 44);                                                       \
		h0 = (u64)(d0) & MASK44;                                                         \
		(d1) += c;                                                                       \
		c = (u64)((d1) >> 44);                                                           \
		h1 = (u64)(d1) & MASK44;                                                         \
		(d2) += c;                                                                       \
		c = (u64)((d2) >> 42);                                                           \
		h2 = (u64)(d2) & MASK42;                                                         \
		h0 += c * 5;                                                                     \
		c = h0 >> 44;                                                                    \
		h0 &= MASK44;                                                                    \
		h1 += c;                                                                         \
	} while (0)

/* (h + m[0]) * r^K + m[1] * r^(K-1) + ... + m[K-1] * r: the K products are independent, so only
 * one carry chain stays serial per K blocks. */
#define POLY_STEP(K)                                                                     \
	do {                                                                                 \
		u128 d0 = 0, d1 = 0, d2 = 0;                                                     \
		for (int i = 0; i < (K); i++) {                                                  \
			u64 t0 = load64(m + 16 * i), t1 = load64(m + 16 * i + 8);                    \
			u64 a0 = t0 & MASK44;                                                        \
			u64 a1 = ((t0 >> 44) | (t1 << 20)) & MASK44;                                 \
			u64 a2 = ((t1 >> 24) & MASK42) | ((u64)1 << 40);                             \
			if (i == 0) {                                                                \
				a0 += h0;                                                                \
				a1 += h1;                                                                \
				a2 += h2;                                                                \
			}                                                                            \
			MULACC(d0, d1, d2, a0, a1, a2, st->rp[(K) - 1 - i]);                         \
		}                                                                                \
		CARRY(d0, d1, d2, h0, h1, h2);                                                   \
		m += 16 * (K);                                                                   \
		blocks -= (K);                                                                   \
	} while (0)

#ifdef POLY_VEC

#define MASK26 0x3ffffffULL
#define POLY_AVX2_MIN_BLOCKS 32

static void toLimbs26(u64 l[5], u64 a0, u64 a1, u64 a2) {
	u64 c;
	for (int i = 0; i < 2; i++) {
		c = a0 >> 44; a0 &= MASK44; a1 += c;
		c = a1 >> 44; a1 &= MASK44; a2 += c;
		c = a2 >> 42; a2 &= MASK42; a0 += c * 5;
	}
	c = a0 >> 44; a0 &= MASK44; a1 += c;
	l[0] = a0 & MASK26;
	l[1] = ((a0 >> 26) | (a1 << 18)) & MASK26;
	l[2] = (a1 >> 8) & MASK26;
	l[3] = ((a1 >> 34) | (a2 << 10)) & MASK26;
	l[4] = a2 >> 16;
}

static void fromSums26(polyState *st, u64 d0, u64 d1, u64 d2, u64 d3, u64 d4) {
	u64 c = d0 >> 26; d0 &= MASK26; d1 += c;
	c = d1 >> 26; d1 &= MASK26; d2 += c;
	c = d2 >> 26; d2 &= MASK26; d3 += c;
	c = d3 >> 26; d3 &= MASK26; d4 += c;
	c = d4 >> 26; d4 &= MASK26; d0 += c * 5;
	c = d0 >> 26; d0 &= MASK26; d1 += c;
	u128 lo = (u128)d0 + ((u128)d1 << 26) + ((u128)d2 << 52) + ((u128)d3 << 78);
	st->h0 = (u64)lo & MASK44;
	st->h1 = (u64)(lo >> 44) & MASK44;
	st->h2 = (u64)(lo >> 88) + (d4 << 16);
}

static void wipe(void *p, size_t n) {
	volatile u64 *w = (volatile u64 *)p;
	for (size_t i = 0; i < n / 8; i++) w[i] = 0;
}

static void powers26(u64 pw[8][5], const polyState *st) {
	for (int k = 0; k < 4; k++) toLimbs26(pw[k], st->rp[k][0], st->rp[k][1], st->rp[k][2]);
	for (int k = 0; k < 4; k++) {
		u64 h0, h1, h2;
		u128 d0 = 0, d1 = 0, d2 = 0;
		MULACC(d0, d1, d2, st->rp[3][0], st->rp[3][1], st->rp[3][2], st->rp[k]);
		CARRY(d0, d1, d2, h0, h1, h2);
		toLimbs26(pw[4 + k], h0, h1, h2);
	}
}

#endif

#if defined(__x86_64__)

static int cpuHasAvx2(void) {
	static int cached = -1;
	int v = __atomic_load_n(&cached, __ATOMIC_RELAXED);
	if (v < 0) {
		unsigned a, b, c, d;
		v = 0;
		if (__get_cpuid(1, &a, &b, &c, &d) && (c & (1u << 27)) && (c & (1u << 28))) {
			unsigned lo, hi;
			__asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
			if ((lo & 6) == 6 && __get_cpuid_count(7, 0, &a, &b, &c, &d) && (b & (1u << 5))) v = 1;
		}
		__atomic_store_n(&cached, v, __ATOMIC_RELAXED);
	}
	return v;
}

#define MUL(x, y) _mm256_mul_epu32(x, y)
#define ADD(x, y) _mm256_add_epi64(x, y)
#define SRL(x, n) _mm256_srli_epi64(x, n)
#define SLL(x, n) _mm256_slli_epi64(x, n)
#define AND(x, y) _mm256_and_si256(x, y)

#define V_MUL(d, a, R, S)                                                                \
	d##0 = ADD(ADD(ADD(MUL(a##0, R##0), MUL(a##1, S##4)), ADD(MUL(a##2, S##3), MUL(a##3, S##2))), MUL(a##4, S##1)); \
	d##1 = ADD(ADD(ADD(MUL(a##0, R##1), MUL(a##1, R##0)), ADD(MUL(a##2, S##4), MUL(a##3, S##3))), MUL(a##4, S##2)); \
	d##2 = ADD(ADD(ADD(MUL(a##0, R##2), MUL(a##1, R##1)), ADD(MUL(a##2, R##0), MUL(a##3, S##4))), MUL(a##4, S##3)); \
	d##3 = ADD(ADD(ADD(MUL(a##0, R##3), MUL(a##1, R##2)), ADD(MUL(a##2, R##1), MUL(a##3, R##0))), MUL(a##4, S##4)); \
	d##4 = ADD(ADD(ADD(MUL(a##0, R##4), MUL(a##1, R##3)), ADD(MUL(a##2, R##2), MUL(a##3, R##1))), MUL(a##4, R##0))

/* Four blocks, one per 64-bit lane in the order b0, b2, b1, b3 that the unpack leaves them in. */
#define V_LOAD(m, a, mask, hibit)                                                        \
	do {                                                                                 \
		__m256i x0 = _mm256_loadu_si256((const __m256i *)(m));                           \
		__m256i x1 = _mm256_loadu_si256((const __m256i *)((m) + 32));                    \
		__m256i lo = _mm256_unpacklo_epi64(x0, x1), hi = _mm256_unpackhi_epi64(x0, x1);  \
		a##0 = AND(lo, mask);                                                            \
		a##1 = AND(SRL(lo, 26), mask);                                                   \
		a##2 = AND(_mm256_or_si256(SRL(lo, 52), SLL(hi, 12)), mask);                     \
		a##3 = AND(SRL(hi, 14), mask);                                                   \
		a##4 = _mm256_or_si256(SRL(hi, 40), hibit);                                      \
	} while (0)

#define V_CARRY(d, mask)                                                                 \
	do {                                                                                 \
		__m256i c0 = SRL(d##0, 26), c3 = SRL(d##3, 26);                                  \
		d##0 = AND(d##0, mask);                                                          \
		d##3 = AND(d##3, mask);                                                          \
		d##1 = ADD(d##1, c0);                                                            \
		d##4 = ADD(d##4, c3);                                                            \
		__m256i c1 = SRL(d##1, 26), c4 = SRL(d##4, 26);                                  \
		d##1 = AND(d##1, mask);                                                          \
		d##4 = AND(d##4, mask);                                                          \
		d##2 = ADD(d##2, c1);                                                            \
		d##0 = ADD(d##0, ADD(c4, SLL(c4, 2)));                                           \
		__m256i c2 = SRL(d##2, 26);                                                      \
		c0 = SRL(d##0, 26);                                                              \
		d##2 = AND(d##2, mask);                                                          \
		d##0 = AND(d##0, mask);                                                          \
		d##3 = ADD(d##3, c2);                                                            \
		d##1 = ADD(d##1, c0);                                                            \
		c3 = SRL(d##3, 26);                                                              \
		d##3 = AND(d##3, mask);                                                          \
		d##4 = ADD(d##4, c3);                                                            \
	} while (0)

#define V_ADD(a, n) a##0 = ADD(a##0, n##0); a##1 = ADD(a##1, n##1); a##2 = ADD(a##2, n##2); a##3 = ADD(a##3, n##3); a##4 = ADD(a##4, n##4)

#define V_STORE(o, d)                                                                    \
	_mm256_storeu_si256((__m256i *)o[0], d##0); _mm256_storeu_si256((__m256i *)o[1], d##1); \
	_mm256_storeu_si256((__m256i *)o[2], d##2); _mm256_storeu_si256((__m256i *)o[3], d##3); \
	_mm256_storeu_si256((__m256i *)o[4], d##4)

__attribute__((target("avx2"))) static void avx2Blocks(polyState *st, const uint8_t *m, size_t steps) {
	u64 pw[8][5], hl[5];
	powers26(pw, st);
	toLimbs26(hl, st->h0, st->h1, st->h2);
	const __m256i mask = _mm256_set1_epi64x(MASK26), hibit = _mm256_set1_epi64x(1 << 24);
	__m256i r0 = _mm256_set1_epi64x(pw[7][0]), r1 = _mm256_set1_epi64x(pw[7][1]), r2 = _mm256_set1_epi64x(pw[7][2]),
	        r3 = _mm256_set1_epi64x(pw[7][3]), r4 = _mm256_set1_epi64x(pw[7][4]);
	__m256i s1 = ADD(r1, SLL(r1, 2)), s2 = ADD(r2, SLL(r2, 2)), s3 = ADD(r3, SLL(r3, 2)), s4 = ADD(r4, SLL(r4, 2));
	__m256i a0, a1, a2, a3, a4, b0, b1, b2, b3, b4, d0, d1, d2, d3, d4, e0, e1, e2, e3, e4;
	V_LOAD(m, a, mask, hibit);
	V_LOAD(m + 64, b, mask, hibit);
	a0 = ADD(a0, _mm256_set_epi64x(0, 0, 0, hl[0]));
	a1 = ADD(a1, _mm256_set_epi64x(0, 0, 0, hl[1]));
	a2 = ADD(a2, _mm256_set_epi64x(0, 0, 0, hl[2]));
	a3 = ADD(a3, _mm256_set_epi64x(0, 0, 0, hl[3]));
	a4 = ADD(a4, _mm256_set_epi64x(0, 0, 0, hl[4]));
	for (size_t g = 1; g < steps; g++) {
		m += 128;
		V_MUL(d, a, r, s);
		V_MUL(e, b, r, s);
		V_CARRY(d, mask);
		V_CARRY(e, mask);
		V_LOAD(m, a, mask, hibit);
		V_LOAD(m + 64, b, mask, hibit);
		V_ADD(a, d);
		V_ADD(b, e);
	}
	/* lanes hold b0, b2, b1, b3 of their four: the first register takes r^8, r^6, r^7, r^5, the second r^4, r^2, r^3, r^1 */
#define LANE(i, x, y, z, w) _mm256_set_epi64x(pw[w][i], pw[z][i], pw[y][i], pw[x][i])
	r0 = LANE(0, 7, 5, 6, 4); r1 = LANE(1, 7, 5, 6, 4); r2 = LANE(2, 7, 5, 6, 4); r3 = LANE(3, 7, 5, 6, 4); r4 = LANE(4, 7, 5, 6, 4);
	s1 = ADD(r1, SLL(r1, 2)); s2 = ADD(r2, SLL(r2, 2)); s3 = ADD(r3, SLL(r3, 2)); s4 = ADD(r4, SLL(r4, 2));
	V_MUL(d, a, r, s);
	r0 = LANE(0, 3, 1, 2, 0); r1 = LANE(1, 3, 1, 2, 0); r2 = LANE(2, 3, 1, 2, 0); r3 = LANE(3, 3, 1, 2, 0); r4 = LANE(4, 3, 1, 2, 0);
#undef LANE
	s1 = ADD(r1, SLL(r1, 2)); s2 = ADD(r2, SLL(r2, 2)); s3 = ADD(r3, SLL(r3, 2)); s4 = ADD(r4, SLL(r4, 2));
	V_MUL(e, b, r, s);
	V_ADD(d, e);
	u64 o[5][4], t[5];
	V_STORE(o, d);
	for (int i = 0; i < 5; i++) t[i] = o[i][0] + o[i][1] + o[i][2] + o[i][3];
	fromSums26(st, t[0], t[1], t[2], t[3], t[4]);
	_mm256_zeroall();
	wipe(pw, sizeof pw); wipe(hl, sizeof hl); wipe(o, sizeof o); wipe(t, sizeof t);
}

static size_t polyVecBlocks(polyState *st, const uint8_t *m, size_t blocks) {
	if (blocks < POLY_AVX2_MIN_BLOCKS || !cpuHasAvx2()) return 0;
	avx2Blocks(st, m, blocks >> 3);
	return blocks & ~(size_t)7;
}

#elif defined(__aarch64__)

#define NV 3
#define POLY_NEON_MIN_BLOCKS 24

static inline void nLoad(const uint8_t *m, uint32x2_t a[5]) {
	uint64x2_t x = vreinterpretq_u64_u8(vld1q_u8(m)), y = vreinterpretq_u64_u8(vld1q_u8(m + 16));
	uint64x2_t lo = vtrn1q_u64(x, y), hi = vtrn2q_u64(x, y), mask = vdupq_n_u64(MASK26);
	a[0] = vmovn_u64(vandq_u64(lo, mask));
	a[1] = vmovn_u64(vandq_u64(vshrq_n_u64(lo, 26), mask));
	a[2] = vmovn_u64(vandq_u64(vorrq_u64(vshrq_n_u64(lo, 52), vshlq_n_u64(hi, 12)), mask));
	a[3] = vmovn_u64(vandq_u64(vshrq_n_u64(hi, 14), mask));
	a[4] = vmovn_u64(vorrq_u64(vshrq_n_u64(hi, 40), vdupq_n_u64(1 << 24)));
}

static inline void nMul(uint64x2_t d[5], const uint32x2_t a[5], const uint32x2_t r[5], const uint32x2_t s[5]) {
	d[0] = vmull_u32(a[0], r[0]);
	d[1] = vmull_u32(a[0], r[1]);
	d[2] = vmull_u32(a[0], r[2]);
	d[3] = vmull_u32(a[0], r[3]);
	d[4] = vmull_u32(a[0], r[4]);
	d[0] = vmlal_u32(d[0], a[1], s[4]); d[1] = vmlal_u32(d[1], a[1], r[0]); d[2] = vmlal_u32(d[2], a[1], r[1]);
	d[3] = vmlal_u32(d[3], a[1], r[2]); d[4] = vmlal_u32(d[4], a[1], r[3]);
	d[0] = vmlal_u32(d[0], a[2], s[3]); d[1] = vmlal_u32(d[1], a[2], s[4]); d[2] = vmlal_u32(d[2], a[2], r[0]);
	d[3] = vmlal_u32(d[3], a[2], r[1]); d[4] = vmlal_u32(d[4], a[2], r[2]);
	d[0] = vmlal_u32(d[0], a[3], s[2]); d[1] = vmlal_u32(d[1], a[3], s[3]); d[2] = vmlal_u32(d[2], a[3], s[4]);
	d[3] = vmlal_u32(d[3], a[3], r[0]); d[4] = vmlal_u32(d[4], a[3], r[1]);
	d[0] = vmlal_u32(d[0], a[4], s[1]); d[1] = vmlal_u32(d[1], a[4], s[2]); d[2] = vmlal_u32(d[2], a[4], s[3]);
	d[3] = vmlal_u32(d[3], a[4], s[4]); d[4] = vmlal_u32(d[4], a[4], r[0]);
}

static inline void nCarry(uint64x2_t d[5]) {
	uint64x2_t mask = vdupq_n_u64(MASK26), c0 = vshrq_n_u64(d[0], 26), c3 = vshrq_n_u64(d[3], 26);
	d[0] = vandq_u64(d[0], mask);
	d[3] = vandq_u64(d[3], mask);
	d[1] = vaddq_u64(d[1], c0);
	d[4] = vaddq_u64(d[4], c3);
	uint64x2_t c1 = vshrq_n_u64(d[1], 26), c4 = vshrq_n_u64(d[4], 26);
	d[1] = vandq_u64(d[1], mask);
	d[4] = vandq_u64(d[4], mask);
	d[2] = vaddq_u64(d[2], c1);
	d[0] = vaddq_u64(d[0], vaddq_u64(c4, vshlq_n_u64(c4, 2)));
	uint64x2_t c2 = vshrq_n_u64(d[2], 26);
	c0 = vshrq_n_u64(d[0], 26);
	d[2] = vandq_u64(d[2], mask);
	d[0] = vandq_u64(d[0], mask);
	d[3] = vaddq_u64(d[3], c2);
	d[1] = vaddq_u64(d[1], c0);
	c3 = vshrq_n_u64(d[3], 26);
	d[3] = vandq_u64(d[3], mask);
	d[4] = vaddq_u64(d[4], c3);
}

static void neonBlocks(polyState *st, const uint8_t *m, size_t steps) {
	u64 pw[8][5], hl[5];
	powers26(pw, st);
	toLimbs26(hl, st->h0, st->h1, st->h2);
	uint32x2_t a[NV][5], r[5], s[5];
	for (int i = 0; i < 5; i++) {
		r[i] = vdup_n_u32((uint32_t)pw[2 * NV - 1][i]);
		s[i] = vdup_n_u32((uint32_t)(pw[2 * NV - 1][i] * 5));
	}
	for (int k = 0; k < NV; k++) nLoad(m + 32 * k, a[k]);
	for (int i = 0; i < 5; i++) a[0][i] = vadd_u32(a[0][i], vcreate_u32(hl[i]));
	for (size_t g = 1; g < steps; g++) {
		m += 32 * NV;
		for (int k = 0; k < NV; k++) {
			uint64x2_t d[5];
			uint32x2_t n[5];
			nMul(d, a[k], r, s);
			nCarry(d);
			nLoad(m + 32 * k, n);
			for (int i = 0; i < 5; i++) a[k][i] = vadd_u32(vmovn_u64(d[i]), n[i]);
		}
	}
	uint64x2_t tot[5] = {vdupq_n_u64(0), vdupq_n_u64(0), vdupq_n_u64(0), vdupq_n_u64(0), vdupq_n_u64(0)};
	for (int k = 0; k < NV; k++) {
		uint64x2_t d[5];
		for (int i = 0; i < 5; i++) {
			u64 x = pw[2 * NV - 2 * k - 1][i], y = pw[2 * NV - 2 * k - 2][i];
			r[i] = vcreate_u32(x | (y << 32));
			s[i] = vcreate_u32(x * 5 | ((y * 5) << 32));
		}
		nMul(d, a[k], r, s);
		for (int i = 0; i < 5; i++) tot[i] = vaddq_u64(tot[i], d[i]);
	}
	u64 t[5];
	for (int i = 0; i < 5; i++) t[i] = vaddvq_u64(tot[i]);
	fromSums26(st, t[0], t[1], t[2], t[3], t[4]);
	wipe(pw, sizeof pw); wipe(hl, sizeof hl); wipe(t, sizeof t);
}

static size_t polyVecBlocks(polyState *st, const uint8_t *m, size_t blocks) {
	if (blocks < POLY_NEON_MIN_BLOCKS) return 0;
	size_t per = 2 * NV, steps = blocks / per;
	neonBlocks(st, m, steps);
	return steps * per;
}

#endif

#ifdef POLY_VEC
#define POLY_VEC_TAKE(st, m, blocks)                                                     \
	do {                                                                                 \
		size_t took = polyVecBlocks(st, m, blocks);                                      \
		m += 16 * took;                                                                  \
		blocks -= took;                                                                  \
	} while (0)
#else
#define POLY_VEC_TAKE(st, m, blocks) ((void)0)
#endif

static void polyBlocks(polyState *st, const uint8_t *m, size_t blocks) {
	POLY_VEC_TAKE(st, m, blocks);
	u64 h0 = st->h0, h1 = st->h1, h2 = st->h2;
	while (blocks >= 4) POLY_STEP(4);
	if (blocks >= 2) POLY_STEP(2);
	if (blocks >= 1) POLY_STEP(1);
	st->h0 = h0;
	st->h1 = h1;
	st->h2 = h2;
}

/* Whole 16-byte blocks of data, then the remainder zero-padded to one more block. */
static void polyPadded(polyState *st, const uint8_t *data, size_t len) {
	polyBlocks(st, data, len >> 4);
	size_t rest = len & 15;
	if (rest > 0) {
		uint8_t block[16] = {0};
		memcpy(block, data + (len - rest), rest);
		polyBlocks(st, block, 1);
	}
}

static void polyFinal(polyState *st, uint8_t mac[16], const uint8_t pad[16]) {
	u64 h0 = st->h0, h1 = st->h1, h2 = st->h2, c;

	c = h1 >> 44; h1 &= MASK44; h2 += c;
	c = h2 >> 42; h2 &= MASK42; h0 += c * 5;
	c = h0 >> 44; h0 &= MASK44; h1 += c;
	c = h1 >> 44; h1 &= MASK44; h2 += c;
	c = h2 >> 42; h2 &= MASK42; h0 += c * 5;
	c = h0 >> 44; h0 &= MASK44; h1 += c;

	/* g = h + 5 - 2^130; h < p exactly when g went negative, which sets bit 63 of g2. */
	u64 g0 = h0 + 5;
	c = g0 >> 44; g0 &= MASK44;
	u64 g1 = h1 + c;
	c = g1 >> 44; g1 &= MASK44;
	u64 g2 = h2 + c - ((u64)1 << 42);

	u64 takeG = (g2 >> 63) - 1; /* all ones when h >= p */
	u64 keepH = ~takeG;
	h0 = (h0 & keepH) | (g0 & takeG);
	h1 = (h1 & keepH) | (g1 & takeG);
	h2 = (h2 & keepH) | (g2 & takeG);

	u64 t0 = load64(pad), t1 = load64(pad + 8);
	h0 += t0 & MASK44;
	c = h0 >> 44; h0 &= MASK44;
	h1 += (((t0 >> 44) | (t1 << 20)) & MASK44) + c;
	c = h1 >> 44; h1 &= MASK44;
	h2 += ((t1 >> 24) & MASK42) + c;
	h2 &= MASK42;

	u64 lo = h0 | (h1 << 44);
	u64 hi = (h1 >> 20) | (h2 << 24);
	memcpy(mac, &lo, 8);
	memcpy(mac + 8, &hi, 8);
}

void msPoly1305Aead(uint8_t mac[16], const uint8_t authKey[32], const uint8_t *ad, size_t adLen,
                    const uint8_t *cipherText, size_t textLen) {
	polyState st;
	u64 t0 = load64(authKey), t1 = load64(authKey + 8);
	st.rp[0][0] = t0 & 0xffc0fffffffULL;
	st.rp[0][1] = ((t0 >> 44) | (t1 << 20)) & 0xfffffc0ffffULL;
	st.rp[0][2] = (t1 >> 24) & 0x00ffffffc0fULL;
	st.rp[0][3] = st.rp[0][1] * (5 << 2);
	st.rp[0][4] = st.rp[0][2] * (5 << 2);
	for (int k = 1; k < 4; k++) {
		u64 *r = st.rp[0], *q = st.rp[k - 1], *o = st.rp[k], h0, h1, h2;
		u128 d0 = 0, d1 = 0, d2 = 0;
		MULACC(d0, d1, d2, q[0], q[1], q[2], r);
		CARRY(d0, d1, d2, h0, h1, h2);
		o[0] = h0;
		o[1] = h1;
		o[2] = h2;
		o[3] = h1 * (5 << 2);
		o[4] = h2 * (5 << 2);
	}
	st.h0 = st.h1 = st.h2 = 0;

	polyPadded(&st, ad, adLen);
	polyPadded(&st, cipherText, textLen);
	u64 sizes[2] = {adLen, textLen};
	polyBlocks(&st, (const uint8_t *)sizes, 1);
	polyFinal(&st, mac, authKey + 16);

	volatile uint8_t *w = (volatile uint8_t *)&st;
	for (size_t i = 0; i < sizeof st; i++) w[i] = 0;
}

#endif
