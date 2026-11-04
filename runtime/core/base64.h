#ifndef MS_CORE_BASE64_H
#define MS_CORE_BASE64_H

#include <stddef.h>
#include <stdint.h>

#if defined(__aarch64__) && defined(__ARM_NEON)
#define MS_BASE64_NEON 1
#include <arm_neon.h>
#elif defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__)) && !defined(__EMSCRIPTEN__)
#define MS_BASE64_AVX2 1
#include <cpuid.h>
#include <immintrin.h>
#endif

static const uint8_t msBase64StdDigits[65] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static const uint8_t msBase64UrlDigits[65] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

static const uint8_t msBase64EitherValues[256] = {
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 62, 255, 62, 255, 63,
	52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 255, 255, 255, 255, 255, 255,
	255, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
	15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 255, 255, 255, 255, 63,
	255, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
	41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
};

static const uint8_t msBase64StdValues[256] = {
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 62, 255, 255, 255, 63,
	52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 255, 255, 255, 255, 255, 255,
	255, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
	15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 255, 255, 255, 255, 255,
	255, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
	41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
};

static inline void msBase64EncodeFrom(const uint8_t* src, int64_t i, int64_t n, uint8_t* out, int32_t url) {
	const uint8_t* digits = url ? msBase64UrlDigits : msBase64StdDigits;
	for (; i + 6 <= n; i += 6) {
		uint64_t w = ((uint64_t)src[i] << 40) | ((uint64_t)src[i + 1] << 32) | ((uint64_t)src[i + 2] << 24) |
			((uint64_t)src[i + 3] << 16) | ((uint64_t)src[i + 4] << 8) | (uint64_t)src[i + 5];
		out[0] = digits[(w >> 42) & 63];
		out[1] = digits[(w >> 36) & 63];
		out[2] = digits[(w >> 30) & 63];
		out[3] = digits[(w >> 24) & 63];
		out[4] = digits[(w >> 18) & 63];
		out[5] = digits[(w >> 12) & 63];
		out[6] = digits[(w >> 6) & 63];
		out[7] = digits[w & 63];
		out += 8;
	}
	for (; i + 3 <= n; i += 3) {
		uint32_t w = ((uint32_t)src[i] << 16) | ((uint32_t)src[i + 1] << 8) | (uint32_t)src[i + 2];
		out[0] = digits[w >> 18];
		out[1] = digits[(w >> 12) & 63];
		out[2] = digits[(w >> 6) & 63];
		out[3] = digits[w & 63];
		out += 4;
	}
	int64_t rest = n - i;
	if (rest == 0) return;
	uint32_t a = src[i];
	uint32_t b = rest == 2 ? src[i + 1] : 0;
	out[0] = digits[a >> 2];
	out[1] = digits[((a & 3) << 4) | (b >> 4)];
	if (rest == 2) out[2] = digits[(b & 15) << 2];
	if (!url) {
		if (rest == 1) out[2] = '=';
		out[3] = '=';
	}
}

static inline int64_t msBase64DecodeFrom(const uint8_t* text, int64_t i, int64_t n, uint8_t* out, int64_t k, int64_t limit, int32_t standardOnly) {
	const uint8_t* values = standardOnly ? msBase64StdValues : msBase64EitherValues;
	for (; i + 4 <= n && k + 3 <= limit; i += 4, k += 3) {
		uint32_t a = values[text[i]];
		uint32_t b = values[text[i + 1]];
		uint32_t c = values[text[i + 2]];
		uint32_t d = values[text[i + 3]];
		if ((a | b | c | d) & 0x80) break;
		uint32_t w = (a << 18) | (b << 12) | (c << 6) | d;
		out[k] = (uint8_t)(w >> 16);
		out[k + 1] = (uint8_t)(w >> 8);
		out[k + 2] = (uint8_t)w;
	}
	uint32_t phase = 0;
	uint32_t hi = 0;
	while (i < n && k < limit) {
		uint8_t byte = text[i++];
		uint32_t lo = values[byte];
		if (lo & 0x80) {
			if (byte == '=') break;
			continue;
		}
		if (phase == 1) out[k++] = (uint8_t)(((hi & 0x3F) << 2) | (lo >> 4));
		else if (phase == 2) out[k++] = (uint8_t)(((hi & 0x0F) << 4) | (lo >> 2));
		else if (phase == 3) out[k++] = (uint8_t)(((hi & 0x03) << 6) | lo);
		hi = lo;
		phase = (phase + 1) & 3;
	}
	return k;
}

