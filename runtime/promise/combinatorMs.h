/*
 * C primitives under the combinators written in MetaScript (std/core/promise/combinator.cms):
 * the field reads, macros and allocator calls a .cms body cannot name itself.
 */
#ifndef MS_COMBINATOR_MS_H
#define MS_COMBINATOR_MS_H

#include "runtime/promise/combinator.h"

static inline int32_t msPromiseArrayCount(void* arr) {
	msRefArray* a = (msRefArray*)arr;
	return (a != NULL && a->p != NULL) ? (int32_t)a->len : 0;
}

static inline void* msPromiseArrayAt(void* arr, int32_t i) {
	return ((msRefArray*)arr)->p->data[i];
}

static inline void msPromiseHold(void* p) { msIncref(p); }
static inline void msPromiseRelease(void* p) { msDecrefAny(p); }

static inline void** msPromiseSlots(int32_t count) {
	return (void**)msMemAlloc((size_t)count * sizeof(void*));
}

static inline void** msPromiseSlotsZeroed(int32_t count) {
	return (void**)msMemAllocN0((size_t)count, sizeof(void*));
}

static inline void msPromiseFreeValueOnDestroy(void* fut) {
	((msFuture*)fut)->base.valueDestructor = free;
}

static inline bool msPromiseInputRejected(void* f) {
	return ((msFuture*)f)->base.failed || ((msFuture*)f)->base.cancelled;
}

static inline void* msPromiseInputError(void* f) { return ((msFuture*)f)->base.error; }
static inline void* msPromiseInputValue(void* f) { return ((msFuture*)f)->value; }

static inline void msPromiseCompleteEmpty(void* fut) { msFutureComplete(fut, NULL); }

static inline void msPromiseCellOnDestroy(void* fut) {
	((msFuture*)fut)->base.valueDestructor = msPromiseAllArrRelease;
}

static inline void* msPromiseVtMake(const void* vt, int32_t count) {
	return ((const msPromiseAllVt*)vt)->make(count);
}

static inline void msPromiseVtCollect(const void* vt, void* arr, int32_t index, void* fut, void* shareFn) {
	((const msPromiseAllVt*)vt)->collect(arr, index, fut, shareFn);
}

static inline int32_t msPromiseLoadAcquire(void* p) {
	return atomic_load_explicit((_Atomic(int32_t)*)p, memory_order_acquire);
}

static inline int32_t msPromiseExchangeAcqRel(void* p, int32_t v) {
	return atomic_exchange_explicit((_Atomic(int32_t)*)p, v, memory_order_acq_rel);
}

static inline int32_t msPromiseFetchSubAcqRel(void* p, int32_t n) {
	return atomic_fetch_sub_explicit((_Atomic(int32_t)*)p, n, memory_order_acq_rel);
}

static inline int32_t msPromiseFetchAddAcqRel(void* p, int32_t n) {
	return atomic_fetch_add_explicit((_Atomic(int32_t)*)p, n, memory_order_acq_rel);
}

static void msPromiseFirstGenericDeliver(void* result, void* input, void* shareFn, void* dropFn, void* dropEnv) {
	(void)shareFn; (void)dropFn; (void)dropEnv;
	msFutureComplete(result, ((msFuture*)input)->value);
}

static const msPromiseFirstVt msPromiseFirstGenericVt = { .futSize = sizeof(msFuture), .deliver = msPromiseFirstGenericDeliver };

static inline const void* msPromiseFirstGeneric(void) { return &msPromiseFirstGenericVt; }

static inline void* msPromiseFirstCreate(const void* vt) {
	return msAllocTyped(((const msPromiseFirstVt*)vt)->futSize, &msFutureTypeInfo);
}

static inline void msPromiseFirstDeliver(const void* vt, void* result, void* input, void* shareFn, void* dropFn, void* dropEnv) {
	((const msPromiseFirstVt*)vt)->deliver(result, input, shareFn, dropFn, dropEnv);
}

static inline void* msPromiseAllRejectedError(void) {
	return msMakeError(msStringFromCStr("All promises were rejected"));
}

void msPromiseFirstCb(void* env);

static inline void msPromiseFirstWatch(void* fut, void* env) {
	msFutureAddCallback(fut, (msClosure){ .fn = (msClosureFn)msPromiseFirstCb, .env = env });
}

void msPromiseAllCb(void* env);
void msPromiseAllTypedCb(void* env);

static inline void msPromiseAllTypedWatch(void* fut, void* env) {
	msFutureAddCallback(fut, (msClosure){ .fn = (msClosureFn)msPromiseAllTypedCb, .env = env });
}

static inline void msPromiseAllWatch(void* fut, void* env) {
	msFutureAddCallback(fut, (msClosure){ .fn = (msClosureFn)msPromiseAllCb, .env = env });
}

#endif
