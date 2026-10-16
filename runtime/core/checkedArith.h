/*
 * Checked integer arithmetic, division, modulo and power, ToInt32, the float power, and the
 * compound assignments C has no operator for on a float target. The includer declares
 * msRaiseDivByZero, msRaiseOverflow and msRaiseRangeError first
 * (runtime/core/system.h, runtime/manual.h).
 */
#ifndef MS_CHECKED_ARITH_H
#define MS_CHECKED_ARITH_H

#include <math.h>
#include <stdint.h>

static inline int32_t msDivI32(int32_t a, int32_t b) {
	if (b == 0) msRaiseDivByZero();
	if (b == -1 && a == INT32_MIN) msRaiseOverflow();
	return a / b;
}

static inline int32_t msModI32(int32_t a, int32_t b) {
	if (b == 0) msRaiseDivByZero();
	return b == -1 ? 0 : a % b;
}

static inline int64_t msDivI64(int64_t a, int64_t b) {
	if (b == 0) msRaiseDivByZero();
	if (b == -1 && a == INT64_MIN) msRaiseOverflow();
	return a / b;
}

static inline int64_t msModI64(int64_t a, int64_t b) {
	if (b == 0) msRaiseDivByZero();
	return b == -1 ? 0 : a % b;
}

static inline uint32_t msDivU32(uint32_t a, uint32_t b) {
	if (b == 0) msRaiseDivByZero();
	return a / b;
}

static inline uint32_t msModU32(uint32_t a, uint32_t b) {
	if (b == 0) msRaiseDivByZero();
	return a % b;
}

static inline uint64_t msDivU64(uint64_t a, uint64_t b) {
	if (b == 0) msRaiseDivByZero();
	return a / b;
}

static inline uint64_t msModU64(uint64_t a, uint64_t b) {
	if (b == 0) msRaiseDivByZero();
	return a % b;
}

#define msDivAssign_(lv, b, op) (*({ \
	__typeof__(lv)* __dap = &(lv); \
	*__dap = (__typeof__(lv))op(*__dap, (b)); \
	__dap; \
}))
#define msDivAssignI32(lv, b) msDivAssign_(lv, b, msDivI32)
#define msModAssignI32(lv, b) msDivAssign_(lv, b, msModI32)
#define msDivAssignI64(lv, b) msDivAssign_(lv, b, msDivI64)
#define msModAssignI64(lv, b) msDivAssign_(lv, b, msModI64)
#define msDivAssignU32(lv, b) msDivAssign_(lv, b, msDivU32)
#define msModAssignU32(lv, b) msDivAssign_(lv, b, msModU32)
#define msDivAssignU64(lv, b) msDivAssign_(lv, b, msDivU64)
#define msModAssignU64(lv, b) msDivAssign_(lv, b, msModU64)

static inline int64_t msPowI64(int64_t a, int64_t b) {
	if (b < 0) msRaiseRangeError(b, 0, INT64_MAX);
	int64_t r = 1;
	for (;;) {
		if ((b & 1) && __builtin_mul_overflow(r, a, &r)) msRaiseOverflow();
		b >>= 1;
		if (b == 0) return r;
		if (__builtin_mul_overflow(a, a, &a)) msRaiseOverflow();
	}
}

static inline int32_t msPowI32(int32_t a, int32_t b) {
	if (b < 0) msRaiseRangeError(b, 0, INT32_MAX);
	int32_t r = 1;
	for (;;) {
		if ((b & 1) && __builtin_mul_overflow(r, a, &r)) msRaiseOverflow();
		b >>= 1;
		if (b == 0) return r;
		if (__builtin_mul_overflow(a, a, &a)) msRaiseOverflow();
	}
}

static inline uint64_t msPowU64(uint64_t a, uint64_t b) {
	uint64_t r = 1;
	for (;;) {
		if ((b & 1) && __builtin_mul_overflow(r, a, &r)) msRaiseOverflow();
		b >>= 1;
		if (b == 0) return r;
		if (__builtin_mul_overflow(a, a, &a)) msRaiseOverflow();
	}
}

