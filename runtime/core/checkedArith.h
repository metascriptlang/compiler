/*
 * Checked integer arithmetic, division and modulo, ToInt32, the float power, and the
 * compound assignments C has no operator for on a float target (integer power is
 * std/core/system). The includer declares msRaiseDivByZero and msRaiseOverflow first
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
#define msDivAssignI8(lv, b) msDivAssign_(lv, b, msDivI8)
#define msDivAssignI16(lv, b) msDivAssign_(lv, b, msDivI16)

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

static inline int64_t msBlockEndOf(int64_t b, int64_t len, int64_t size) {
	if (b < 0) return b + 1;
	return len - b > size ? b + size : len;
}
/* The installed msc that builds this tree's compiler still emits the two-argument form; drop it once
   tools/syncLocalBinary.ms has delivered a compiler that emits msBlockEndOf. */
#define msBlockEnd(b, len) msBlockEndOf(b, len, 1024)

#define msStickyOp_(T, op, a, b, bad) ({ T __r; (bad) |= op((T)(a), (T)(b), &__r); __r; })
#define msStickyWide_(T, op, a, b, bad) ({ int64_t __w = (int64_t)(T)(a) op (int64_t)(T)(b); (bad) |= __w != (int64_t)(T)__w; (T)__w; })
#define msStickyAddI8(a, b, bad) msStickyWide_(int8_t, +, a, b, bad)
#define msStickyAddI16(a, b, bad) msStickyWide_(int16_t, +, a, b, bad)
#define msStickyAddI32(a, b, bad) msStickyWide_(int32_t, +, a, b, bad)
#define msStickyAddI64(a, b, bad) msStickyOp_(int64_t, __builtin_add_overflow, a, b, bad)
#define msStickySubI8(a, b, bad) msStickyWide_(int8_t, -, a, b, bad)
#define msStickySubI16(a, b, bad) msStickyWide_(int16_t, -, a, b, bad)
#define msStickySubI32(a, b, bad) msStickyWide_(int32_t, -, a, b, bad)
#define msStickySubI64(a, b, bad) msStickyOp_(int64_t, __builtin_sub_overflow, a, b, bad)
#define msStickyMulI8(a, b, bad) msStickyWide_(int8_t, *, a, b, bad)
#define msStickyMulI16(a, b, bad) msStickyWide_(int16_t, *, a, b, bad)
#define msStickyMulI32(a, b, bad) msStickyWide_(int32_t, *, a, b, bad)
#define msStickyMulI64(a, b, bad) msStickyOp_(int64_t, __builtin_mul_overflow, a, b, bad)
#define msStickyNegI8(a, bad) msStickyWide_(int8_t, -, 0, a, bad)
#define msStickyNegI16(a, bad) msStickyWide_(int16_t, -, 0, a, bad)
#define msStickyNegI32(a, bad) msStickyWide_(int32_t, -, 0, a, bad)
#define msStickyNegI64(a, bad) msStickyOp_(int64_t, __builtin_sub_overflow, 0, a, bad)
#define msStickyRange_(v, lo, hi, bad) ({ int64_t __v = (int64_t)(v); (bad) |= (__v < (lo)) | (__v > (hi)); __v; })
#define msStickyRangeI8(v, lo, hi, bad) ((int8_t)msStickyRange_(v, lo, hi, bad))
#define msStickyRangeU8(v, lo, hi, bad) ((uint8_t)msStickyRange_(v, lo, hi, bad))
#define msStickyRangeI16(v, lo, hi, bad) ((int16_t)msStickyRange_(v, lo, hi, bad))
#define msStickyRangeU16(v, lo, hi, bad) ((uint16_t)msStickyRange_(v, lo, hi, bad))
#define msStickyRangeI32(v, lo, hi, bad) ((int32_t)msStickyRange_(v, lo, hi, bad))
#define msStickyRangeU32(v, lo, hi, bad) ((uint32_t)msStickyRange_(v, lo, hi, bad))
#define msStickyExactI64(v, bad) ({ int64_t __v = (v); (bad) |= (__v <= -9007199254740992LL) | (__v >= 9007199254740992LL); __v; })
#define msStickyAt(a, i, bad) ({ int64_t __i = (i); int __in = (uint64_t)__i < (uint64_t)(a).len; (bad) |= !__in; __in ? (a).p->data[__i] : 0; })
#define msStickySpanAt(s, i, bad) ({ int64_t __i = (i); int __in = (uint64_t)__i < (uint64_t)(s).len; (bad) |= !__in; __in ? (s).data[__i] : 0; })
/* After k of a block's n terms, each in [lo, hi], the partial sum lies between acc + n * min(lo, 0) and
   acc + n * max(hi, 0), so when both ends fit no step of the block overflows. */
