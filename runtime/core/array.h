/*
 * MetaScript Array Runtime
 *
 * Type-erased allocation core, with typed wrappers for:
 *   msNumberArray (double[]), msStringArray (msString[]), msRefArray (void*[])
 * Growth: <=0 -> 4, <=32K -> x2, else -> x3/2
 */

#ifndef MS_ARRAY_H
#define MS_ARRAY_H

#include "runtime/drc.h"
#include <stdio.h>
#include <stdarg.h>

/* string.h must be included before array.h */
#include "runtime/core/string.h"

/* ===== Payload Types ===== */

/* Reference parity: payloads are uniquely owned (no refcount).
   DRC ensures copies are deep and moves zero the source. */
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
	int64_t grown = old + old / 2;
	return grown < MS_LEN_MAX ? grown : MS_LEN_MAX;
}

/* ===== Type-Erased Core ===== */

/* Allocate payload: header(cap) + cap*elemSize, zero-filled */
void* msArrayPayloadNew(int64_t cap, int64_t elemSize);

/* Grow payload if needed. Returns new payload pointer. */
void* msArrayPrepareAdd(int64_t len, void* p, int64_t addLen, int64_t elemSize);

void msArrayRotateBytes(char* data, int64_t lo, int64_t mid, int64_t hi, int64_t elemSize);

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
msNumberArray msNumberArrayConcat(msNumberArray* a, const msNumberArray* b);
void msNumberArrayReverse(msNumberArray* arr);
void msNumberArraySort(msNumberArray* arr);
void msNumberArrayFill(msNumberArray* arr, double value);
int64_t msNumberArrayCount(msNumberArray* arr, double value);
msString msNumberArrayJoin(msNumberArray* arr, msString sep);
void msNumberArrayShrink(msNumberArray* arr, int64_t newLen);
void msNumberArrayGrow(msNumberArray* arr, int64_t newLen, double value);
void msNumberArraySetLen(msNumberArray* arr, int64_t newLen);
int64_t msNumberArrayCapacity(msNumberArray* arr);

/* ===== String Array ===== */

msStringArray msStringArrayNew(int64_t cap);
msStringArray msStringArrayFromArr(const msString* arr, int64_t count);
void msStringArrayDestroy(msStringArray* arr);
void msStringArrayPush(msStringArray* arr, msString value);
msString msStringArrayPop(msStringArray* arr);
msString msStringArrayShift(msStringArray* arr);
int64_t msStringArrayIndexOf(msStringArray* arr, msString value);
int64_t msStringArrayLastIndexOf(msStringArray* arr, msString value, int64_t fromIndex);
bool msStringArrayIncludes(msStringArray* arr, msString value);
msStringArray msStringArraySlice(msStringArray* arr, int64_t start, int64_t end);
msStringArray msStringArrayConcat(msStringArray* a, const msStringArray* b);
void msStringArrayReverse(msStringArray* arr);
void msStringArraySort(msStringArray* arr);
void msStringArrayFill(msStringArray* arr, msString value);
int64_t msStringArrayCount(msStringArray* arr, msString value);
msString msStringArrayJoin(msStringArray* arr, msString sep);
void msStringArrayShrink(msStringArray* arr, int64_t newLen);
void msStringArrayGrow(msStringArray* arr, int64_t newLen, msString value);
void msStringArraySetLen(msStringArray* arr, int64_t newLen);
int64_t msStringArrayCapacity(msStringArray* arr);

/* ===== Ref Array ===== */

void msRefArrayDestroy(msRefArray* arr);
void msRefArrayShrink(msRefArray* arr, int64_t newLen);
void msRefArrayGrow(msRefArray* arr, int64_t newLen, void* value);
void msRefArraySetLen(msRefArray* arr, int64_t newLen);
void msRefArraySplice(msRefArray* arr, int64_t start, int64_t deleteCount);
void msRefArraySplice3(msRefArray* arr, int64_t start, int64_t deleteCount, void* item);
void msAtomicRefArrayDestroy(msRefArray* arr);
void msAtomicRefArrayShrink(msRefArray* arr, int64_t newLen);
void msAtomicRefArraySetLen(msRefArray* arr, int64_t newLen);
void msAtomicRefArraySplice(msRefArray* arr, int64_t start, int64_t deleteCount);
void msAtomicRefArraySplice3(msRefArray* arr, int64_t start, int64_t deleteCount, void* item);
void msAcyclicRefArrayDestroy(msRefArray* arr);
void msAcyclicRefArrayShrink(msRefArray* arr, int64_t newLen);
void msAcyclicRefArraySetLen(msRefArray* arr, int64_t newLen);
void msAcyclicRefArraySplice3(msRefArray* arr, int64_t start, int64_t deleteCount, void* item);
void msNumberArraySplice(msNumberArray* arr, int64_t start, int64_t deleteCount);
void msNumberArraySplice3(msNumberArray* arr, int64_t start, int64_t deleteCount, double item);
void msStringArraySplice(msStringArray* arr, int64_t start, int64_t deleteCount);
void msStringArraySplice3(msStringArray* arr, int64_t start, int64_t deleteCount, msString item);

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
msString msAsString(msUint8Array* arr);
void msUint8ArraySplice3(msUint8Array* arr, int64_t start, int64_t deleteCount, uint8_t item);

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
#define msArrDataOr0(p_) ((p_) ? (p_)->data : NULL)
#define msArrDataAt(p_, i_) ((p_) ? (p_)->data + (i_) : NULL)

