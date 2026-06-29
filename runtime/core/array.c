/*
 * MetaScript Array Runtime — Implementation
 */

#include "runtime/core/system.h"
#include "runtime/core/string.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* ===== Type-Erased Core ===== */

/* Reference parity: payloads are uniquely owned — no refcount field.
   DRC handles ownership (move vs deep copy) at compile time. */

void* msArrayPayloadNew(int64_t cap, int64_t elemSize) {
	if (cap <= 0) return NULL;
	int64_t headerSize = sizeof(msArrayPayloadBase);
	int64_t totalSize = headerSize + cap * elemSize;
	msArrayPayloadBase* p = (msArrayPayloadBase*)calloc(1, totalSize);
	if (p) { p->cap = cap; }
	return p;
}

void* msArrayPayloadNewUninit(int64_t cap, int64_t elemSize) {
	if (cap <= 0) return NULL;
	int64_t headerSize = sizeof(msArrayPayloadBase);
	int64_t totalSize = headerSize + cap * elemSize;
	msArrayPayloadBase* p = (msArrayPayloadBase*)malloc(totalSize);
	if (p) { p->cap = cap; }
	return p;
}

void* msArrayPrepareAdd(int64_t len, void* p, int64_t addLen, int64_t elemSize) {
	int64_t headerSize = sizeof(msArrayPayloadBase);
	if (addLen <= 0) return p;
	if (p == NULL) {
		return msArrayPayloadNew(len + addLen, elemSize);
	}
	/* Payload is uniquely owned — safe to realloc in place */
	msArrayPayloadBase* base = (msArrayPayloadBase*)p;
	int64_t oldCap = base->cap;
	int64_t needed = len + addLen;
	if (needed <= oldCap) return p;

	int64_t newCap = msArrayResizeCap(oldCap);
	if (newCap < needed) newCap = needed;

	int64_t oldSize = headerSize + oldCap * elemSize;
	int64_t newSize = headerSize + newCap * elemSize;
	msArrayPayloadBase* q = (msArrayPayloadBase*)realloc(p, newSize);
	if (q) {
		if (newSize > oldSize) {
			memset((char*)q + oldSize, 0, newSize - oldSize);
		}
		q->cap = newCap;
	}
	return q;
}

/* ===== Number Array ===== */

msNumberArray msNumberArrayNew(int64_t cap) {
	msNumberArray arr;
	arr.len = 0;
	arr.p = (msNumberPayload*)msArrayPayloadNew(cap, sizeof(double));
	return arr;
}

msNumberArray msNumberArrayFrom(int64_t count, ...) {
	if (count <= 0) return MS_EMPTY_NUMBER_ARRAY;
	msNumberArray arr = msNumberArrayNew(count);
	va_list args;
	va_start(args, count);
	for (int64_t i = 0; i < count; i++) {
		arr.p->data[i] = va_arg(args, double);
	}
	va_end(args);
	arr.len = count;
	return arr;
}

void msNumberArrayDestroy(msNumberArray* arr) {
	if (arr->p != NULL) {
		free(arr->p);
		arr->p = NULL;
	}
	arr->len = 0;
}

void msNumberArrayPush(msNumberArray* arr, double value) {
	if (arr->p == NULL || arr->p->cap < arr->len + 1) {
		arr->p = (msNumberPayload*)msArrayPrepareAdd(arr->len, arr->p, 1, sizeof(double));
	}
	arr->p->data[arr->len] = value;
	arr->len++;
}

double msNumberArrayPop(msNumberArray* arr) {
	if (arr->len <= 0) return 0.0;
	arr->len--;
	return arr->p->data[arr->len];
}

double msNumberArrayShift(msNumberArray* arr) {
	if (arr->len <= 0) return 0.0;
	double first = arr->p->data[0];
	memmove(arr->p->data, arr->p->data + 1, (arr->len - 1) * sizeof(double));
	arr->len--;
	return first;
}

