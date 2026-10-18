#include "runtime/core/system.h"
#include "guardFuzz.h"

static uint64_t gfState = 88172645463325252ull;
static int64_t gfStops = 0;
static int64_t gfFast = 0;

static uint64_t gfNext(void) {
	gfState ^= gfState << 13;
	gfState ^= gfState >> 7;
	gfState ^= gfState << 17;
	return gfState;
}

static int64_t gfPick(int mode, int bits) {
	uint64_t r = gfNext();
	int64_t max = bits == 64 ? INT64_MAX : ((int64_t)1 << (bits - 1)) - 1;
	int64_t min = -max - 1;
	switch (mode) {
	case 0: return bits == 64 ? (int64_t)r : (int64_t)(r % ((uint64_t)max - (uint64_t)min + 1)) + min;
	case 1: return (int64_t)(r % 21) - 10;
	case 2: {
		int64_t edges[] = {max, min, max - 1, min + 1, 0, 1, -1};
		return edges[r % 7];
	}
	case 3: {
		int64_t lim = max / 2048 + 1;
		return (int64_t)(r % (uint64_t)(2 * lim + 1)) - lim;
	}
	default: {
		int64_t v = bits == 64 ? (int64_t)(r >> 1) : (int64_t)(r % ((uint64_t)max + 1));
		v >>= r % (uint64_t)bits;
		return (r & 1) ? v : -v - (int64_t)((r >> 1) & 1);
	}
	}
}

static int64_t gfLength(int64_t t) {
	return (int64_t)(gfNext() % (t % 10 == 0 ? 5000 : 40));
}

#define GF_SUM(A, AT, AW, E, ET, EW) \
typedef MS_ARRAY(ET) gfArr##A##E; \
static int gfRef##A##E(AT acc, const ET* x, int64_t n, int sub, AT* out, int64_t* at) { \
	for (int64_t i = 0; i < n; i++) { \
		if (sub ? __builtin_sub_overflow(acc, (AT)x[i], &acc) : __builtin_add_overflow(acc, (AT)x[i], &acc)) { *at = i; return 1; } \
	} \
	*out = acc; \
	return 0; \
} \
static int gfBlk##A##E(AT acc, gfArr##A##E a, int sub, AT* out, int64_t* at) { \
	for (int64_t i = 0; i < a.len;) { \
		int64_t e = msBlockEnd(i, a.len); \
		if (msSumFits##A##E(acc, a, i, e)) { \
			gfFast++; \
			acc = sub ? msSumSub##A##E(acc, a, i, e) : msSumAdd##A##E(acc, a, i, e); \
			i = e; \
			continue; \
		} \
		for (; i < e; i++) { \
			if (sub ? __builtin_sub_overflow(acc, (AT)a.p->data[i], &acc) : __builtin_add_overflow(acc, (AT)a.p->data[i], &acc)) { *at = i; return 1; } \
		} \
	} \
	*out = acc; \
	return 0; \
} \
static int64_t gfFuzz##A##E(int64_t cases) { \
	int64_t bad = 0; \
	gfArr##A##E a; \
	a.p = malloc(sizeof(*a.p) + 5000 * sizeof(ET)); \
	for (int64_t t = 0; t < cases; t++) { \
		int64_t n = gfLength(t); \
		int mode = (int)(gfNext() % 5); \
		for (int64_t i = 0; i < n; i++) a.p->data[i] = (ET)gfPick(gfNext() % 3 == 0 ? mode : 1, EW); \
		a.len = n; \
		AT acc = (AT)gfPick(gfNext() % 2 ? 1 : mode, AW); \
		int sub = (int)(gfNext() & 1); \
		AT r1 = 0, r2 = 0; \
		int64_t i1 = -1, i2 = -1; \
		int s1 = gfRef##A##E(acc, a.p->data, n, sub, &r1, &i1); \
		int s2 = gfBlk##A##E(acc, a, sub, &r2, &i2); \
		gfStops += s1; \
		if (s1 != s2 || (!s1 && r1 != r2) || (s1 && i1 != i2)) bad++; \
	} \
	free(a.p); \
	return bad; \
}
GF_SUM(I8, int8_t, 8, I8, int8_t, 8)
GF_SUM(I16, int16_t, 16, I8, int8_t, 8)
GF_SUM(I16, int16_t, 16, I16, int16_t, 16)
GF_SUM(I32, int32_t, 32, I8, int8_t, 8)
GF_SUM(I32, int32_t, 32, I16, int16_t, 16)
GF_SUM(I32, int32_t, 32, I32, int32_t, 32)
GF_SUM(I64, int64_t, 64, I8, int8_t, 8)
GF_SUM(I64, int64_t, 64, I16, int16_t, 16)
GF_SUM(I64, int64_t, 64, I32, int32_t, 32)
GF_SUM(I64, int64_t, 64, I64, int64_t, 64)

