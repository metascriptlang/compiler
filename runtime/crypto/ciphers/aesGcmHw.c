/*
 * MetaScript AES-GCM hardware path: 8 blocks of CTR and one aggregated GHASH per pass, on Arm
 * AES + PMULL or x86-64 AES-NI + PCLMULQDQ. The mbedTLS key schedule and CPU detection decide
 * whether it runs, so a CPU without the extensions stays on the vendored gcm.c.
 */

#include "runtime/crypto/ciphers/aesGcmHw.h"
#include <string.h>
#include "mbedtls/platform_util.h"

#if defined(__aarch64__) && (defined(__clang__) || defined(__GNUC__))
#define MS_GCM_HW_ARM 1
#if !defined(__ARM_FEATURE_AES)
#define __ARM_FEATURE_AES 1
#endif
#if !defined(__ARM_FEATURE_CRYPTO)
#define __ARM_FEATURE_CRYPTO 1
#endif
#include <arm_neon.h>
#if defined(__linux__)
#include <sys/auxv.h>
#endif
#elif defined(__x86_64__) && (defined(__clang__) || defined(__GNUC__))
#define MS_GCM_HW_X86 1
#include <immintrin.h>
#endif

#if defined(MS_GCM_HW_ARM) || defined(MS_GCM_HW_X86)

#include "aesce.h"
#include "aesni.h"

#if defined(__clang__) && defined(MS_GCM_HW_ARM)
#pragma clang attribute push (__attribute__((target("aes"))), apply_to=function)
#elif defined(__clang__)
#pragma clang attribute push (__attribute__((target("aes,pclmul,ssse3,sse4.1"))), apply_to=function)
#elif defined(MS_GCM_HW_ARM)
#pragma GCC push_options
#pragma GCC target ("+crypto")
#else
#pragma GCC push_options
#pragma GCC target ("aes,pclmul,ssse3,sse4.1")
#endif

#if defined(__clang__)
#define MS_UNROLL _Pragma("clang loop unroll(full)")
#else
#define MS_UNROLL _Pragma("GCC unroll 16")
#endif

#if defined(MS_GCM_HW_ARM)

typedef uint8x16_t V;

static inline V load(const uint8_t* p) { return vld1q_u8(p); }
static inline void store(uint8_t* p, V v) { vst1q_u8(p, v); }
static inline V xorV(V a, V b) { return veorq_u8(a, b); }
static inline V bswapV(V v) { v = vrev64q_u8(v); return vextq_u8(v, v, 8); }
static inline V mulLL(V a, V b) {
	return vreinterpretq_u8_p128(vmull_p64(vgetq_lane_u64(vreinterpretq_u64_u8(a), 0), vgetq_lane_u64(vreinterpretq_u64_u8(b), 0)));
}
static inline V mulHH(V a, V b) {
	return vreinterpretq_u8_p128(vmull_p64(vgetq_lane_u64(vreinterpretq_u64_u8(a), 1), vgetq_lane_u64(vreinterpretq_u64_u8(b), 1)));
}
static inline V mulLH(V a, V b) {
	return vreinterpretq_u8_p128(vmull_p64(vgetq_lane_u64(vreinterpretq_u64_u8(a), 0), vgetq_lane_u64(vreinterpretq_u64_u8(b), 1)));
}
static inline V mulHL(V a, V b) {
	return vreinterpretq_u8_p128(vmull_p64(vgetq_lane_u64(vreinterpretq_u64_u8(a), 1), vgetq_lane_u64(vreinterpretq_u64_u8(b), 0)));
}
#define SHL64(v, n) vreinterpretq_u8_u64(vshlq_n_u64(vreinterpretq_u64_u8(v), n))
#define SHR64(v, n) vreinterpretq_u8_u64(vshrq_n_u64(vreinterpretq_u64_u8(v), n))
static inline V lowToHigh(V v) { return vextq_u8(vdupq_n_u8(0), v, 8); }
static inline V highToLow(V v) { return vextq_u8(v, vdupq_n_u8(0), 8); }
static inline V counterBlock(V base, uint32_t counter) {
	return vreinterpretq_u8_u32(vsetq_lane_u32(__builtin_bswap32(counter), vreinterpretq_u32_u8(base), 3));
}
static inline V aesRounds(V b, const V* rk, int nr) {
	for (int r = 0; r < nr - 1; r++) b = vaesmcq_u8(vaeseq_u8(b, rk[r]));
	return veorq_u8(vaeseq_u8(b, rk[nr - 1]), rk[nr]);
}
static inline __attribute__((always_inline)) void aesRounds8N(V* b, const V* rk, const int nr) {
	V t[8];
	MS_UNROLL for (int i = 0; i < 8; i++) t[i] = b[i];
	MS_UNROLL for (int r = 0; r < nr - 1; r++) {
		const V k = rk[r];
		MS_UNROLL for (int i = 0; i < 8; i++) t[i] = vaesmcq_u8(vaeseq_u8(t[i], k));
	}
	const V k = rk[nr - 1], last = rk[nr];
	MS_UNROLL for (int i = 0; i < 8; i++) b[i] = veorq_u8(vaeseq_u8(t[i], k), last);
}