double msNumberArrayAt(msNumberArray* arr, int64_t idx) {
	if (idx < 0) idx = arr->len + idx;
	if (idx < 0 || idx >= arr->len) return 0.0;
	return arr->p->data[idx];
}

int64_t msNumberArrayIndexOf(msNumberArray* arr, double value) {
	if (arr->p == NULL) return -1;
	for (int64_t i = 0; i < arr->len; i++) {
		if (arr->p->data[i] == value) return i;
	}
	return -1;
}

bool msNumberArrayIncludes(msNumberArray* arr, double value) {
	return msNumberArrayIndexOf(arr, value) >= 0;
}

msNumberArray msNumberArraySlice(msNumberArray* arr, int64_t start, int64_t end) {
	if (start < 0) start = arr->len + start;
	if (end < 0) end = arr->len + end;
	if (start < 0) start = 0;
	if (end > arr->len) end = arr->len;
	if (start >= end) return MS_EMPTY_NUMBER_ARRAY;

	int64_t newLen = end - start;
	msNumberArray result = msNumberArrayNew(newLen);
	memcpy(result.p->data, arr->p->data + start, newLen * sizeof(double));
	result.len = newLen;
	return result;
}

msNumberArray msNumberArrayConcat(msNumberArray* a, msNumberArray b) {
	int64_t totalLen = a->len + b.len;
	if (totalLen == 0) return MS_EMPTY_NUMBER_ARRAY;
	msNumberArray result = msNumberArrayNew(totalLen);
	if (a->len > 0 && a->p) {
		memcpy(result.p->data, a->p->data, a->len * sizeof(double));
	}
	if (b.len > 0 && b.p) {
		memcpy(result.p->data + a->len, b.p->data, b.len * sizeof(double));
	}
	result.len = totalLen;
	return result;
}

void msNumberArrayReverse(msNumberArray* arr) {
	if (arr->len <= 1 || arr->p == NULL) return;
	for (int64_t i = 0, j = arr->len - 1; i < j; i++, j--) {
		double tmp = arr->p->data[i];
		arr->p->data[i] = arr->p->data[j];
		arr->p->data[j] = tmp;
	}
}

static int msNumberCmp(const void* a, const void* b) {
	double da = *(const double*)a;
	double db = *(const double*)b;
	if (da < db) return -1;
	if (da > db) return 1;
	return 0;
}

void msNumberArraySort(msNumberArray* arr) {
	if (arr->len <= 1 || arr->p == NULL) return;
	qsort(arr->p->data, arr->len, sizeof(double), msNumberCmp);
}

void msNumberArrayFill(msNumberArray* arr, double value) {
	if (arr->p == NULL) return;
	for (int64_t i = 0; i < arr->len; i++) {
		arr->p->data[i] = value;
	}
}

int64_t msNumberArrayCount(msNumberArray* arr, double value) {
	if (arr->p == NULL) return 0;
	int64_t count = 0;
	for (int64_t i = 0; i < arr->len; i++) {
		if (arr->p->data[i] == value) count++;
	}
	return count;
}

msString msNumberArrayJoin(msNumberArray* arr, msString sep) {
	if (arr->len == 0) return MS_EMPTY_STRING;

	/* Convert all numbers to strings first */
	msString result = msStringNewCap(arr->len * 8);
	for (int64_t i = 0; i < arr->len; i++) {
		if (i > 0) msStringAppend(&result, sep);
		msString numStr = msNumberToString(arr->p->data[i]);
		msStringAppend(&result, numStr);
		msStringDestroy(numStr);
	}
	return result;
}

/* ===== Type-Erased Core: Uninit + SamePayload ===== */