#define GF_DOT(T, ET, W) \
typedef MS_ARRAY(ET) gfDot##T; \
static int gfDotRef##T(ET acc, const ET* x, const ET* y, int64_t n, int sub, ET* out, int64_t* at) { \
	ET p; \
	for (int64_t i = 0; i < n; i++) { \
		if (__builtin_mul_overflow(x[i], y[i], &p) || (sub ? __builtin_sub_overflow(acc, p, &acc) : __builtin_add_overflow(acc, p, &acc))) { *at = i; return 1; } \
	} \
	*out = acc; \
	return 0; \
} \
static int gfDotBlk##T(ET acc, gfDot##T a, gfDot##T b, int sub, ET* out, int64_t* at) { \
	ET p; \
	for (int64_t i = 0; i < a.len;) { \
		int64_t e = msBlockEnd(i, a.len); \
		if (msDotFits##T(acc, a, b, i, e)) { \
			gfFast++; \
			acc = sub ? msDotSub##T(acc, a, b, i, e) : msDotAdd##T(acc, a, b, i, e); \
			i = e; \
			continue; \
		} \
		for (; i < e; i++) { \
			if (__builtin_mul_overflow(a.p->data[i], b.p->data[i], &p) || (sub ? __builtin_sub_overflow(acc, p, &acc) : __builtin_add_overflow(acc, p, &acc))) { *at = i; return 1; } \
		} \
	} \
	*out = acc; \
	return 0; \
} \
static int64_t gfDotFuzz##T(int64_t cases) { \
	int64_t bad = 0; \
	gfDot##T a, b; \
	a.p = malloc(sizeof(*a.p) + 5000 * sizeof(ET)); \
	b.p = malloc(sizeof(*b.p) + 5000 * sizeof(ET)); \
	for (int64_t t = 0; t < cases; t++) { \
		int64_t n = gfLength(t); \
		int mode = (int)(gfNext() % 5); \
		for (int64_t i = 0; i < n; i++) { \
			a.p->data[i] = (ET)gfPick(gfNext() % 3 == 0 ? mode : 1, W); \
			b.p->data[i] = (ET)gfPick(gfNext() % 3 == 0 ? mode : 1, W); \
		} \
		a.len = n; \
		b.len = n; \
		ET acc = (ET)gfPick(gfNext() % 2 ? 1 : mode, W); \
		int sub = (int)(gfNext() & 1); \
		ET r1 = 0, r2 = 0; \
		int64_t i1 = -1, i2 = -1; \
		int s1 = gfDotRef##T(acc, a.p->data, b.p->data, n, sub, &r1, &i1); \
		int s2 = gfDotBlk##T(acc, a, b, sub, &r2, &i2); \
		gfStops += s1; \
		if (s1 != s2 || (!s1 && r1 != r2) || (s1 && i1 != i2)) bad++; \
	} \
	free(a.p); \
	free(b.p); \
	return bad; \
}
GF_DOT(I8, int8_t, 8)
GF_DOT(I16, int16_t, 16)
GF_DOT(I32, int32_t, 32)
GF_DOT(I64, int64_t, 64)

int64_t msTestBlockReduceMismatches(int64_t cases) {
	return gfFuzzI8I8(cases) + gfFuzzI16I8(cases) + gfFuzzI16I16(cases) + gfFuzzI32I8(cases) + gfFuzzI32I16(cases)
		+ gfFuzzI32I32(cases) + gfFuzzI64I8(cases) + gfFuzzI64I16(cases) + gfFuzzI64I32(cases) + gfFuzzI64I64(cases)
		+ gfDotFuzzI8(cases) + gfDotFuzzI16(cases) + gfDotFuzzI32(cases) + gfDotFuzzI64(cases);
}

int64_t msTestBlockReduceStops(void) { return gfStops; }
int64_t msTestBlockReduceFastBlocks(void) { return gfFast; }