#define msGenericArrayPush(arr_ptr, ...) do { \
	__typeof__((arr_ptr)->p->data[0]) msPushedValue_ = (__VA_ARGS__); \
	if ((arr_ptr)->p == NULL || (((msArrayPayloadBase*)(arr_ptr)->p)->cap & ~MS_CAP_MASK) != 0 \
		|| (arr_ptr)->len >= (int64_t)(((msArrayPayloadBase*)(arr_ptr)->p)->cap & MS_CAP_MASK)) { \
		(arr_ptr)->p = (__typeof__((arr_ptr)->p))msArrayPrepareAdd( \
			(arr_ptr)->len, (arr_ptr)->p, 1, sizeof((arr_ptr)->p->data[0])); \
	} \
	(arr_ptr)->p->data[(arr_ptr)->len] = msPushedValue_; \
	(arr_ptr)->len++; \
} while(0)

#define msGenericArrayCheckedIndex(arr_ptr, idx) ({ \
	int64_t _gx = (idx); \
	int64_t _gi = _gx < 0 ? (arr_ptr)->len + _gx : _gx; \
	if ((uint64_t)_gi >= (uint64_t)(arr_ptr)->len) msRaiseIndexError(_gx, (arr_ptr)->len); \
	_gi; \
})

/* Pop last element. Returns the value. */
#define msGenericArrayPop(arr_ptr) ({ \
	if ((arr_ptr)->len <= 0) msRaiseIndexError((arr_ptr)->len - 1, (arr_ptr)->len); \
	(arr_ptr)->len--; \
	(arr_ptr)->p->data[(arr_ptr)->len]; \
})

/* Set length. Grows with zero-fill if needed. */
#define msGenericArraySetLen(arr_ptr, newLen) do { \
	int64_t _nl = (newLen); \
	if (_nl < 0) _nl = 0; \
	if (_nl > (arr_ptr)->len) { \
		if ((arr_ptr)->p == NULL || (((msArrayPayloadBase*)(arr_ptr)->p)->cap & ~MS_CAP_MASK) != 0 \
			|| _nl > (int64_t)(((msArrayPayloadBase*)(arr_ptr)->p)->cap & MS_CAP_MASK)) { \
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

#define msGenericArrayRotate(arr_ptr, lo, mid, hi) do { \
	int64_t _rlo = (lo), _rmid = (mid), _rhi = (hi); \
	if (_rlo < 0 || _rmid < _rlo || _rhi < _rmid || _rhi > (arr_ptr)->len) msRaiseIndexError(_rhi, (arr_ptr)->len); \
	if (_rlo < _rmid && _rmid < _rhi) \
		msArrayRotateBytes((char*)(arr_ptr)->p->data, _rlo, _rmid, _rhi, sizeof((arr_ptr)->p->data[0])); \
} while(0)

#define msGenericArraySwap(arr_ptr, i, j) do { \
	int64_t _si = (i), _sj = (j); \
	if ((uint64_t)_si >= (uint64_t)(arr_ptr)->len) msRaiseIndexError(_si, (arr_ptr)->len); \
	if ((uint64_t)_sj >= (uint64_t)(arr_ptr)->len) msRaiseIndexError(_sj, (arr_ptr)->len); \
	__typeof__((arr_ptr)->p->data[0]) _st = (arr_ptr)->p->data[_si]; \
	(arr_ptr)->p->data[_si] = (arr_ptr)->p->data[_sj]; \
	(arr_ptr)->p->data[_sj] = _st; \
} while(0)

#define msGenericArraySwapWith(arr_ptr, i, other, j) do { \
	int64_t _si = (i), _sj = (j); \
	__typeof__(arr_ptr) _so = __builtin_choose_expr( \
		__builtin_types_compatible_p(__typeof__(other), __typeof__(arr_ptr)), (other), &(other)); \
	if ((uint64_t)_si >= (uint64_t)(arr_ptr)->len) msRaiseIndexError(_si, (arr_ptr)->len); \
	if ((uint64_t)_sj >= (uint64_t)_so->len) msRaiseIndexError(_sj, _so->len); \
	__typeof__((arr_ptr)->p->data[0]) _st = (arr_ptr)->p->data[_si]; \
	(arr_ptr)->p->data[_si] = _so->p->data[_sj]; \
	_so->p->data[_sj] = _st; \
} while(0)

#endif /* MS_ARRAY_H */