void* msArrayPrepareAddUninit(int64_t len, void* p, int64_t addLen, int64_t elemSize) {
	int64_t headerSize = sizeof(msArrayPayloadBase);
	if (addLen <= 0) return p;
	if (p == NULL) {
		int64_t cap = len + addLen;
		int64_t totalSize = headerSize + cap * elemSize;
		msArrayPayloadBase* q = (msArrayPayloadBase*)malloc(totalSize);
		if (q) q->cap = cap;
		return q;
	}
	/* Payload is uniquely owned — safe to realloc in place */
	msArrayPayloadBase* base = (msArrayPayloadBase*)p;
	int64_t oldCap = base->cap;
	int64_t needed = len + addLen;
	if (needed <= oldCap) return p;

	int64_t newCap = msArrayResizeCap(oldCap);
	if (newCap < needed) newCap = needed;

	int64_t newSize = headerSize + newCap * elemSize;
	msArrayPayloadBase* q = (msArrayPayloadBase*)realloc(p, newSize);
	if (q) q->cap = newCap;
	return q;
}

bool msArraySamePayload(void* a, void* b) {
	return a == b;
}

/* ===== Number Array Lifecycle ===== */

void msNumberArrayShrink(msNumberArray* arr, int64_t newLen) {
	if (newLen < 0) newLen = 0;
	if (newLen >= arr->len) return;
	/* No destructors needed for doubles */
	arr->len = newLen;
}

void msNumberArrayGrow(msNumberArray* arr, int64_t newLen, double value) {
	if (newLen <= arr->len) return;
	/* Ensure capacity */
	if (arr->p == NULL || arr->p->cap < newLen) {
		arr->p = (msNumberPayload*)msArrayPrepareAdd(arr->len, arr->p, newLen - arr->len, sizeof(double));
	}
	/* Fill new slots */
	for (int64_t i = arr->len; i < newLen; i++) {
		arr->p->data[i] = value;
	}
	arr->len = newLen;
}

void msNumberArraySetLen(msNumberArray* arr, int64_t newLen) {
	if (newLen < arr->len) {
		msNumberArrayShrink(arr, newLen);
	} else if (newLen > arr->len) {
		msNumberArrayGrow(arr, newLen, 0.0);
	}
}

int64_t msNumberArrayCapacity(msNumberArray* arr) {
	return arr->p ? arr->p->cap : 0;
}

void msNumberArraySetLenUninit(msNumberArray* arr, int64_t newLen) {
	if (newLen < arr->len) {
		arr->len = newLen;
		return;
	}
	if (arr->p == NULL || arr->p->cap < newLen) {
		arr->p = (msNumberPayload*)msArrayPrepareAddUninit(arr->len, arr->p, newLen - arr->len, sizeof(double));
	}
	arr->len = newLen;
}

/* ===== String Array ===== */

msStringArray msStringArrayNew(int64_t cap) {
	msStringArray arr;
	arr.len = 0;
	arr.p = (msStringPayload*)msArrayPayloadNew(cap, sizeof(msString));
	return arr;
}

msStringArray msStringArrayFromArr(const msString* src, int64_t count) {
	if (count <= 0) return MS_EMPTY_STRING_ARRAY;
	msStringArray arr = msStringArrayNew(count);
	for (int64_t i = 0; i < count; i++) {
		/* Move: each element arrives already independently owned — the analyzer
		   copies aliased occurrences (`[s, s]` → incref the non-last-read one) and
		   moves last-read ones, so taking the handle as-is is correct. Deep-copying
		   here would allocate a redundant second buffer and orphan the analyzer's
		   owned element → leak. Mirrors msGenericArrayPush (ref/object arrays). */
		arr.p->data[i] = src[i];
	}
	arr.len = count;
	return arr;
}

void msStringArrayDestroy(msStringArray* arr) {
	if (arr->p != NULL) {
		for (int64_t i = 0; i < arr->len; i++) {
			msStringDestroy(arr->p->data[i]);
		}
		free(arr->p);
		arr->p = NULL;
	}
	arr->len = 0;
}