static inline int msBlockRangeFits(int64_t acc, int64_t n, int64_t lo, int64_t hi, int sub, int64_t min, int64_t max) {
	if (n > (1LL << 20) || lo < -(1LL << 40) || hi > (1LL << 40)) return 0;
	int64_t down = n * (lo < 0 ? lo : 0), up = n * (hi > 0 ? hi : 0);
	return sub ? acc - up >= min && acc - down <= max : acc + down >= min && acc + up <= max;
}
static inline int64_t msBlockMagnitude(uint64_t bits) {
	if (bits > (uint64_t)INT64_MAX) return INT64_MAX;
	return bits == 0 ? 0 : (int64_t)(UINT64_MAX >> __builtin_clzll(bits));
}
#define msBlockWithin(a, b, e) ((b) >= 0 && (e) <= (int64_t)(a).len)
#define msBlockWithinSpan(s, b, e) ((b) >= 0 && (e) <= (int64_t)(s).len)
#define msBlockSumOf(acc, sum, sub) ((sub) ? (int64_t)(acc) - (sum) : (int64_t)(acc) + (sum))

static inline int msBlockFits_(uint64_t acc, uint64_t term, int64_t n, uint64_t max) {
	if (acc > max) return 0;
	return term <= (max - acc) / (uint64_t)n;
}

#define msAbsOf_(U, v) ((v) < 0 ? (U)0 - (U)(v) : (U)(v))
#define msArrayData_(a) ((a).len > 0 ? (a).p->data : NULL)

#define msOnesAbs_(x) ((x) ^ ((x) >> (sizeof(x) * 8 - 1)))
#define MS_SUM_TRY_(A, AT, UA, AMAX, E, ET, UE) \
static inline int msSumTry##A##E##_(AT* acc, int sub, int64_t len, const ET* p, int64_t b, int64_t e) { \
	if (b < 0 || e > len || e <= b) return 0; \
	UE o = 0; \
	UA s = 0; \
	for (int64_t i = b; i < e; i++) { \
		ET x = p[i]; \
		o |= (UE)msOnesAbs_(x); \
		s += (UA)(AT)x; \
	} \
	uint64_t a = msAbsOf_(uint64_t, *acc); \
	int k = o == 0 ? 0 : 64 - __builtin_clzll((uint64_t)o); \
	if (a > (uint64_t)(AMAX) || (uint64_t)(e - b) > ((uint64_t)(AMAX) - a) >> k) return 0; \
	*acc = (AT)(sub ? (UA)*acc - s : (UA)*acc + s); \
	return 1; \
}
MS_SUM_TRY_(I8, int8_t, uint32_t, INT8_MAX, I8, int8_t, uint8_t)
MS_SUM_TRY_(I16, int16_t, uint32_t, INT16_MAX, I8, int8_t, uint8_t)
MS_SUM_TRY_(I16, int16_t, uint32_t, INT16_MAX, I16, int16_t, uint16_t)
MS_SUM_TRY_(I32, int32_t, uint32_t, INT32_MAX, I8, int8_t, uint8_t)
MS_SUM_TRY_(I32, int32_t, uint32_t, INT32_MAX, I16, int16_t, uint16_t)
MS_SUM_TRY_(I32, int32_t, uint32_t, INT32_MAX, I32, int32_t, uint32_t)
MS_SUM_TRY_(I64, int64_t, uint64_t, INT64_MAX, I8, int8_t, uint8_t)
MS_SUM_TRY_(I64, int64_t, uint64_t, INT64_MAX, I16, int16_t, uint16_t)
MS_SUM_TRY_(I64, int64_t, uint64_t, INT64_MAX, I32, int32_t, uint32_t)
MS_SUM_TRY_(I64, int64_t, uint64_t, INT64_MAX, I64, int64_t, uint64_t)
#define msSumTry_(fn, sub, acc, a, b, e) fn(&(acc), (sub), (a).len, msArrayData_(a), (b), (e))
#define msSumTryAddI8I8(acc, a, b, e) msSumTry_(msSumTryI8I8_, 0, acc, a, b, e)
#define msSumTryAddI16I8(acc, a, b, e) msSumTry_(msSumTryI16I8_, 0, acc, a, b, e)
#define msSumTryAddI16I16(acc, a, b, e) msSumTry_(msSumTryI16I16_, 0, acc, a, b, e)
#define msSumTryAddI32I8(acc, a, b, e) msSumTry_(msSumTryI32I8_, 0, acc, a, b, e)
#define msSumTryAddI32I16(acc, a, b, e) msSumTry_(msSumTryI32I16_, 0, acc, a, b, e)
#define msSumTryAddI32I32(acc, a, b, e) msSumTry_(msSumTryI32I32_, 0, acc, a, b, e)
#define msSumTryAddI64I8(acc, a, b, e) msSumTry_(msSumTryI64I8_, 0, acc, a, b, e)
#define msSumTryAddI64I16(acc, a, b, e) msSumTry_(msSumTryI64I16_, 0, acc, a, b, e)
#define msSumTryAddI64I32(acc, a, b, e) msSumTry_(msSumTryI64I32_, 0, acc, a, b, e)
#define msSumTryAddI64I64(acc, a, b, e) msSumTry_(msSumTryI64I64_, 0, acc, a, b, e)
#define msSumTrySubI8I8(acc, a, b, e) msSumTry_(msSumTryI8I8_, 1, acc, a, b, e)
#define msSumTrySubI16I8(acc, a, b, e) msSumTry_(msSumTryI16I8_, 1, acc, a, b, e)
#define msSumTrySubI16I16(acc, a, b, e) msSumTry_(msSumTryI16I16_, 1, acc, a, b, e)
#define msSumTrySubI32I8(acc, a, b, e) msSumTry_(msSumTryI32I8_, 1, acc, a, b, e)
#define msSumTrySubI32I16(acc, a, b, e) msSumTry_(msSumTryI32I16_, 1, acc, a, b, e)
#define msSumTrySubI32I32(acc, a, b, e) msSumTry_(msSumTryI32I32_, 1, acc, a, b, e)
#define msSumTrySubI64I8(acc, a, b, e) msSumTry_(msSumTryI64I8_, 1, acc, a, b, e)
#define msSumTrySubI64I16(acc, a, b, e) msSumTry_(msSumTryI64I16_, 1, acc, a, b, e)
#define msSumTrySubI64I32(acc, a, b, e) msSumTry_(msSumTryI64I32_, 1, acc, a, b, e)
#define msSumTrySubI64I64(acc, a, b, e) msSumTry_(msSumTryI64I64_, 1, acc, a, b, e)