static inline uint32_t msPowU32(uint32_t a, uint32_t b) {
	uint32_t r = 1;
	for (;;) {
		if ((b & 1) && __builtin_mul_overflow(r, a, &r)) msRaiseOverflow();
		b >>= 1;
		if (b == 0) return r;
		if (__builtin_mul_overflow(a, a, &a)) msRaiseOverflow();
	}
}

/* A negative exponent truncates a^b toward zero, the value an integer slot
   keeps of the float TypeScript computes. */
static inline uint64_t msPowWrapU64(uint64_t a, uint64_t b) {
	uint64_t r = 1;
	while (b != 0) {
		if (b & 1) r *= a;
		b >>= 1;
		a *= a;
	}
	return r;
}

static inline int64_t msPowWrapI64(int64_t a, int64_t b) {
	if (b < 0) return a == 1 ? 1 : (a == -1 ? ((b & 1) ? -1 : 1) : 0);
	return (int64_t)msPowWrapU64((uint64_t)a, (uint64_t)b);
}

static inline int32_t msPowWrapI32(int32_t a, int32_t b) {
	if (b < 0) return a == 1 ? 1 : (a == -1 ? ((b & 1) ? -1 : 1) : 0);
	return (int32_t)(uint32_t)msPowWrapU64((uint64_t)(int64_t)a, (uint64_t)b);
}

static inline uint32_t msPowWrapU32(uint32_t a, uint32_t b) {
	return (uint32_t)msPowWrapU64(a, b);
}

#define msPowAssignI32(lv, b) msDivAssign_(lv, b, msPowI32)
#define msPowAssignI64(lv, b) msDivAssign_(lv, b, msPowI64)
#define msPowAssignU32(lv, b) msDivAssign_(lv, b, msPowU32)
#define msPowAssignU64(lv, b) msDivAssign_(lv, b, msPowU64)
#define msPowWrapAssignI32(lv, b) msDivAssign_(lv, b, msPowWrapI32)
#define msPowWrapAssignI64(lv, b) msDivAssign_(lv, b, msPowWrapI64)
#define msPowWrapAssignU32(lv, b) msDivAssign_(lv, b, msPowWrapU32)
#define msPowWrapAssignU64(lv, b) msDivAssign_(lv, b, msPowWrapU64)

static inline int32_t msToInt32(double x) {
	if (x > -2147483649.0 && x < 2147483648.0) return (int32_t)x;
	if (!isfinite(x)) return 0;
	double m = fmod(trunc(x), 4294967296.0);
	if (m < 0) m += 4294967296.0;
	return (int32_t)(uint32_t)m;
}

static inline int32_t msNumberAnd(double a, int32_t b) { return msToInt32(a) & b; }
static inline int32_t msNumberOr(double a, int32_t b) { return msToInt32(a) | b; }
static inline int32_t msNumberXor(double a, int32_t b) { return msToInt32(a) ^ b; }
static inline int32_t msNumberShl(double a, int32_t b) { return (int32_t)((uint32_t)msToInt32(a) << ((uint32_t)b & 31)); }
static inline int32_t msNumberShr(double a, int32_t b) { return msToInt32(a) >> ((uint32_t)b & 31); }
static inline uint32_t msNumberShrU(double a, int32_t b) { return (uint32_t)msToInt32(a) >> ((uint32_t)b & 31); }

/* ECMAScript Number::exponentiate (ES2024 6.1.6.1.3) as node computes it, to the bit.
 * Keep sqrt off --os=solana: SBF links no sqrt (runtime/freestanding/math.h only declares it). */
static inline double msPowF64(double x, double y) {
	if (y != y || (fabs(x) == 1.0 && fabs(y) == INFINITY)) return NAN;
	if (x != x) x = NAN;
	if (y == 2.0) return x * x;
#ifndef MSOS_SOLANA
	if (y == 0.5) return fabs(x) == INFINITY ? INFINITY : sqrt(x + 0.0);
#endif
	return pow(x, y);
}

#define msPowAssignF64(lv, b) msDivAssign_(lv, b, msPowF64)

/* A macro, not a typed function: the builtin checks the exact result of
   operands of any width against T, where a parameter would truncate them first. */
