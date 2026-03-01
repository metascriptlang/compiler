/*
 * MetaScript Array Runtime
 *
 * Type-erased allocation core, with typed wrappers for:
 *   msNumberArray (double[]), msStringArray (msString[]), msRefArray (void*[])
 * Growth: <=0 -> 4, <=32K -> x2, else -> x3/2
 */

#ifndef MS_ARRAY_H
#define MS_ARRAY_H

#include "../mem/arc.h"
#include <stdio.h>
#include <stdarg.h>

/* string.h must be included before array.h */
#include "string.h"

/* ===== Payload Types ===== */

typedef struct {
	int64_t cap;
} msArrayPayloadBase;

typedef struct {
	int64_t cap;
	double data[];
} msNumberPayload;

typedef struct {
	int64_t cap;
	msString data[];
} msStringPayload;

typedef struct {
	int64_t cap;
	void* data[];
} msRefPayload;

/* ===== Array Types ===== */

typedef struct {
	int64_t len;
	msNumberPayload* p;
} msNumberArray;

struct msStringArray {
	int64_t len;
	msStringPayload* p;
};

typedef struct {
	int64_t len;
	msRefPayload* p;
} msRefArray;

/* Generic raw array (for type-erased ops) */
typedef struct {
	int64_t len;
	void* p;
} msRawArray;

/* ===== Constants ===== */

#define MS_EMPTY_NUMBER_ARRAY ((msNumberArray){0, NULL})
#define MS_EMPTY_STRING_ARRAY ((msStringArray){0, NULL})
#define MS_EMPTY_REF_ARRAY    ((msRefArray){0, NULL})

/* ===== Capacity Growth ===== */

static inline int64_t msArrayResizeCap(int64_t old) {
	if (old <= 0) return 4;
	if (old <= 32767) return old * 2;
	return old + old / 2;
}

/* ===== Type-Erased Core ===== */

/* Allocate payload: header(cap) + cap*elemSize, zero-filled */
void* msArrayPayloadNew(int64_t cap, int64_t elemSize);

/* Allocate payload without zeroing — for newArrayOfCap */
void* msArrayPayloadNewUninit(int64_t cap, int64_t elemSize);

/* Grow payload if needed. Returns new payload pointer. */
void* msArrayPrepareAdd(int64_t len, void* p, int64_t addLen, int64_t elemSize);

/* Grow without zeroing */
void* msArrayPrepareAddUninit(int64_t len, void* p, int64_t addLen, int64_t elemSize);

/* Raw pointer compare */
bool msArraySamePayload(void* a, void* b);

/* ===== Number Array ===== */

msNumberArray msNumberArrayNew(int64_t cap);
msNumberArray msNumberArrayFrom(int64_t count, ...);
void msNumberArrayDestroy(msNumberArray* arr);
void msNumberArrayPush(msNumberArray* arr, double value);
double msNumberArrayPop(msNumberArray* arr);
double msNumberArrayShift(msNumberArray* arr);
double msNumberArrayAt(msNumberArray* arr, int64_t idx);
int64_t msNumberArrayIndexOf(msNumberArray* arr, double value);
bool msNumberArrayIncludes(msNumberArray* arr, double value);
msNumberArray msNumberArraySlice(msNumberArray* arr, int64_t start, int64_t end);
msNumberArray msNumberArrayConcat(msNumberArray* a, msNumberArray b);
void msNumberArrayReverse(msNumberArray* arr);
void msNumberArraySort(msNumberArray* arr);
void msNumberArrayFill(msNumberArray* arr, double value);
int64_t msNumberArrayCount(msNumberArray* arr, double value);
msString msNumberArrayJoin(msNumberArray* arr, msString sep);
void msNumberArrayShrink(msNumberArray* arr, int64_t newLen);
void msNumberArrayGrow(msNumberArray* arr, int64_t newLen, double value);
void msNumberArraySetLen(msNumberArray* arr, int64_t newLen);
int64_t msNumberArrayCapacity(msNumberArray* arr);
void msNumberArraySetLenUninit(msNumberArray* arr, int64_t newLen);

/* ===== String Array ===== */

msStringArray msStringArrayNew(int64_t cap);
msStringArray msStringArrayFrom(int64_t count, ...);
void msStringArrayDestroy(msStringArray* arr);
void msStringArrayPush(msStringArray* arr, msString value);
msString msStringArrayPop(msStringArray* arr);
msString msStringArrayShift(msStringArray* arr);
msString msStringArrayAt(msStringArray* arr, int64_t idx);
int64_t msStringArrayIndexOf(msStringArray* arr, msString value);
bool msStringArrayIncludes(msStringArray* arr, msString value);
msStringArray msStringArraySlice(msStringArray* arr, int64_t start, int64_t end);
msStringArray msStringArrayConcat(msStringArray* a, msStringArray b);
void msStringArrayReverse(msStringArray* arr);
void msStringArraySort(msStringArray* arr);
void msStringArrayFill(msStringArray* arr, msString value);
int64_t msStringArrayCount(msStringArray* arr, msString value);
msString msStringArrayJoin(msStringArray* arr, msString sep);
void msStringArrayShrink(msStringArray* arr, int64_t newLen);
void msStringArrayGrow(msStringArray* arr, int64_t newLen, msString value);
void msStringArraySetLen(msStringArray* arr, int64_t newLen);
int64_t msStringArrayCapacity(msStringArray* arr);
void msStringArraySetLenUninit(msStringArray* arr, int64_t newLen);

/* ===== Ref Array ===== */

msRefArray msRefArrayNew(int64_t cap);
void msRefArrayDestroy(msRefArray* arr);
void msRefArrayPush(msRefArray* arr, void* value);
void* msRefArrayPop(msRefArray* arr);
void* msRefArrayAt(msRefArray* arr, int64_t idx);
void msRefArrayShrink(msRefArray* arr, int64_t newLen);
void msRefArrayGrow(msRefArray* arr, int64_t newLen, void* value);
void msRefArraySetLen(msRefArray* arr, int64_t newLen);
int64_t msRefArrayCapacity(msRefArray* arr);
void msRefArraySetLenUninit(msRefArray* arr, int64_t newLen);

#endif /* MS_ARRAY_H */