static inline void msBase64EncodeScalar(const uint8_t* src, int64_t n, uint8_t* out, int32_t url) {
	msBase64EncodeFrom(src, 0, n, out, url);
}

static inline int64_t msBase64DecodeScalar(const uint8_t* text, int64_t n, uint8_t* out, int64_t limit, int32_t standardOnly) {
	return msBase64DecodeFrom(text, 0, n, out, 0, limit, standardOnly);
}

#if defined(MS_BASE64_NEON)

static inline void msBase64NeonEncode48(const uint8_t* src, uint8_t* out, uint8x16x4_t lut) {
	const uint8x16_t low6 = vdupq_n_u8(63);
	uint8x16x3_t in = vld3q_u8(src);
	uint8x16x4_t o;
	o.val[0] = vqtbl4q_u8(lut, vshrq_n_u8(in.val[0], 2));
	o.val[1] = vqtbl4q_u8(lut, vandq_u8(vsliq_n_u8(vshrq_n_u8(in.val[1], 4), in.val[0], 4), low6));
	o.val[2] = vqtbl4q_u8(lut, vandq_u8(vsliq_n_u8(vshrq_n_u8(in.val[2], 6), in.val[1], 2), low6));
	o.val[3] = vqtbl4q_u8(lut, vandq_u8(in.val[2], low6));
	vst4q_u8(out, o);
}

static inline void msBase64Encode(const uint8_t* src, int64_t n, uint8_t* out, int32_t url) {
	const uint8_t* digits = url ? msBase64UrlDigits : msBase64StdDigits;
	uint8x16x4_t lut = {{vld1q_u8(digits), vld1q_u8(digits + 16), vld1q_u8(digits + 32), vld1q_u8(digits + 48)}};
	int64_t i = 0;
	for (; i + 96 <= n; i += 96, out += 128) {
		msBase64NeonEncode48(src + i, out, lut);
		msBase64NeonEncode48(src + i + 48, out + 64, lut);
	}
	for (; i + 48 <= n; i += 48, out += 64) msBase64NeonEncode48(src + i, out, lut);
	msBase64EncodeFrom(src, i, n, out, url);
}

typedef struct {
	uint8x16_t invalidByLow;
	uint8x16_t classByHigh;
	uint8x16_t roll;
} msBase64NeonAlphabet;

static inline uint8x16_t msBase64NeonValues(uint8x16_t c, uint8x16_t rollAt, const msBase64NeonAlphabet* t, uint8x16_t* bad) {
	uint8x16_t high = vshrq_n_u8(c, 4);
	*bad = vorrq_u8(*bad, vandq_u8(vqtbl1q_u8(t->invalidByLow, vandq_u8(c, vdupq_n_u8(0x0f))), vqtbl1q_u8(t->classByHigh, high)));
	return vaddq_u8(c, vqtbl1q_u8(t->roll, vaddq_u8(rollAt, high)));
}

static inline int msBase64NeonBlock(uint8x16x4_t c, const msBase64NeonAlphabet* t, uint8x16_t rollChar, uint8x16_t rollStep, uint8x16x4_t* v) {
	uint8x16_t bad = vdupq_n_u8(0);
	v->val[0] = msBase64NeonValues(c.val[0], vandq_u8(vceqq_u8(c.val[0], rollChar), rollStep), t, &bad);
	v->val[1] = msBase64NeonValues(c.val[1], vandq_u8(vceqq_u8(c.val[1], rollChar), rollStep), t, &bad);
	v->val[2] = msBase64NeonValues(c.val[2], vandq_u8(vceqq_u8(c.val[2], rollChar), rollStep), t, &bad);
	v->val[3] = msBase64NeonValues(c.val[3], vandq_u8(vceqq_u8(c.val[3], rollChar), rollStep), t, &bad);
	return vmaxvq_u8(bad) == 0;
}