static int hwAvailable(void) {
	if (!MBEDTLS_AESCE_HAS_SUPPORT()) return 0;
#if defined(__linux__)
	return (getauxval(AT_HWCAP) & (1UL << 4)) != 0;
#else
	return 1;
#endif
}

#else

typedef __m128i V;

static inline V load(const uint8_t* p) { return _mm_loadu_si128((const __m128i*)p); }
static inline void store(uint8_t* p, V v) { _mm_storeu_si128((__m128i*)p, v); }
static inline V xorV(V a, V b) { return _mm_xor_si128(a, b); }
static inline V bswapV(V v) { return _mm_shuffle_epi8(v, _mm_set_epi8(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)); }
static inline V mulLL(V a, V b) { return _mm_clmulepi64_si128(a, b, 0x00); }
static inline V mulHH(V a, V b) { return _mm_clmulepi64_si128(a, b, 0x11); }
static inline V mulLH(V a, V b) { return _mm_clmulepi64_si128(a, b, 0x10); }
static inline V mulHL(V a, V b) { return _mm_clmulepi64_si128(a, b, 0x01); }
#define SHL64(v, n) _mm_slli_epi64(v, n)
#define SHR64(v, n) _mm_srli_epi64(v, n)
static inline V lowToHigh(V v) { return _mm_slli_si128(v, 8); }
static inline V highToLow(V v) { return _mm_srli_si128(v, 8); }
static inline V counterBlock(V base, uint32_t counter) {
	return _mm_insert_epi32(base, (int)__builtin_bswap32(counter), 3);
}
static inline V aesRounds(V b, const V* rk, int nr) {
	b = _mm_xor_si128(b, rk[0]);
	for (int r = 1; r < nr; r++) b = _mm_aesenc_si128(b, rk[r]);
	return _mm_aesenclast_si128(b, rk[nr]);
}
static inline __attribute__((always_inline)) void aesRounds8N(V* b, const V* rk, const int nr) {
	V t[8];
	const V first = rk[0];
	MS_UNROLL for (int i = 0; i < 8; i++) t[i] = _mm_xor_si128(b[i], first);
	MS_UNROLL for (int r = 1; r < nr; r++) {
		const V k = rk[r];
		MS_UNROLL for (int i = 0; i < 8; i++) t[i] = _mm_aesenc_si128(t[i], k);
	}
	const V last = rk[nr];
	MS_UNROLL for (int i = 0; i < 8; i++) b[i] = _mm_aesenclast_si128(t[i], last);
}

static int hwAvailable(void) {
	return mbedtls_aesni_has_support(MBEDTLS_AESNI_AES) && mbedtls_aesni_has_support(MBEDTLS_AESNI_CLMUL);
}