/* The installed msc that builds this tree's compiler still emits msSumFits, msSumAdd and msSumSub; drop them once
   tools/syncLocalBinary.ms has delivered a compiler that emits msSumTry. */
#define MS_SUM_BLOCK_(A, AT, UA, AMAX, E, ET, UE) \
static inline int msSumFits##A##E##_(AT acc, int64_t len, const ET* p, int64_t b, int64_t e) { \
	if (b < 0 || e > len || e <= b) return 0; \
	UE m = 0; \
	for (int64_t i = b; i < e; i++) { UE v = msAbsOf_(UE, p[i]); m = v > m ? v : m; } \
	return msBlockFits_(msAbsOf_(uint64_t, acc), m, e - b, AMAX); \
} \
static inline AT msSumAdd##A##E##_(AT acc, const ET* p, int64_t b, int64_t e) { \
	UA s = (UA)acc; \
	for (int64_t i = b; i < e; i++) s += (UA)(AT)p[i]; \
	return (AT)s; \
} \
static inline AT msSumSub##A##E##_(AT acc, const ET* p, int64_t b, int64_t e) { \
	UA s = (UA)acc; \
	for (int64_t i = b; i < e; i++) s -= (UA)(AT)p[i]; \
	return (AT)s; \
}
MS_SUM_BLOCK_(I8, int8_t, uint32_t, INT8_MAX, I8, int8_t, uint8_t)
MS_SUM_BLOCK_(I16, int16_t, uint32_t, INT16_MAX, I8, int8_t, uint8_t)
MS_SUM_BLOCK_(I16, int16_t, uint32_t, INT16_MAX, I16, int16_t, uint16_t)
MS_SUM_BLOCK_(I32, int32_t, uint32_t, INT32_MAX, I8, int8_t, uint8_t)
MS_SUM_BLOCK_(I32, int32_t, uint32_t, INT32_MAX, I16, int16_t, uint16_t)
MS_SUM_BLOCK_(I32, int32_t, uint32_t, INT32_MAX, I32, int32_t, uint32_t)
MS_SUM_BLOCK_(I64, int64_t, uint64_t, INT64_MAX, I8, int8_t, uint8_t)
MS_SUM_BLOCK_(I64, int64_t, uint64_t, INT64_MAX, I16, int16_t, uint16_t)
MS_SUM_BLOCK_(I64, int64_t, uint64_t, INT64_MAX, I32, int32_t, uint32_t)
MS_SUM_BLOCK_(I64, int64_t, uint64_t, INT64_MAX, I64, int64_t, uint64_t)
#define msSumFits_(fn, acc, a, b, e) fn((acc), (a).len, msArrayData_(a), (b), (e))
#define msSumRun_(fn, acc, a, b, e) fn((acc), msArrayData_(a), (b), (e))
#define msSumFitsI8I8(acc, a, b, e) msSumFits_(msSumFitsI8I8_, acc, a, b, e)
#define msSumFitsI16I8(acc, a, b, e) msSumFits_(msSumFitsI16I8_, acc, a, b, e)
#define msSumFitsI16I16(acc, a, b, e) msSumFits_(msSumFitsI16I16_, acc, a, b, e)
#define msSumFitsI32I8(acc, a, b, e) msSumFits_(msSumFitsI32I8_, acc, a, b, e)
#define msSumFitsI32I16(acc, a, b, e) msSumFits_(msSumFitsI32I16_, acc, a, b, e)
#define msSumFitsI32I32(acc, a, b, e) msSumFits_(msSumFitsI32I32_, acc, a, b, e)
#define msSumFitsI64I8(acc, a, b, e) msSumFits_(msSumFitsI64I8_, acc, a, b, e)
#define msSumFitsI64I16(acc, a, b, e) msSumFits_(msSumFitsI64I16_, acc, a, b, e)
#define msSumFitsI64I32(acc, a, b, e) msSumFits_(msSumFitsI64I32_, acc, a, b, e)
#define msSumFitsI64I64(acc, a, b, e) msSumFits_(msSumFitsI64I64_, acc, a, b, e)
#define msSumAddI8I8(acc, a, b, e) msSumRun_(msSumAddI8I8_, acc, a, b, e)
#define msSumAddI16I8(acc, a, b, e) msSumRun_(msSumAddI16I8_, acc, a, b, e)
#define msSumAddI16I16(acc, a, b, e) msSumRun_(msSumAddI16I16_, acc, a, b, e)
#define msSumAddI32I8(acc, a, b, e) msSumRun_(msSumAddI32I8_, acc, a, b, e)
#define msSumAddI32I16(acc, a, b, e) msSumRun_(msSumAddI32I16_, acc, a, b, e)
#define msSumAddI32I32(acc, a, b, e) msSumRun_(msSumAddI32I32_, acc, a, b, e)
#define msSumAddI64I8(acc, a, b, e) msSumRun_(msSumAddI64I8_, acc, a, b, e)
#define msSumAddI64I16(acc, a, b, e) msSumRun_(msSumAddI64I16_, acc, a, b, e)
#define msSumAddI64I32(acc, a, b, e) msSumRun_(msSumAddI64I32_, acc, a, b, e)
#define msSumAddI64I64(acc, a, b, e) msSumRun_(msSumAddI64I64_, acc, a, b, e)
#define msSumSubI8I8(acc, a, b, e) msSumRun_(msSumSubI8I8_, acc, a, b, e)
#define msSumSubI16I8(acc, a, b, e) msSumRun_(msSumSubI16I8_, acc, a, b, e)
#define msSumSubI16I16(acc, a, b, e) msSumRun_(msSumSubI16I16_, acc, a, b, e)
#define msSumSubI32I8(acc, a, b, e) msSumRun_(msSumSubI32I8_, acc, a, b, e)
#define msSumSubI32I16(acc, a, b, e) msSumRun_(msSumSubI32I16_, acc, a, b, e)
#define msSumSubI32I32(acc, a, b, e) msSumRun_(msSumSubI32I32_, acc, a, b, e)
#define msSumSubI64I8(acc, a, b, e) msSumRun_(msSumSubI64I8_, acc, a, b, e)
#define msSumSubI64I16(acc, a, b, e) msSumRun_(msSumSubI64I16_, acc, a, b, e)
#define msSumSubI64I32(acc, a, b, e) msSumRun_(msSumSubI64I32_, acc, a, b, e)
#define msSumSubI64I64(acc, a, b, e) msSumRun_(msSumSubI64I64_, acc, a, b, e)

