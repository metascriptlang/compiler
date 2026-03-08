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

/* Allocate dest to match src length (Reference parity: setLen for copy) */
static inline void msArraySetLenGeneric(void* dest, int64_t srcLen, int64_t elemSize) {
	msRawArray* d = (msRawArray*)dest;
	if (d->p) { free(d->p); }
	if (srcLen > 0) {
		d->p = msArrayPayloadNew(srcLen, elemSize);
	} else {
		d->p = NULL;
	}
	d->len = srcLen;
}

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

/* ===== Uint8 Array (binary-compatible with msString for zero-copy bridge) ===== */

typedef struct {
	int64_t cap;
	uint8_t data[];
} msUint8Payload;

typedef struct {
	int64_t len;
	msUint8Payload* p;
} msUint8Array;

#define MS_EMPTY_UINT8_ARRAY ((msUint8Array){0, NULL})

void msUint8ArrayDestroy(msUint8Array* arr);
void msUint8ArrayPush(msUint8Array* arr, uint8_t value);
uint8_t msUint8ArrayAt(msUint8Array* arr, int64_t idx);
msUint8Array msUint8ArrayNew(int64_t cap);

/* ===== Generic Typed Array Macro (Standard reference sequence pattern) ===== */
/* Generates per-type array struct: { int64_t len; struct { int64_t cap; T data[]; }* p; }
 * Usage: typedef MS_ARRAY(struct Token) TokenArray;
 * Each element type gets its own array with inline value storage (not void* indirection). */

#define MS_ARRAY_PAYLOAD(T) struct { int64_t cap; T data[]; }

#define MS_ARRAY(T) struct { int64_t len; MS_ARRAY_PAYLOAD(T)* p; }

/* Generic empty initializer — works for any MS_ARRAY(T) */
#define MS_ARRAY_EMPTY {0, NULL}

/* ===== Generic Array Operations (work with any MS_ARRAY(T) type) ===== */

/* Push a value onto the array. Grows capacity if needed.
 * Uses a helper macro to avoid comma-in-braced-initializer issues with C preprocessor.
 * Usage: msGenericArrayPush(&arr, value) where value can be a compound literal. */
#define msGenericArrayPush(arr_ptr, ...) do { \
	if ((arr_ptr)->p == NULL || (arr_ptr)->len >= (int64_t)((msArrayPayloadBase*)(arr_ptr)->p)->cap) { \
		(arr_ptr)->p = (__typeof__((arr_ptr)->p))msArrayPrepareAdd( \
			(arr_ptr)->len, (arr_ptr)->p, 1, sizeof((arr_ptr)->p->data[0])); \
	} \
	(arr_ptr)->p->data[(arr_ptr)->len] = (__VA_ARGS__); \
	(arr_ptr)->len++; \
} while(0)

/* Access element at index with negative index support. Returns value. */
#define msGenericArrayAt(arr_ptr, idx) ({ \
	int64_t _gi = (idx); \
	if (_gi < 0) _gi = (arr_ptr)->len + _gi; \
	(arr_ptr)->p->data[_gi]; \
})

/* Pop last element. Returns the value. */
#define msGenericArrayPop(arr_ptr) ({ \
	__typeof__((arr_ptr)->p->data[0]) _pv = (arr_ptr)->p->data[(arr_ptr)->len - 1]; \
	(arr_ptr)->len--; \
	_pv; \
})

/* Set length. Grows with zero-fill if needed. */
#define msGenericArraySetLen(arr_ptr, newLen) do { \
	int64_t _nl = (newLen); \
	if (_nl > (arr_ptr)->len) { \
		if ((arr_ptr)->p == NULL || _nl > (int64_t)((msArrayPayloadBase*)(arr_ptr)->p)->cap) { \
			(arr_ptr)->p = (__typeof__((arr_ptr)->p))msArrayPrepareAdd( \
				(arr_ptr)->len, (arr_ptr)->p, _nl - (arr_ptr)->len, sizeof((arr_ptr)->p->data[0])); \
		} \
		memset(&(arr_ptr)->p->data[(arr_ptr)->len], 0, \
			(_nl - (arr_ptr)->len) * sizeof((arr_ptr)->p->data[0])); \
	} \
	(arr_ptr)->len = _nl; \
} while(0)

/* Destroy (free payload). */
#define msGenericArrayDestroy(arr_ptr) do { \
	if ((arr_ptr)->p != NULL) { free((arr_ptr)->p); (arr_ptr)->p = NULL; } \
	(arr_ptr)->len = 0; \
} while(0)

/* Capacity query. */
#define msGenericArrayCapacity(arr_ptr) \
	((arr_ptr)->p != NULL ? (int64_t)((msArrayPayloadBase*)(arr_ptr)->p)->cap : (int64_t)0)

#endif /* MS_ARRAY_H */