static inline int64_t msBase64Decode(const uint8_t* text, int64_t n, uint8_t* out, int64_t limit, int32_t standardOnly) {
	static const uint8_t classByHigh[16] = {0x20, 0x20, 0x01, 0x02, 0x04, 0x08, 0x04, 0x10, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20};
	static const uint8_t stdInvalidByLow[16] = {0x25, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x23, 0x3A, 0x3B, 0x3B, 0x3B, 0x3A};
	static const uint8_t stdRoll[16] = {0, 16, 19, 4, 191, 191, 185, 185, 0, 0, 0, 0, 0, 0, 0, 0};
	static const uint8_t urlInvalidByLow[16] = {0x25, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x23, 0x3B, 0x3B, 0x3A, 0x3B, 0x33};
	static const uint8_t urlRoll[16] = {0, 0, 17, 4, 191, 191, 185, 185, 224, 0, 0, 0, 0, 0, 0, 0};
	msBase64NeonAlphabet std = {vld1q_u8(stdInvalidByLow), vld1q_u8(classByHigh), vld1q_u8(stdRoll)};
	msBase64NeonAlphabet url = {vld1q_u8(urlInvalidByLow), vld1q_u8(classByHigh), vld1q_u8(urlRoll)};
	const uint8x16_t slash = vdupq_n_u8('/');
	const uint8x16_t underscore = vdupq_n_u8('_');
	const uint8x16_t minusOne = vdupq_n_u8(255);
	const uint8x16_t three = vdupq_n_u8(3);
	int64_t i = 0;
	int64_t k = 0;
	for (; i + 64 <= n && k + 48 <= limit; i += 64, k += 48) {
		uint8x16x4_t c = vld4q_u8(text + i);
		uint8x16x4_t v;
		if (!msBase64NeonBlock(c, &std, slash, minusOne, &v) &&
				(standardOnly || !msBase64NeonBlock(c, &url, underscore, three, &v))) {
			break;
		}
		uint8x16x3_t o;
		o.val[0] = vorrq_u8(vshlq_n_u8(v.val[0], 2), vshrq_n_u8(v.val[1], 4));
		o.val[1] = vorrq_u8(vshlq_n_u8(v.val[1], 4), vshrq_n_u8(v.val[2], 2));
		o.val[2] = vorrq_u8(vshlq_n_u8(v.val[2], 6), v.val[3]);
		vst3q_u8(out + k, o);
	}
	return msBase64DecodeFrom(text, i, n, out, k, limit, standardOnly);
}

#elif defined(MS_BASE64_AVX2)