#endif

/* One body per round count, so each loop has a constant trip count and unrolls. */
static void aesRounds8(V* b, const V* rk, int nr) {
	if (nr == 10) aesRounds8N(b, rk, 10);
	else if (nr == 12) aesRounds8N(b, rk, 12);
	else aesRounds8N(b, rk, 14);
}

/* GHASH runs on each block read as a big-endian integer. Key powers are stored multiplied by x
 * (twisted), which folds the bit reflection of GCM into the reduction below. */

static inline void mulAccumulate(V a, V b, V* lo, V* mid, V* hi) {
	*lo = xorV(*lo, mulLL(a, b));
	*hi = xorV(*hi, mulHH(a, b));
	*mid = xorV(*mid, xorV(mulLH(a, b), mulHL(a, b)));
}

static inline V reduceProduct(V lo, V mid, V hi) {
	lo = xorV(lo, lowToHigh(mid));
	hi = xorV(hi, highToLow(mid));
	V t = SHL64(lo, 1);
	t = xorV(t, lo);
	t = SHL64(t, 5);
	t = xorV(t, lo);
	t = SHL64(t, 57);
	lo = xorV(lo, lowToHigh(t));
	hi = xorV(hi, highToLow(t));
	V u = SHR64(lo, 5);
	u = xorV(u, lo);
	u = SHR64(u, 1);
	u = xorV(u, lo);
	u = SHR64(u, 1);
	return xorV(xorV(hi, u), lo);
}

static inline V fieldMul(V a, V twistedB) {
	V lo = xorV(a, a), mid = lo, hi = lo;
	mulAccumulate(a, twistedB, &lo, &mid, &hi);
	return reduceProduct(lo, mid, hi);
}

static V twist(V v) {
	uint64_t w[2];
	store((uint8_t*)w, v);
	uint64_t carry = w[1] >> 63;
	uint64_t high = (w[1] << 1) | (w[0] >> 63);
	uint64_t low = (w[0] << 1) | carry;
	if (carry) high ^= 0xc200000000000000ull;
	w[0] = low;
	w[1] = high;
	V out = load((const uint8_t*)w);
	mbedtls_platform_zeroize(w, sizeof(w));
	return out;
}

typedef struct {
	V power[8];
	V acc;
} Ghash;

static void ghashInit(Ghash* g, V keyBlock) {
	V h = bswapV(keyBlock);
	g->power[0] = twist(h);
	V p = h;
	for (int i = 1; i < 8; i++) {
		p = fieldMul(p, g->power[0]);
		g->power[i] = twist(p);
	}
	g->acc = xorV(h, h);
}

static inline void ghashBlock(Ghash* g, V block) {
	g->acc = fieldMul(xorV(g->acc, bswapV(block)), g->power[0]);
}

static void ghashBytes(Ghash* g, const uint8_t* p, size_t n) {
	while (n >= 16) {
		ghashBlock(g, load(p));
		p += 16;
		n -= 16;
	}
	if (n > 0) {
		uint8_t pad[16] = {0};
		memcpy(pad, p, n);
		ghashBlock(g, load(pad));
	}
}

static inline void ghash8(Ghash* g, const V* c) {
	V lo = xorV(c[0], c[0]), mid = lo, hi = lo;
	mulAccumulate(xorV(g->acc, bswapV(c[0])), g->power[7], &lo, &mid, &hi);
	for (int i = 1; i < 8; i++) mulAccumulate(bswapV(c[i]), g->power[7 - i], &lo, &mid, &hi);
	g->acc = reduceProduct(lo, mid, hi);
}

/* Every value derived from the key (round keys, H and its powers, the tag mask, keystream) lives
 * here so that one wipe covers the success and the refusal return. */
typedef struct {
	V rk[15];
	V tagMask;
	Ghash g;
	V ks[8], ct[8];
	uint8_t block[16], ksBytes[16];
} Secrets;

