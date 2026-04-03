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

#endif /* MS_COMBINATOR_H */