/* Keep UW at 32 bits or more: two uint16_t operands promote to int, whose product overflows. */
#define MS_DOT_BLOCK_(T, ET, UE, UW, MAX) \
static inline int msDotFits##T##_(ET acc, int64_t alen, const ET* p, int64_t blen, const ET* q, int64_t s, int64_t e) { \
	if (s < 0 || e > alen || e > blen || e <= s) return 0; \
	UE ma = 0, mb = 0; \
	for (int64_t i = s; i < e; i++) { \
		UE x = msAbsOf_(UE, p[i]), y = msAbsOf_(UE, q[i]); \
		ma = x > ma ? x : ma; \
		mb = y > mb ? y : mb; \
	} \
	uint64_t a = msAbsOf_(uint64_t, acc); \
	if (a > (uint64_t)(MAX)) return 0; \
	uint64_t room = ((uint64_t)(MAX) - a) / (uint64_t)(e - s); \
	return ma == 0 || (uint64_t)mb <= room / (uint64_t)ma; \
} \
static inline ET msDotAdd##T##_(ET acc, const ET* p, const ET* q, int64_t s, int64_t e) { \
	UW r = (UW)acc; \
	for (int64_t i = s; i < e; i++) r += (UW)p[i] * (UW)q[i]; \
	return (ET)r; \
} \
static inline ET msDotSub##T##_(ET acc, const ET* p, const ET* q, int64_t s, int64_t e) { \
	UW r = (UW)acc; \
	for (int64_t i = s; i < e; i++) r -= (UW)p[i] * (UW)q[i]; \
	return (ET)r; \
}
MS_DOT_BLOCK_(I8, int8_t, uint8_t, uint32_t, INT8_MAX)
MS_DOT_BLOCK_(I16, int16_t, uint16_t, uint32_t, INT16_MAX)
MS_DOT_BLOCK_(I32, int32_t, uint32_t, uint32_t, INT32_MAX)
MS_DOT_BLOCK_(I64, int64_t, uint64_t, uint64_t, INT64_MAX)
#define msDotFits_(fn, acc, a, b, s, e) fn((acc), (a).len, msArrayData_(a), (b).len, msArrayData_(b), (s), (e))
#define msDotRun_(fn, acc, a, b, s, e) fn((acc), msArrayData_(a), msArrayData_(b), (s), (e))
#define msDotFitsI8(acc, a, b, s, e) msDotFits_(msDotFitsI8_, acc, a, b, s, e)
#define msDotFitsI16(acc, a, b, s, e) msDotFits_(msDotFitsI16_, acc, a, b, s, e)
#define msDotFitsI32(acc, a, b, s, e) msDotFits_(msDotFitsI32_, acc, a, b, s, e)
#define msDotFitsI64(acc, a, b, s, e) msDotFits_(msDotFitsI64_, acc, a, b, s, e)
#define msDotAddI8(acc, a, b, s, e) msDotRun_(msDotAddI8_, acc, a, b, s, e)
#define msDotAddI16(acc, a, b, s, e) msDotRun_(msDotAddI16_, acc, a, b, s, e)
#define msDotAddI32(acc, a, b, s, e) msDotRun_(msDotAddI32_, acc, a, b, s, e)
#define msDotAddI64(acc, a, b, s, e) msDotRun_(msDotAddI64_, acc, a, b, s, e)
#define msDotSubI8(acc, a, b, s, e) msDotRun_(msDotSubI8_, acc, a, b, s, e)
#define msDotSubI16(acc, a, b, s, e) msDotRun_(msDotSubI16_, acc, a, b, s, e)
#define msDotSubI32(acc, a, b, s, e) msDotRun_(msDotSubI32_, acc, a, b, s, e)
#define msDotSubI64(acc, a, b, s, e) msDotRun_(msDotSubI64_, acc, a, b, s, e)

#define msModAssignF64(lv, b) msDivAssign_(lv, b, fmod)
#define msAndAssignF64(lv, b) msDivAssign_(lv, b, msNumberAnd)
#define msOrAssignF64(lv, b) msDivAssign_(lv, b, msNumberOr)
#define msXorAssignF64(lv, b) msDivAssign_(lv, b, msNumberXor)
#define msShlAssignF64(lv, b) msDivAssign_(lv, b, msNumberShl)
#define msShrAssignF64(lv, b) msDivAssign_(lv, b, msNumberShr)
#define msShrUAssignF64(lv, b) msDivAssign_(lv, b, msNumberShrU)

#endif /* MS_CHECKED_ARITH_H */
