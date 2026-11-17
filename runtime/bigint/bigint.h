#ifndef MS_BIGINT_H
#define MS_BIGINT_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#include "runtime/types.h"
#include "runtime/core/string.h"

typedef struct msBigInt msBigInt;

extern const msTypeInfo msBigIntTypeInfo;

msBigInt* msBigIntFromString(const char* s, size_t len);
msBigInt* msBigIntFromLit(msString s);
bool msBigIntParses(msString s);
msBigInt* msBigIntParse(msString s);
msString msBigIntToString(const msBigInt* a, int32_t radix);
msString msBigIntToDebugString(const msBigInt* a);
msBigInt* msBigIntFromInt64(int64_t v);
msBigInt* msBigIntFromUint64(uint64_t v);
msBigInt* msBigIntFromFloat64(double v);

int64_t msBigIntToInt64(const msBigInt* a);
int64_t msBigIntToSigned(const msBigInt* a, int32_t bits);
float msBigIntToFloat32(const msBigInt* a);
double msBigIntToFloat64(const msBigInt* a);
char* msBigIntToCString(const msBigInt* a, int32_t radix);

msBigInt* msBigIntAdd(const msBigInt* a, const msBigInt* b);
msBigInt* msBigIntSub(const msBigInt* a, const msBigInt* b);
msBigInt* msBigIntMul(const msBigInt* a, const msBigInt* b);
msBigInt* msBigIntDiv(const msBigInt* a, const msBigInt* b);
msBigInt* msBigIntMod(const msBigInt* a, const msBigInt* b);
msBigInt* msBigIntPow(const msBigInt* a, const msBigInt* b);
msBigInt* msBigIntClone(const msBigInt* a);
#define msBigIntCopy(destp, src) do { \
	__typeof__(destp) msBigIntCopyDest_ = (destp); \
	const msBigInt* msBigIntCopySrc_ = (src); \
	if ((const void*)*msBigIntCopyDest_ != (const void*)msBigIntCopySrc_) { \
		void* msBigIntCopyOld_ = (void*)*msBigIntCopyDest_; \
		*msBigIntCopyDest_ = msBigIntCopySrc_ != NULL ? msBigIntClone(msBigIntCopySrc_) : NULL; \
		msDecref(msBigIntCopyOld_); \
	} \
} while(0)
#define msBigIntIncref(b)     do { if ((b) != NULL) (b) = msBigIntClone(b); } while(0)
#define msBigIntSink(d, ...)  do { msBigInt* msBigIntSinkOld_ = (d); (d) = (__VA_ARGS__); msDecref(msBigIntSinkOld_); } while(0)
#define msArrayBigIntCopy(d, s) msArrayRefCopyBy(d, s, msBigIntIncref, msRefArrayDestroy)
msBigInt* msBigIntNeg(const msBigInt* a);
msBigInt* msBigIntNot(const msBigInt* a);
msBigInt* msBigIntAnd(const msBigInt* a, const msBigInt* b);
msBigInt* msBigIntOr(const msBigInt* a, const msBigInt* b);
msBigInt* msBigIntXor(const msBigInt* a, const msBigInt* b);
msBigInt* msBigIntShl(const msBigInt* a, const msBigInt* b);
msBigInt* msBigIntShr(const msBigInt* a, const msBigInt* b);

int32_t msBigIntCmp(const msBigInt* a, const msBigInt* b);
int32_t msBigIntCompareFloat64(const msBigInt* a, double d, int32_t unordered);
int32_t msFloat64CompareBigInt(double d, const msBigInt* a, int32_t unordered);
bool msBigIntIsZero(const msBigInt* a);
msBigInt* msBigIntAsIntN(int64_t bits, const msBigInt* a);
msBigInt* msBigIntAsUintN(int64_t bits, const msBigInt* a);
void msBigIntThrowRange(msString message);

#endif
