/*
 * MetaScript Promise Combinators — Promise.all / Promise.race
 *
 * Pure C runtime functions. No compiler changes needed.
 * Takes arrays of msFuture*, returns a new msFuture* that settles
 * when the input futures meet the combinator's condition.
 */
#ifndef MS_COMBINATOR_H
#define MS_COMBINATOR_H

#include "future.h"

/* ===== Promise.all ===== */

typedef struct {
	msFuture* result;     /* output future — resolves when all inputs resolve */
	msFuture** inputs;    /* input futures (borrowed) */
	void** values;        /* result values in order (owned) */
	int count;            /* total inputs */
	int remaining;        /* unsettled count */
	bool failed;          /* set on first rejection */
} msPromiseAllState;

typedef struct {
	msPromiseAllState* state;
	int index;
} msPromiseAllCbEnv;

/* Resolves when ALL resolve. Rejects on FIRST rejection.
 * Takes msRefArray (Promise<void>[]) — extracts .p->data and .len internally. */
void* msPromiseAll(msRefArray futures);

/* ===== Promise.race ===== */

typedef struct {
	msFuture* result;     /* output future — settles with first settled input */
	bool settled;          /* true after first settlement */
	int remaining;         /* callbacks remaining — free state when 0 */
} msPromiseRaceState;

typedef struct {
	msPromiseRaceState* state;
	msFuture* input;
} msPromiseRaceCbEnv;

/* Resolves/rejects with the FIRST settled input.
 * Takes msRefArray (Promise<void>[]) — extracts .p->data and .len internally. */
void* msPromiseRace(msRefArray futures);

/* ===== Promise.resolve / Promise.reject ===== */

/* Create pre-completed future (Reference: newFuture[T]() + complete(val)) */
static inline msFuture* msPromiseResolve(void* val) {
	msFuture* f = (msFuture*)msFutureCreate();
	msFutureComplete(f, val);
	return f;
}

/* Create pre-failed future (Reference: newFuture[T]() + fail(err)) */
static inline msFuture* msPromiseReject(void* err) {
	msFuture* f = (msFuture*)msFutureCreate();
	msFutureFail(f, err);
	return f;
}

/* ===== Promise.allSettled ===== */

typedef struct {
	msFuture* result;     /* output future — resolves when all inputs settle */
	msFuture** inputs;    /* input futures (borrowed) */
	int count;            /* total inputs */
	int remaining;        /* unsettled count */
} msPromiseAllSettledState;

typedef struct {
	msPromiseAllSettledState* state;
	int index;
} msPromiseAllSettledCbEnv;

/* Resolves when ALL settle (never rejects).
 * Takes msRefArray (Promise<void>[]) — extracts .p->data and .len internally. */
void* msPromiseAllSettled(msRefArray futures);

/* ===== Promise.any ===== */

typedef struct {
	msFuture* result;     /* output future — resolves with first fulfilled input */
	int count;            /* total inputs */
	int rejected;         /* number rejected so far */
	bool resolved;        /* true after first fulfillment */
	int remaining;        /* callbacks remaining — free state when 0 */
} msPromiseAnyState;

typedef struct {
	msPromiseAnyState* state;
	msFuture* input;
} msPromiseAnyCbEnv;

/* Resolves with FIRST fulfilled input. Rejects only if ALL reject.
 * Takes msRefArray (Promise<void>[]) — extracts .p->data and .len internally. */
void* msPromiseAny(msRefArray futures);

/* ===== new Promise(executor) ===== */

typedef struct {
	msFuture* future;
	bool settled;         /* only first resolve/reject takes effect */
} msPromiseNewEnv;

msFuture* msPromiseNew(msClosure executor);

/* ===== Promise.then / .catch / .finally ===== */

/* Type tags for typed callback dispatch.
 * 0 = void/pointer (pass void* directly)
 * 1 = int (pass void* directly — lower bits are the int value)
 * 2 = double (val is double*, dereference + free)
 * 3 = string (val is msString*, dereference + free) */