static inline int msBase64HasAvx2(void) {
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

__attribute__((target("avx2"))) static inline int64_t msBase64EncodeAvx2(const uint8_t* src, int64_t n, uint8_t* out, int32_t url) {
	const __m256i spread = _mm256_setr_epi8(
		1, 0, 2, 1, 4, 3, 5, 4, 7, 6, 8, 7, 10, 9, 11, 10,
		1, 0, 2, 1, 4, 3, 5, 4, 7, 6, 8, 7, 10, 9, 11, 10);
	const __m256i shift = url
		? _mm256_setr_epi8(71, -4, -4, -4, -4, -4, -4, -4, -4, -4, -4, -17, 32, 65, 0, 0,
			71, -4, -4, -4, -4, -4, -4, -4, -4, -4, -4, -17, 32, 65, 0, 0)
		: _mm256_setr_epi8(71, -4, -4, -4, -4, -4, -4, -4, -4, -4, -4, -19, -16, 65, 0, 0,
			71, -4, -4, -4, -4, -4, -4, -4, -4, -4, -4, -19, -16, 65, 0, 0);
	const __m256i maskHigh = _mm256_set1_epi32(0x0fc0fc00);
	const __m256i mulHigh = _mm256_set1_epi32(0x04000040);
	const __m256i maskLow = _mm256_set1_epi32(0x003f03f0);
	const __m256i mulLow = _mm256_set1_epi32(0x01000010);
	const __m256i fiftyOne = _mm256_set1_epi8(51);
	const __m256i twentySix = _mm256_set1_epi8(26);
	const __m256i thirteen = _mm256_set1_epi8(13);
	int64_t i = 0;
	for (; i + 28 <= n; i += 24) {
		__m128i lo = _mm_loadu_si128((const __m128i*)(src + i));
		__m128i hi = _mm_loadu_si128((const __m128i*)(src + i + 12));
		__m256i in = _mm256_shuffle_epi8(_mm256_inserti128_si256(_mm256_castsi128_si256(lo), hi, 1), spread);
		__m256i indices = _mm256_or_si256(
			_mm256_mulhi_epu16(_mm256_and_si256(in, maskHigh), mulHigh),
			_mm256_mullo_epi16(_mm256_and_si256(in, maskLow), mulLow));
		__m256i r = _mm256_subs_epu8(indices, fiftyOne);
		r = _mm256_or_si256(r, _mm256_and_si256(_mm256_cmpgt_epi8(twentySix, indices), thirteen));
		r = _mm256_add_epi8(_mm256_shuffle_epi8(shift, r), indices);
		_mm256_storeu_si256((__m256i*)out, r);
		out += 32;
	}
	return i;
}

typedef struct {
	__m256i invalidByLow;
	__m256i classByHigh;
	__m256i roll;
	__m256i rollChar;
	__m256i rollStep;
} msBase64Avx2Alphabet;

__attribute__((target("avx2"))) static inline __m256i msBase64Avx2Values(__m256i c, const msBase64Avx2Alphabet* t, __m256i* bad) {
	const __m256i nibble = _mm256_set1_epi8(0x0f);
	__m256i high = _mm256_and_si256(_mm256_srli_epi32(c, 4), nibble);
	*bad = _mm256_or_si256(*bad, _mm256_and_si256(_mm256_shuffle_epi8(t->invalidByLow, _mm256_and_si256(c, nibble)),
		_mm256_shuffle_epi8(t->classByHigh, high)));
	__m256i rollAt = _mm256_add_epi8(_mm256_and_si256(_mm256_cmpeq_epi8(c, t->rollChar), t->rollStep), high);
	return _mm256_add_epi8(c, _mm256_shuffle_epi8(t->roll, rollAt));
}

__attribute__((target("avx2"))) static inline __m256i msBase64Avx2Pack(__m256i v) {
	const __m256i order = _mm256_setr_epi8(
		2, 1, 0, 6, 5, 4, 10, 9, 8, 14, 13, 12, -1, -1, -1, -1,
		2, 1, 0, 6, 5, 4, 10, 9, 8, 14, 13, 12, -1, -1, -1, -1);
	__m256i packed = _mm256_madd_epi16(_mm256_maddubs_epi16(v, _mm256_set1_epi32(0x01400140)), _mm256_set1_epi32(0x00011000));
	return _mm256_permutevar8x32_epi32(_mm256_shuffle_epi8(packed, order), _mm256_setr_epi32(0, 1, 2, 4, 5, 6, 7, 7));
}

__attribute__((target("avx2"))) static inline void msBase64Avx2Store24(uint8_t* out, __m256i packed) {
	_mm_storeu_si128((__m128i*)out, _mm256_castsi256_si128(packed));
	_mm_storel_epi64((__m128i*)(out + 16), _mm256_extracti128_si256(packed, 1));
}

__attribute__((target("avx2"))) static inline int64_t msBase64DecodeAvx2(const uint8_t* text, int64_t n, uint8_t* out, int64_t limit, int32_t standardOnly, int64_t* written) {
	const __m256i classByHigh = _mm256_setr_epi8(
		0x20, 0x20, 0x01, 0x02, 0x04, 0x08, 0x04, 0x10, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
		0x20, 0x20, 0x01, 0x02, 0x04, 0x08, 0x04, 0x10, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20);
	const msBase64Avx2Alphabet std = {
		_mm256_setr_epi8(
			0x25, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x23, 0x3A, 0x3B, 0x3B, 0x3B, 0x3A,
			0x25, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x23, 0x3A, 0x3B, 0x3B, 0x3B, 0x3A),
		classByHigh,
		_mm256_setr_epi8(
			0, 16, 19, 4, -65, -65, -71, -71, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 16, 19, 4, -65, -65, -71, -71, 0, 0, 0, 0, 0, 0, 0, 0),
		_mm256_set1_epi8('/'),
		_mm256_set1_epi8(-1),
	};
	const msBase64Avx2Alphabet url = {
		_mm256_setr_epi8(
			0x25, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x23, 0x3B, 0x3B, 0x3A, 0x3B, 0x33,
			0x25, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x23, 0x3B, 0x3B, 0x3A, 0x3B, 0x33),
		classByHigh,
		_mm256_setr_epi8(
			0, 0, 17, 4, -65, -65, -71, -71, -32, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 17, 4, -65, -65, -71, -71, -32, 0, 0, 0, 0, 0, 0, 0),
		_mm256_set1_epi8('_'),
		_mm256_set1_epi8(3),
	};
	int64_t i = 0;
	int64_t k = 0;
	for (; i + 64 <= n && k + 48 <= limit; i += 64, k += 48) {
		__m256i c0 = _mm256_loadu_si256((const __m256i*)(text + i));
		__m256i c1 = _mm256_loadu_si256((const __m256i*)(text + i + 32));
		__m256i bad = _mm256_setzero_si256();
		__m256i v0 = msBase64Avx2Values(c0, &std, &bad);
		__m256i v1 = msBase64Avx2Values(c1, &std, &bad);
		if (!_mm256_testz_si256(bad, bad)) {
			if (standardOnly) break;
			bad = _mm256_setzero_si256();
			v0 = msBase64Avx2Values(c0, &url, &bad);
			v1 = msBase64Avx2Values(c1, &url, &bad);
			if (!_mm256_testz_si256(bad, bad)) break;
		}
		_mm256_storeu_si256((__m256i*)(out + k), msBase64Avx2Pack(v0));
		msBase64Avx2Store24(out + k + 24, msBase64Avx2Pack(v1));
	}
	*written = k;
	return i;
}

static inline void msBase64Encode(const uint8_t* src, int64_t n, uint8_t* out, int32_t url) {
	int64_t i = msBase64HasAvx2() ? msBase64EncodeAvx2(src, n, out, url) : 0;
	msBase64EncodeFrom(src, i, n, out + i / 3 * 4, url);
}

static inline int64_t msBase64Decode(const uint8_t* text, int64_t n, uint8_t* out, int64_t limit, int32_t standardOnly) {
	int64_t k = 0;
	int64_t i = msBase64HasAvx2() ? msBase64DecodeAvx2(text, n, out, limit, standardOnly, &k) : 0;
	return msBase64DecodeFrom(text, i, n, out, k, limit, standardOnly);
}

#else

static inline void msBase64Encode(const uint8_t* src, int64_t n, uint8_t* out, int32_t url) {
	msBase64EncodeFrom(src, 0, n, out, url);
}

static inline int64_t msBase64Decode(const uint8_t* text, int64_t n, uint8_t* out, int64_t limit, int32_t standardOnly) {
	return msBase64DecodeFrom(text, 0, n, out, 0, limit, standardOnly);
}

#endif

#endif
