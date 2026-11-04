/*
 * AES on the CPU's AES and carry-less multiply extensions (Arm AES + PMULL, x86-64 AES-NI + PCLMULQDQ): GCM as
 * 8 blocks of CTR and one aggregated GHASH per pass, and CBC, encryption serial and decryption 8 blocks per
 * pass. Every entry takes the encryption round keys rk[0..nr] as 16-byte blocks in FIPS 197 order, so the
 * vendor wrapper (aesGcmHw.c) and the portable std/crypto modules share it. Callers check msAesHwAvailable
 * first; on a CPU or build without the extensions it reports 0 and the other entries do nothing.
 * No secret-dependent branch or index.
 */

#include "runtime/crypto/ciphers/aesHw.h"
#include "runtime/crypto/cpuFeatures.h"
#include <string.h>

static void wipe(void* p, size_t n) {
	memset(p, 0, n);
	__asm__ __volatile__("" : : "r"(p) : "memory");
}

#if defined(__aarch64__) && (defined(__clang__) || defined(__GNUC__))
#define MS_GCM_HW_ARM 1
#if !defined(__ARM_FEATURE_AES)
#define __ARM_FEATURE_AES 1
#endif
#if !defined(__ARM_FEATURE_CRYPTO)
#define __ARM_FEATURE_CRYPTO 1
#endif
#include <arm_neon.h>
#elif defined(__x86_64__) && (defined(__clang__) || defined(__GNUC__))
#define MS_GCM_HW_X86 1
#include <immintrin.h>
#endif

#if defined(MS_GCM_HW_ARM) || defined(MS_GCM_HW_X86)

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