#define msOverflowChk_(T, builtin, a, b) ({ \
	T __ovr; \
	if (builtin((a), (b), &__ovr)) msRaiseOverflow(); \
	__ovr; \
})
#define msAddI8(a, b) msOverflowChk_(int8_t, __builtin_add_overflow, a, b)
#define msAddI16(a, b) msOverflowChk_(int16_t, __builtin_add_overflow, a, b)
#define msAddI32(a, b) msOverflowChk_(int32_t, __builtin_add_overflow, a, b)
#define msAddI64(a, b) msOverflowChk_(int64_t, __builtin_add_overflow, a, b)
#define msSubI8(a, b) msOverflowChk_(int8_t, __builtin_sub_overflow, a, b)
#define msSubI16(a, b) msOverflowChk_(int16_t, __builtin_sub_overflow, a, b)
#define msSubI32(a, b) msOverflowChk_(int32_t, __builtin_sub_overflow, a, b)
#define msSubI64(a, b) msOverflowChk_(int64_t, __builtin_sub_overflow, a, b)
#define msMulI8(a, b) msOverflowChk_(int8_t, __builtin_mul_overflow, a, b)
#define msMulI16(a, b) msOverflowChk_(int16_t, __builtin_mul_overflow, a, b)
#define msMulI32(a, b) msOverflowChk_(int32_t, __builtin_mul_overflow, a, b)
#define msMulI64(a, b) msOverflowChk_(int64_t, __builtin_mul_overflow, a, b)
#define msNegI8(a) msOverflowChk_(int8_t, __builtin_sub_overflow, 0, a)
#define msNegI16(a) msOverflowChk_(int16_t, __builtin_sub_overflow, 0, a)
#define msNegI32(a) msOverflowChk_(int32_t, __builtin_sub_overflow, 0, a)
#define msNegI64(a) msOverflowChk_(int64_t, __builtin_sub_overflow, 0, a)

#define msDivI8(a, b) msOverflowChk_(int8_t, __builtin_add_overflow, msDivI32(a, b), 0)
#define msDivI16(a, b) msOverflowChk_(int16_t, __builtin_add_overflow, msDivI32(a, b), 0)
#define msPowI8(a, b) msOverflowChk_(int8_t, __builtin_add_overflow, msPowI32(a, b), 0)
#define msPowI16(a, b) msOverflowChk_(int16_t, __builtin_add_overflow, msPowI32(a, b), 0)
#define msDivAssignI8(lv, b) msDivAssign_(lv, b, msDivI8)
#define msDivAssignI16(lv, b) msDivAssign_(lv, b, msDivI16)
#define msPowAssignI8(lv, b) msDivAssign_(lv, b, msPowI8)
#define msPowAssignI16(lv, b) msDivAssign_(lv, b, msPowI16)

#define msArithAssign_(lv, b, builtin) (*({ \
	__typeof__(lv)* __aap = &(lv); \
	if (builtin(*__aap, (b), __aap)) msRaiseOverflow(); \
	__aap; \
}))
#define msAddAssign(lv, b) msArithAssign_(lv, b, __builtin_add_overflow)
#define msSubAssign(lv, b) msArithAssign_(lv, b, __builtin_sub_overflow)
#define msMulAssign(lv, b) msArithAssign_(lv, b, __builtin_mul_overflow)
#define msPostStep_(lv, builtin) ({ \
	__typeof__(lv)* __psp = &(lv); \
	__typeof__(lv) __old = *__psp; \
	if (builtin(__old, 1, __psp)) msRaiseOverflow(); \
	__old; \
})
#define msPostInc(lv) msPostStep_(lv, __builtin_add_overflow)
#define msPostDec(lv) msPostStep_(lv, __builtin_sub_overflow)

#define msModAssignF64(lv, b) msDivAssign_(lv, b, fmod)
#define msAndAssignF64(lv, b) msDivAssign_(lv, b, msNumberAnd)
#define msOrAssignF64(lv, b) msDivAssign_(lv, b, msNumberOr)
#define msXorAssignF64(lv, b) msDivAssign_(lv, b, msNumberXor)
#define msShlAssignF64(lv, b) msDivAssign_(lv, b, msNumberShl)
#define msShrAssignF64(lv, b) msDivAssign_(lv, b, msNumberShr)
#define msShrUAssignF64(lv, b) msDivAssign_(lv, b, msNumberShrU)

#endif /* MS_CHECKED_ARITH_H */