#define MS_TYPETAG_PTR    0
#define MS_TYPETAG_INT    1
#define MS_TYPETAG_DOUBLE 2
#define MS_TYPETAG_STRING 3

typedef struct {
	msFuture* output;
	msFuture* input;
	msClosure onFulfilled;
	int typeTag;
} msFutureThenEnv;

typedef struct {
	msFuture* output;
	msFuture* input;
	msClosure onRejected;
	int typeTag;
} msFutureCatchEnv;

typedef struct {
	msFuture* output;
	msFuture* input;
	msClosure onSettled;
} msFutureFinallyEnv;

msFuture* msFutureThen(msFuture* input, msClosure onFulfilled);
msFuture* msFutureThenTyped(msFuture* input, msClosure onFulfilled, int typeTag);
msFuture* msFutureCatch(msFuture* input, msClosure onRejected);
msFuture* msFutureCatchTyped(msFuture* input, msClosure onRejected, int typeTag);
msFuture* msFutureFinally(msFuture* input, msClosure onSettled);

/* ===== Typed .then / .catch / .finally (per-T, reads input as inline typed field) =====
 * Correct when input future was populated via msFutureCompleteT (inline typed storage).
 * Each variant reads ((msFuture_<T>*)input)->value to preserve sizeof(T) on pass-through
 * — the generic msFuture_ptr.value read would truncate msString (16B) and structs > 8B.
 *
 * The output future is still msFuture_ptr* for now; .then callbacks don't currently
 * return values through the chain, so output storage type is irrelevant. */

/* Typed .then: read input as T, pass to callback, complete output with NULL.
 *
 *   name      — generated function name (e.g., msFutureThen_double)
 *   fut_type  — typed future struct (e.g., msFuture_double)
 *   T         — value type read from the input (e.g., double)
 *   arg_type  — callback parameter type (usually == T; separate in case of
 *               ABI differences between storage and argument passing)
 *
 * Preconditions: input->value was written via msFutureCompleteT on the same fut_type.
 * Passing a boxed-storage input (spawn legacy path) reinterprets the heap pointer
 * as T — undefined behavior. A Session-3 assert will catch this at runtime. */
