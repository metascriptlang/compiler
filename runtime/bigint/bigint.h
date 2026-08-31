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
msString msBigIntToString(const msBigInt* a, int32_t radix);
msString msBigIntToDebugString(const msBigInt* a);
msBigInt* msBigIntFromInt64(int64_t v);
msBigInt* msBigIntFromUint64(uint64_t v);
msBigInt* msBigIntFromFloat64(double v);

int64_t msBigIntToInt64(const msBigInt* a);
double msBigIntToFloat64(const msBigInt* a);
char* msBigIntToCString(const msBigInt* a, int32_t radix);

msBigInt* msBigIntAdd(const msBigInt* a, const msBigInt* b);
msBigInt* msBigIntSub(const msBigInt* a, const msBigInt* b);
msBigInt* msBigIntMul(const msBigInt* a, const msBigInt* b);
msBigInt* msBigIntDiv(const msBigInt* a, const msBigInt* b);
msBigInt* msBigIntMod(const msBigInt* a, const msBigInt* b);
msBigInt* msBigIntPow(const msBigInt* a, const msBigInt* b);
msBigInt* msBigIntNeg(const msBigInt* a);
msBigInt* msBigIntNot(const msBigInt* a);
msBigInt* msBigIntAnd(const msBigInt* a, const msBigInt* b);
msBigInt* msBigIntOr(const msBigInt* a, const msBigInt* b);
msBigInt* msBigIntXor(const msBigInt* a, const msBigInt* b);
msBigInt* msBigIntShl(const msBigInt* a, const msBigInt* b);
msBigInt* msBigIntShr(const msBigInt* a, const msBigInt* b);

int32_t msBigIntCmp(const msBigInt* a, const msBigInt* b);
bool msBigIntIsZero(const msBigInt* a);
msBigInt* msBigIntAsIntN(int64_t bits, const msBigInt* a);
msBigInt* msBigIntAsUintN(int64_t bits, const msBigInt* a);

#endif