void msStringArrayPush(msStringArray* arr, msString value) {
	if (arr->p == NULL || arr->p->cap < arr->len + 1) {
		arr->p = (msStringPayload*)msArrayPrepareAdd(arr->len, arr->p, 1, sizeof(msString));
	}
	/* Sink semantics — take ownership of value. The analyzer marks the source
	   wasMoved at the call site (push value param is sink-bound). No deep copy:
	   the original heap is transferred into the array and freed when the array
	   element is destroyed. Reference parity: seq.add(x: sink T) in standard
	   reference compilers. Literals store by value (no heap to transfer). */
	arr->p->data[arr->len] = value;
	arr->len++;
}

msString msStringArrayPop(msStringArray* arr) {
	if (arr->len <= 0) return MS_EMPTY_STRING;
	arr->len--;
	return arr->p->data[arr->len];
}

msString msStringArrayAt(msStringArray* arr, int64_t idx) {
	if (idx < 0) idx = arr->len + idx;
	if (idx < 0 || idx >= arr->len || arr->p == NULL) return MS_EMPTY_STRING;
	return arr->p->data[idx];
}

int64_t msStringArrayIndexOf(msStringArray* arr, msString value) {
	if (arr->p == NULL) return -1;
	for (int64_t i = 0; i < arr->len; i++) {
		if (msStringEquals(arr->p->data[i], value)) return i;
	}
	return -1;
}

msStringArray msStringArraySlice(msStringArray* arr, int64_t start, int64_t end) {
	if (start < 0) start = arr->len + start;
	if (end < 0) end = arr->len + end;
	if (start < 0) start = 0;
	if (end > arr->len) end = arr->len;
	if (start >= end) return MS_EMPTY_STRING_ARRAY;

	int64_t newLen = end - start;
	msStringArray result = msStringArrayNew(newLen);
	for (int64_t i = 0; i < newLen; i++) {
		/* Deep-copy non-literal strings so result owns its elements independently.
		   Without this, destroying either array would free the shared payload and
		   corrupt the other (use-after-free). Same rule as msStringArrayPush/From. */
		msString s = arr->p->data[start + i];
		if (s.p != NULL && !msIsLiteral(s)) {
			result.p->data[i] = msStringNew(s.p->data, s.len);
		} else {
			result.p->data[i] = s;
		}
	}
	result.len = newLen;
	return result;
}

msStringArray msStringArrayConcat(msStringArray* a, msStringArray b) {
	int64_t totalLen = a->len + b.len;
	if (totalLen == 0) return MS_EMPTY_STRING_ARRAY;
	msStringArray result = msStringArrayNew(totalLen);
	/* Deep-copy non-literal strings — same rule as Slice/Push/From. */
	for (int64_t i = 0; i < a->len; i++) {
		msString s = a->p->data[i];
		result.p->data[i] = (s.p != NULL && !msIsLiteral(s)) ? msStringNew(s.p->data, s.len) : s;
	}
	for (int64_t i = 0; i < b.len; i++) {
		msString s = b.p->data[i];
		result.p->data[a->len + i] = (s.p != NULL && !msIsLiteral(s)) ? msStringNew(s.p->data, s.len) : s;
	}
	result.len = totalLen;
	return result;
}

void msStringArrayReverse(msStringArray* arr) {
	if (arr->len <= 1 || arr->p == NULL) return;
	for (int64_t i = 0, j = arr->len - 1; i < j; i++, j--) {
		msString tmp = arr->p->data[i];
		arr->p->data[i] = arr->p->data[j];
		arr->p->data[j] = tmp;
	}
}

msString msStringArrayShift(msStringArray* arr) {
	if (arr->len <= 0) return MS_EMPTY_STRING;
	msString first = arr->p->data[0];
	memmove(arr->p->data, arr->p->data + 1, (arr->len - 1) * sizeof(msString));
	arr->len--;
	return first;
}