static inline V aesInvMix(V k) { return vaesimcq_u8(k); }
static inline V aesDecRounds(V b, const V* dk, int nr) {
	for (int r = 0; r < nr - 1; r++) b = vaesimcq_u8(vaesdq_u8(b, dk[r]));
	return veorq_u8(vaesdq_u8(b, dk[nr - 1]), dk[nr]);
}
static inline __attribute__((always_inline)) void aesDecRounds8N(V* b, const V* dk, const int nr) {
	MS_UNROLL for (int r = 0; r < nr - 1; r++) {
		const V k = dk[r];
		MS_UNROLL for (int i = 0; i < 8; i++) b[i] = vaesimcq_u8(vaesdq_u8(b[i], k));
	}
	const V k = dk[nr - 1], last = dk[nr];
	MS_UNROLL for (int i = 0; i < 8; i++) b[i] = veorq_u8(vaesdq_u8(b[i], k), last);
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


static inline V aesInvMix(V k) { return _mm_aesimc_si128(k); }
static inline V aesDecRounds(V b, const V* dk, int nr) {
	b = _mm_xor_si128(b, dk[0]);
	for (int r = 1; r < nr; r++) b = _mm_aesdec_si128(b, dk[r]);
	return _mm_aesdeclast_si128(b, dk[nr]);
}
static inline __attribute__((always_inline)) void aesDecRounds8N(V* b, const V* dk, const int nr) {
	const V first = dk[0];
	MS_UNROLL for (int i = 0; i < 8; i++) b[i] = _mm_xor_si128(b[i], first);
	MS_UNROLL for (int r = 1; r < nr; r++) {
		const V k = dk[r];
		MS_UNROLL for (int i = 0; i < 8; i++) b[i] = _mm_aesdec_si128(b[i], k);
	}
	const V last = dk[nr];
	MS_UNROLL for (int i = 0; i < 8; i++) b[i] = _mm_aesdeclast_si128(b[i], last);
}

#endif

/* One body per round count, so each loop has a constant trip count and unrolls. */
static void aesRounds8(V* b, const V* rk, int nr) {
	if (nr == 10) aesRounds8N(b, rk, 10);
	else if (nr == 12) aesRounds8N(b, rk, 12);
	else aesRounds8N(b, rk, 14);
}

static void aesDecRounds8(V* b, const V* dk, int nr) {
	if (nr == 10) aesDecRounds8N(b, dk, 10);
	else if (nr == 12) aesDecRounds8N(b, dk, 12);
	else aesDecRounds8N(b, dk, 14);
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
	high ^= 0xc200000000000000ull & (0 - carry);
	w[0] = low;
	w[1] = high;
	V out = load((const uint8_t*)w);
	wipe(w, sizeof(w));
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
	V dk[15];
	V tagMask;
	Ghash g;
	V ks[8], ct[8];
	uint8_t block[16], ksBytes[16];
} Secrets;

/* GCM over the encryption round keys rk[0..nr] (16 bytes each, FIPS 197 order) and a 12-byte iv. With `crypt` the
 * counter stream XORs in into out; with `hash` the tag over aad and the cipher text (out when encrypting, in when
 * decrypting) goes to tag. */
static void gcmRun(Secrets* s, const uint8_t* rkBytes, int nr, const uint8_t iv[12], const uint8_t* aad, size_t aadLen,
		const uint8_t* in, size_t len, uint8_t* out, uint8_t tag[16], int decrypt, int crypt, int hash) {
	V* rk = s->rk;
	Ghash* g = &s->g;
	V* ks = s->ks;
	V* ct = s->ct;
	for (int i = 0; i <= nr; i++) rk[i] = load(rkBytes + 16 * i);

	uint8_t ivBlock[16] = {0};
	memcpy(ivBlock, iv, 12);
	const V base = load(ivBlock);
	if (hash) {
		s->tagMask = aesRounds(counterBlock(base, 1), rk, nr);
		ghashInit(g, aesRounds(xorV(base, base), rk, nr));
		ghashBytes(g, aad, aadLen);
	}

	uint32_t counter = 2;
	size_t done = 0;
	for (; len - done >= 128; done += 128) {
		if (crypt) {
			for (int i = 0; i < 8; i++) ks[i] = counterBlock(base, counter + i);
			counter += 8;
			aesRounds8(ks, rk, nr);
			for (int i = 0; i < 8; i++) {
				V src = load(in + done + 16 * i);
				V dst = xorV(src, ks[i]);
				store(out + done + 16 * i, dst);
				ct[i] = decrypt ? src : dst;
			}
		} else {
			for (int i = 0; i < 8; i++) ct[i] = load(in + done + 16 * i);
		}
		if (hash) ghash8(g, ct);
	}
	for (; len - done >= 16; done += 16) {
		V src = load(in + done);
		V text = src;
		if (crypt) {
			V dst = xorV(src, aesRounds(counterBlock(base, counter++), rk, nr));
			store(out + done, dst);
			if (!decrypt) text = dst;
		}
		if (hash) ghashBlock(g, text);
	}
	if (done < len) {
		size_t rest = len - done;
		uint8_t* block = s->block;
		memset(block, 0, 16);
		memcpy(block, in + done, rest);
		if (crypt) {
			store(s->ksBytes, aesRounds(counterBlock(base, counter), rk, nr));
			for (size_t i = 0; i < rest; i++) out[done + i] = block[i] ^ s->ksBytes[i];
			if (!decrypt) memcpy(block, out + done, rest);
		}
		if (hash) ghashBlock(g, load(block));
	}

	if (hash) {
		uint8_t lengths[16];
		uint64_t aadBits = (uint64_t)aadLen * 8, bodyBits = (uint64_t)len * 8;
		for (int i = 0; i < 8; i++) {
			lengths[i] = (uint8_t)(aadBits >> (56 - 8 * i));
			lengths[8 + i] = (uint8_t)(bodyBits >> (56 - 8 * i));
		}
		ghashBlock(g, load(lengths));
		store(tag, xorV(s->tagMask, bswapV(g->acc)));
	}
}

int msAesHwAvailable(void) {
	return (msCpuFeatures() & MS_CPU_AES) != 0;
}

void msAesGcmHwRun(const uint8_t* rk, int nr, const uint8_t iv[12], const uint8_t* aad, size_t aadLen,
		const uint8_t* in, size_t len, uint8_t* out, uint8_t tag[16], int decrypt) {
	Secrets s;
	gcmRun(&s, rk, nr, iv, aad, aadLen, in, len, out, tag, decrypt, 1, 1);
	wipe(&s, sizeof(s));
}

int msAesGcmHwOpen(const uint8_t* rk, int nr, const uint8_t iv[12], const uint8_t* aad, size_t aadLen,
		const uint8_t* in, size_t len, const uint8_t tag[16], uint8_t* out) {
	Secrets s;
	uint8_t computed[16];
	gcmRun(&s, rk, nr, iv, aad, aadLen, in, len, NULL, computed, 1, 0, 1);
	uint8_t diff = 0;
	for (int i = 0; i < 16; i++) diff |= computed[i] ^ tag[i];
	const int ok = diff == 0;
	if (ok) gcmRun(&s, rk, nr, iv, aad, aadLen, in, len, out, NULL, 1, 1, 0);
	wipe(computed, sizeof(computed));
	wipe(&s, sizeof(s));
	return ok;
}

void msAesCbcHwEncrypt(const uint8_t* rkBytes, int nr, const uint8_t iv[16], const uint8_t* in, size_t len, uint8_t* out) {
	Secrets s;
	for (int i = 0; i <= nr; i++) s.rk[i] = load(rkBytes + 16 * i);
	V chain = load(iv);
	for (size_t done = 0; done + 16 <= len; done += 16) {
		chain = aesRounds(xorV(load(in + done), chain), s.rk, nr);
		store(out + done, chain);
	}
	wipe(&s, sizeof(s));
}

/* The equivalent inverse cipher's keys: the encryption keys in reverse, the inner ones through InvMixColumns. */
static void decryptKeys(Secrets* s, const uint8_t* rkBytes, int nr) {
	for (int i = 0; i <= nr; i++) s->rk[i] = load(rkBytes + 16 * i);
	s->dk[0] = s->rk[nr];
	for (int i = 1; i < nr; i++) s->dk[i] = aesInvMix(s->rk[nr - i]);
	s->dk[nr] = s->rk[0];
}

void msAesCbcHwDecrypt(const uint8_t* rkBytes, int nr, const uint8_t iv[16], const uint8_t* in, size_t len, uint8_t* out) {
	Secrets s;
	decryptKeys(&s, rkBytes, nr);
	V prev = load(iv);
	size_t done = 0;
	for (; len - done >= 128; done += 128) {
		V* b = s.ks;
		V* c = s.ct;
		for (int i = 0; i < 8; i++) c[i] = b[i] = load(in + done + 16 * i);
		aesDecRounds8(b, s.dk, nr);
		store(out + done, xorV(b[0], prev));
		for (int i = 1; i < 8; i++) store(out + done + 16 * i, xorV(b[i], c[i - 1]));
		prev = c[7];
	}
	for (; len - done >= 16; done += 16) {
		V c = load(in + done);
		store(out + done, xorV(aesDecRounds(c, s.dk, nr), prev));
		prev = c;
	}
	wipe(&s, sizeof(s));
}

#if defined(__clang__)
#pragma clang attribute pop
#else
#pragma GCC pop_options
#endif

#else

int msAesHwAvailable(void) {
	return 0;
}

void msAesGcmHwRun(const uint8_t* rk, int nr, const uint8_t iv[12], const uint8_t* aad, size_t aadLen,
		const uint8_t* in, size_t len, uint8_t* out, uint8_t tag[16], int decrypt) {
	(void)rk; (void)nr; (void)iv; (void)aad; (void)aadLen; (void)in; (void)len; (void)out; (void)tag; (void)decrypt;
}

int msAesGcmHwOpen(const uint8_t* rk, int nr, const uint8_t iv[12], const uint8_t* aad, size_t aadLen,
		const uint8_t* in, size_t len, const uint8_t tag[16], uint8_t* out) {
	(void)rk; (void)nr; (void)iv; (void)aad; (void)aadLen; (void)in; (void)len; (void)tag; (void)out;
	return 0;
}

void msAesCbcHwEncrypt(const uint8_t* rk, int nr, const uint8_t iv[16], const uint8_t* in, size_t len, uint8_t* out) {
	(void)rk; (void)nr; (void)iv; (void)in; (void)len; (void)out;
}

void msAesCbcHwDecrypt(const uint8_t* rk, int nr, const uint8_t iv[16], const uint8_t* in, size_t len, uint8_t* out) {
	(void)rk; (void)nr; (void)iv; (void)in; (void)len; (void)out;
}

#endif