static void gcmRun(Secrets* s, const mbedtls_aes_context* aes, const uint8_t iv[12], const uint8_t* aad, size_t aadLen,
		const uint8_t* in, size_t len, uint8_t* out, uint8_t tag[16], int decrypt) {
	const int nr = aes->MBEDTLS_PRIVATE(nr);
	const uint8_t* rkBytes = (const uint8_t*)(aes->MBEDTLS_PRIVATE(buf) + aes->MBEDTLS_PRIVATE(rk_offset));
	V* rk = s->rk;
	Ghash* g = &s->g;
	V* ks = s->ks;
	V* ct = s->ct;
	for (int i = 0; i <= nr; i++) rk[i] = load(rkBytes + 16 * i);

	uint8_t ivBlock[16] = {0};
	memcpy(ivBlock, iv, 12);
	const V base = load(ivBlock);
	s->tagMask = aesRounds(counterBlock(base, 1), rk, nr);
	ghashInit(g, aesRounds(xorV(base, base), rk, nr));
	ghashBytes(g, aad, aadLen);

	uint32_t counter = 2;
	size_t done = 0;
	for (; len - done >= 128; done += 128) {
		for (int i = 0; i < 8; i++) ks[i] = counterBlock(base, counter + i);
		counter += 8;
		aesRounds8(ks, rk, nr);
		for (int i = 0; i < 8; i++) {
			V src = load(in + done + 16 * i);
			V dst = xorV(src, ks[i]);
			store(out + done + 16 * i, dst);
			ct[i] = decrypt ? src : dst;
		}
		ghash8(g, ct);
	}
	for (; len - done >= 16; done += 16) {
		V src = load(in + done);
		V dst = xorV(src, aesRounds(counterBlock(base, counter++), rk, nr));
		store(out + done, dst);
		ghashBlock(g, decrypt ? src : dst);
	}
	if (done < len) {
		size_t rest = len - done;
		uint8_t* block = s->block;
		memset(block, 0, 16);
		memcpy(block, in + done, rest);
		store(s->ksBytes, aesRounds(counterBlock(base, counter), rk, nr));
		for (size_t i = 0; i < rest; i++) out[done + i] = block[i] ^ s->ksBytes[i];
		if (!decrypt) memcpy(block, out + done, rest);
		ghashBlock(g, load(block));
	}

	uint8_t lengths[16];
	uint64_t aadBits = (uint64_t)aadLen * 8, bodyBits = (uint64_t)len * 8;
	for (int i = 0; i < 8; i++) {
		lengths[i] = (uint8_t)(aadBits >> (56 - 8 * i));
		lengths[8 + i] = (uint8_t)(bodyBits >> (56 - 8 * i));
	}
	ghashBlock(g, load(lengths));
	store(tag, xorV(s->tagMask, bswapV(g->acc)));
}

/* The caller has already refused lengths past the SP 800-38D limits (msAesGcmLengthsOk). */
int msAesGcmHw(const mbedtls_aes_context* aes, const uint8_t iv[12], const uint8_t* aad, size_t aadLen,
		const uint8_t* in, size_t len, uint8_t* out, uint8_t tag[16], int decrypt) {
	if (!hwAvailable()) return 0;
	Secrets s;
	gcmRun(&s, aes, iv, aad, aadLen, in, len, out, tag, decrypt);
	mbedtls_platform_zeroize(&s, sizeof(s));
	return 1;
}

#if defined(__clang__)
#pragma clang attribute pop
#else
#pragma GCC pop_options
#endif

#else

int msAesGcmHw(const mbedtls_aes_context* aes, const uint8_t iv[12], const uint8_t* aad, size_t aadLen,
		const uint8_t* in, size_t len, uint8_t* out, uint8_t tag[16], int decrypt) {
	(void)aes; (void)iv; (void)aad; (void)aadLen; (void)in; (void)len; (void)out; (void)tag; (void)decrypt;
	return 0;
}

#endif