bool msStringArrayIncludes(msStringArray* arr, msString value) {
	return msStringArrayIndexOf(arr, value) >= 0;
}

int64_t msStringArrayCount(msStringArray* arr, msString value) {
	if (arr->p == NULL) return 0;
	int64_t count = 0;
	for (int64_t i = 0; i < arr->len; i++) {
		if (msStringEquals(arr->p->data[i], value)) count++;
	}
	return count;
}

static int msStringCmp(const void* a, const void* b) {
	return msStringCompare(*(const msString*)a, *(const msString*)b);
}

void msStringArraySort(msStringArray* arr) {
	if (arr->len <= 1 || arr->p == NULL) return;
	qsort(arr->p->data, arr->len, sizeof(msString), msStringCmp);
}

void msStringArrayFill(msStringArray* arr, msString value) {
	if (arr->p == NULL) return;
	/* Destroy existing strings first */
	for (int64_t i = 0; i < arr->len; i++) {
		msStringDestroy(arr->p->data[i]);
	}
	/* Fill with copies — for literals, struct copy is sufficient */
	for (int64_t i = 0; i < arr->len; i++) {
		if (msIsLiteral(value)) {
			arr->p->data[i] = value;
		} else {
			arr->p->data[i] = msStringNew(value.p->data, value.len);
		}
	}
}

msString msStringArrayJoin(msStringArray* arr, msString sep) {
	return msStringJoin(*arr, sep);
}

void msStringArrayShrink(msStringArray* arr, int64_t newLen) {
	if (newLen < 0) newLen = 0;
	if (newLen >= arr->len) return;
	/* Destroy evicted strings */
	for (int64_t i = newLen; i < arr->len; i++) {
		msStringDestroy(arr->p->data[i]);
	}
	arr->len = newLen;
}

void msStringArrayGrow(msStringArray* arr, int64_t newLen, msString value) {
	if (newLen <= arr->len) return;
	if (arr->p == NULL || arr->p->cap < newLen) {
		arr->p = (msStringPayload*)msArrayPrepareAdd(arr->len, arr->p, newLen - arr->len, sizeof(msString));
	}
	for (int64_t i = arr->len; i < newLen; i++) {
		if (msIsLiteral(value)) {
			arr->p->data[i] = value;
		} else {
			arr->p->data[i] = msStringNew(value.p->data, value.len);
		}
	}
	arr->len = newLen;
}

void msStringArraySetLen(msStringArray* arr, int64_t newLen) {
	if (newLen < arr->len) {
		msStringArrayShrink(arr, newLen);
	} else if (newLen > arr->len) {
		msStringArrayGrow(arr, newLen, MS_EMPTY_STRING);
	}
}

int64_t msStringArrayCapacity(msStringArray* arr) {
	return arr->p ? arr->p->cap : 0;
}

void msStringArraySetLenUninit(msStringArray* arr, int64_t newLen) {
	if (newLen < arr->len) {
		/* Still destroy evicted strings for safety */
		for (int64_t i = newLen; i < arr->len; i++) {
			msStringDestroy(arr->p->data[i]);
		}
		arr->len = newLen;
		return;
	}
	if (arr->p == NULL || arr->p->cap < newLen) {
		arr->p = (msStringPayload*)msArrayPrepareAddUninit(arr->len, arr->p, newLen - arr->len, sizeof(msString));
	}
	arr->len = newLen;
}

/* ===== Uint8 Array ===== */

msUint8Array msUint8ArrayNew(int64_t cap) {
	msUint8Array arr;
	arr.len = 0;
	arr.p = (msUint8Payload*)msArrayPayloadNew(cap, sizeof(uint8_t));
	return arr;
}

void msUint8ArrayDestroy(msUint8Array* arr) {
	if (arr->p != NULL) {
		free(arr->p);
		arr->p = NULL;
	}
	arr->len = 0;
}