#define MS_DEFINE_FUTURE_THEN(name, fut_type, T, arg_type) \
static inline void name##_cb(void* raw) { \
    msFutureThenEnv* e = (msFutureThenEnv*)raw; \
    if (e->input->base.failed || e->input->base.cancelled) { \
        msFutureFail(e->output, e->input->base.error); \
        free(e); \
        return; \
    } \
    T val = ((fut_type*)e->input)->value; \
    void* fn = (void*)e->onFulfilled.fn; \
    void* env = e->onFulfilled.env; \
    if (env) ((void(*)(arg_type, void*))fn)(val, env); \
    else ((void(*)(arg_type))fn)(val); \
    if (msErr) { \
        msFutureFail(e->output, (void*)msCurrException); \
        msErr = false; msCurrException = NULL; \
    } else { \
        msFutureComplete(e->output, NULL); \
    } \
    free(e); \
} \
static inline msFuture* name(msFuture* input, msClosure onFulfilled) { \
    msFuture* output = (msFuture*)msFutureCreate(); \
    msFutureThenEnv* env = (msFutureThenEnv*)malloc(sizeof(msFutureThenEnv)); \
    env->output = output; env->input = input; env->onFulfilled = onFulfilled; env->typeTag = 0; \
    msFutureAddCallback(input, (msClosure){.fn = (msClosureFn)name##_cb, .env = env}); \
    return output; \
}

/* Typed .finally: invoke handler, then propagate input (value or error) to output
 * via typed msFutureCompleteT. Error propagation goes through msFutureFail
 * (not type-specific). */
#define MS_DEFINE_FUTURE_FINALLY(name, fut_type) \
static inline void name##_cb(void* raw) { \
    msFutureFinallyEnv* e = (msFutureFinallyEnv*)raw; \
    if (e->onSettled.env != NULL) { \
        ((void(*)(void*))e->onSettled.fn)(e->onSettled.env); \
    } else { \
        ((void(*)(void))e->onSettled.fn)(); \
    } \
    if (e->input->base.failed || e->input->base.cancelled) { \
        msFutureFail(e->output, e->input->base.error); \
    } else { \
        fut_type* srcT = (fut_type*)e->input; \
        fut_type* dstT = (fut_type*)e->output; \
        msFutureCompleteT(dstT, srcT->value); \
    } \
    free(e); \
} \
static inline msFuture* name(msFuture* input, msClosure onSettled) { \
    msFuture* output = (msFuture*)msAlloc(sizeof(fut_type)); \
    msFutureFinallyEnv* env = (msFutureFinallyEnv*)malloc(sizeof(msFutureFinallyEnv)); \
    env->output = output; env->input = input; env->onSettled = onSettled; \
    msFutureAddCallback(input, (msClosure){.fn = (msClosureFn)name##_cb, .env = env}); \
    return output; \
}

/* Typed .catch: on success, propagate input value to output via typed complete.
 * On error, invoke handler (error is always msString in MetaScript), complete output
 * with NULL on handler success or propagate handler's rethrow. */
#define MS_DEFINE_FUTURE_CATCH(name, fut_type) \
static inline void name##_cb(void* raw) { \
    msFutureCatchEnv* e = (msFutureCatchEnv*)raw; \
    if (e->input->base.failed || e->input->base.cancelled) { \
        void* err = e->input->base.error; \
        e->input->base.error = NULL; \
        void* fn = (void*)e->onRejected.fn; \
        void* env = e->onRejected.env; \
        msString sval = err ? *(msString*)err : MS_EMPTY_STRING; \
        if (env) ((void(*)(msString, void*))fn)(sval, env); \
        else ((void(*)(msString))fn)(sval); \
        if (msErr) { \
            msFutureFail(e->output, (void*)msCurrException); \
            msErr = false; msCurrException = NULL; \
        } else { \
            msFutureComplete(e->output, NULL); \
        } \
    } else { \
        fut_type* srcT = (fut_type*)e->input; \
        fut_type* dstT = (fut_type*)e->output; \
        msFutureCompleteT(dstT, srcT->value); \
    } \
    free(e); \
} \
static inline msFuture* name(msFuture* input, msClosure onRejected) { \
    msFuture* output = (msFuture*)msAlloc(sizeof(fut_type)); \
    msFutureCatchEnv* env = (msFutureCatchEnv*)malloc(sizeof(msFutureCatchEnv)); \
    env->output = output; env->input = input; env->onRejected = onRejected; env->typeTag = 3; \
    msFutureAddCallback(input, (msClosure){.fn = (msClosureFn)name##_cb, .env = env}); \
    return output; \
}

MS_DEFINE_FUTURE_THEN(msFutureThen_double, msFuture_double, double, double)
MS_DEFINE_FUTURE_THEN(msFutureThen_int32,  msFuture_int32,  int32_t, int32_t)
MS_DEFINE_FUTURE_THEN(msFutureThen_int64,  msFuture_int64,  int64_t, int64_t)
MS_DEFINE_FUTURE_THEN(msFutureThen_bool,   msFuture_bool,   bool,    bool)
MS_DEFINE_FUTURE_THEN(msFutureThen_ptr,    msFuture_ptr,    void*,   void*)

MS_DEFINE_FUTURE_FINALLY(msFutureFinally_double, msFuture_double)
MS_DEFINE_FUTURE_FINALLY(msFutureFinally_int32,  msFuture_int32)
MS_DEFINE_FUTURE_FINALLY(msFutureFinally_int64,  msFuture_int64)
MS_DEFINE_FUTURE_FINALLY(msFutureFinally_bool,   msFuture_bool)
MS_DEFINE_FUTURE_FINALLY(msFutureFinally_ptr,    msFuture_ptr)

/* msFutureCatch_msString / msFutureFinally_msString / msFutureThen_msString
 * are defined in system.h where msString is available. msFutureCatch_<primitive>
 * variants are also defined there (msString is needed for the error handler). */

#endif /* MS_COMBINATOR_H */