void msUint8ArrayPush(msUint8Array* arr, uint8_t value) {
	if (arr->p == NULL || arr->p->cap < arr->len + 1) {
		arr->p = (msUint8Payload*)msArrayPrepareAdd(arr->len, arr->p, 1, sizeof(uint8_t));
	}
	arr->p->data[arr->len] = value;
	arr->len++;
}

uint8_t msUint8ArrayAt(msUint8Array* arr, int64_t idx) {
	if (idx < 0) idx = arr->len + idx;
	if (idx < 0 || idx >= arr->len || arr->p == NULL) return 0;
	return arr->p->data[idx];
}

/* ===== Ref Array ===== */

msRefArray msRefArrayNew(int64_t cap) {
	msRefArray arr;
	arr.len = 0;
	arr.p = (msRefPayload*)msArrayPayloadNew(cap, sizeof(void*));
	return arr;
}

void msRefArrayDestroy(msRefArray* arr) {
	if (arr->p != NULL) {
		for (int64_t i = 0; i < arr->len; i++) msDecref(arr->p->data[i]);
		free(arr->p);
		arr->p = NULL;
	}
	arr->len = 0;
}

void msRefArrayPush(msRefArray* arr, void* value) {
	if (arr->p == NULL || arr->p->cap < arr->len + 1) {
		arr->p = (msRefPayload*)msArrayPrepareAdd(arr->len, arr->p, 1, sizeof(void*));
	}
	arr->p->data[arr->len] = value;
	arr->len++;
}

void* msRefArrayPop(msRefArray* arr) {
	if (arr->len <= 0) return NULL;
	arr->len--;
	return arr->p->data[arr->len];
}

void* msRefArrayAt(msRefArray* arr, int64_t idx) {
	if (idx < 0) idx = arr->len + idx;
	if (idx < 0 || idx >= arr->len || arr->p == NULL) return NULL;
	return arr->p->data[idx];
}

void msRefArrayShrink(msRefArray* arr, int64_t newLen) {
	if (newLen < 0) newLen = 0;
	if (newLen >= arr->len) return;
	for (int64_t i = newLen; i < arr->len; i++) {
		msDecref(arr->p->data[i]);
		arr->p->data[i] = NULL;
	}
	arr->len = newLen;
}

void msRefArrayGrow(msRefArray* arr, int64_t newLen, void* value) {
	if (newLen <= arr->len) return;
	if (arr->p == NULL || arr->p->cap < newLen) {
		arr->p = (msRefPayload*)msArrayPrepareAdd(arr->len, arr->p, newLen - arr->len, sizeof(void*));
	}
	for (int64_t i = arr->len; i < newLen; i++) {
		arr->p->data[i] = value;
		if (value != NULL) msIncRef(value);
	}
	arr->len = newLen;
}

void msRefArraySetLen(msRefArray* arr, int64_t newLen) {
	if (newLen < arr->len) {
		msRefArrayShrink(arr, newLen);
	} else if (newLen > arr->len) {
		msRefArrayGrow(arr, newLen, NULL);
	}
}

int64_t msRefArrayCapacity(msRefArray* arr) {
	return arr->p ? arr->p->cap : 0;
}

void msRefArraySetLenUninit(msRefArray* arr, int64_t newLen) {
	if (newLen < arr->len) {
		msRefArrayShrink(arr, newLen);
		return;
	}
	if (arr->p == NULL || arr->p->cap < newLen) {
		arr->p = (msRefPayload*)msArrayPrepareAddUninit(arr->len, arr->p, newLen - arr->len, sizeof(void*));
	}
	arr->len = newLen;
}

/* ===== Splice — remove deleteCount elements starting at index ===== */

void msNumberArraySplice(msNumberArray* arr, int64_t start, int64_t deleteCount) {
	if (arr->p == NULL || start < 0 || start >= arr->len) return;
	if (deleteCount <= 0) return;
	if (start + deleteCount > arr->len) deleteCount = arr->len - start;
	int64_t remaining = arr->len - start - deleteCount;
	if (remaining > 0) {
		memmove(arr->p->data + start, arr->p->data + start + deleteCount, remaining * sizeof(double));
	}
	arr->len -= deleteCount;
}

void msStringArraySplice(msStringArray* arr, int64_t start, int64_t deleteCount) {
	if (arr->p == NULL || start < 0 || start >= arr->len) return;
	if (deleteCount <= 0) return;
	if (start + deleteCount > arr->len) deleteCount = arr->len - start;
	for (int64_t i = start; i < start + deleteCount; i++) msStringDestroy(arr->p->data[i]);
	int64_t remaining = arr->len - start - deleteCount;
	if (remaining > 0) {
		memmove(arr->p->data + start, arr->p->data + start + deleteCount, remaining * sizeof(msString));
	}
	arr->len -= deleteCount;
}

void msRefArraySplice(msRefArray* arr, int64_t start, int64_t deleteCount) {
	if (arr->p == NULL || start < 0 || start >= arr->len) return;
	if (deleteCount <= 0) return;
	if (start + deleteCount > arr->len) deleteCount = arr->len - start;
	for (int64_t i = start; i < start + deleteCount; i++) msDecref(arr->p->data[i]);
	int64_t remaining = arr->len - start - deleteCount;
	if (remaining > 0) {
		memmove(arr->p->data + start, arr->p->data + start + deleteCount, remaining * sizeof(void*));
	}
	arr->len -= deleteCount;
}

/* ===== Closure Array =====
 * Per-element destroy: decref env (function pointer is untracked). The env's
 * own typeInfo handles deeper field cleanup via msDecref's virtual dispatch.
 * Layout: msClosure structs stored inline (16B stride), NOT void* indirection. */

void msClosureArrayDestroy(msClosureArray* arr) {
	if (arr->p != NULL) {
		for (int64_t i = 0; i < arr->len; i++) {
			if (arr->p->data[i].env != NULL) {
				msDecref(arr->p->data[i].env);
			}
		}
		free(arr->p);
		arr->p = NULL;
	}
	arr->len = 0;
}

void msClosureArrayPush(msClosureArray* arr, msClosure value) {
	if (arr->p == NULL || arr->p->cap < arr->len + 1) {
		arr->p = (msClosurePayload*)msArrayPrepareAdd(arr->len, arr->p, 1, sizeof(msClosure));
	}
	/* Sink semantics: caller already incref'd env if needed; we take ownership. */
	arr->p->data[arr->len] = value;
	arr->len++;
}

void msClosureArrayCopy(msClosureArray* dest, const msClosureArray* src) {
	/* Self-assignment safety: snapshot src FIRST, build new payload from
	 * snapshot, THEN destroy dest. Matches msArrayStringCopy / msArrayRefCopy
	 * pattern (system.h). If we destroyed dest first and dest === src, the
	 * snapshot would read freed memory. */
	const int64_t len = src->len;
	const int64_t cap = src->p != NULL ? src->p->cap : 0;
	msClosurePayload* newp = NULL;
	if (src->p != NULL) {
		const size_t sz = sizeof(msClosurePayload) + (size_t)cap * sizeof(msClosure);
		newp = (msClosurePayload*)calloc(1, sz);
		newp->cap = cap;
		for (int64_t i = 0; i < len; i++) {
			newp->data[i] = src->p->data[i];
			/* Incref env — both dest and src now hold a reference. */
			if (newp->data[i].env != NULL) {
				msIncRef(newp->data[i].env);
			}
		}
	}
	msClosureArrayDestroy(dest);
	dest->len = len;
	dest->p = newp;
}

void msClosureArrayWasMoved(msClosureArray* arr) {
	arr->len = 0;
	arr->p = NULL;
}
