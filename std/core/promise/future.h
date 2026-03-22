/*
 * MetaScript Future Runtime — Monomorphic Future<T>
 *
 * Base struct (msFutureBase) holds shared fields: finished, error, callbacks.
 * Per-type structs extend base with typed value field (C struct inheritance).
 * Event loop, callbacks, dispatch operate on msFutureBase*.
 * Only complete() and read() are typed — zero boxing overhead.
 */
#ifndef MS_FUTURE_H
#define MS_FUTURE_H

#include <stdbool.h>
#include <stdlib.h>
#include <assert.h>

/* ARC runtime — futures participate in DRC refcounting.
 * arc.h is always included before future.h (via native.h include order).
 * Generated code emits msIncref/msDecref on future variables,
 * so futures must be allocated via msAlloc (with refcount header). */
#include "std/runtime/arc.h"

/* ===== Thread-Local Storage (Standard reference threadvar pattern) ===== */

#ifndef MS_THREAD_LOCAL
#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L && !defined(__STDC_NO_THREADS__)
  #define MS_THREAD_LOCAL _Thread_local
#elif defined(__GNUC__) || defined(__clang__)
  #define MS_THREAD_LOCAL __thread
#elif defined(_MSC_VER)
  #define MS_THREAD_LOCAL __declspec(thread)
#else
  #define MS_THREAD_LOCAL /* fallback: single-threaded */
#endif
#endif

/* Forward decl — msClosure defined in system.h, but we need it here.
 * Re-declare the struct layout to avoid circular include. */
#ifndef MS_CLOSURE_DEFINED
#define MS_CLOSURE_DEFINED
typedef void (*msClosureFn)(void*, ...);
typedef struct {
	msClosureFn fn;
	void* env;
} msClosure;
#endif

/* ===== callSoon routing (Standard reference threadvar pattern) ===== */

typedef void (*msCallSoonFn)(msClosure cb);
extern MS_THREAD_LOCAL msCallSoonFn msCallSoonProc; /* set by dispatcher init */

static inline void msCallSoon(msClosure cb) {
	if (msCallSoonProc == NULL) {
		/* No dispatcher — call immediately (Standard reference fallback) */
		((void(*)(void*))cb.fn)(cb.env);
	} else {
		msCallSoonProc(cb);
	}
}

/* ===== Callback list (Standard reference CallbackList pattern — singly-linked) ===== */

typedef struct msFutureCb {
	void (*fn)(void*);
	void* env;
	struct msFutureCb* next;
} msFutureCb;

/* ===== Future Base (shared fields — used by event loop, callbacks, dispatch) ===== */

typedef struct msFutureBase {
	bool finished;
	bool failed;          /* set by msFutureFail (even when error payload is NULL) */
	bool cancelled;       /* set by msFutureCancel */
	bool isBoxed;         /* true = void* boxed value, false = typed value in struct */
	void* error;          /* error payload (may be NULL even when failed) */
	void (*valueDestructor)(void*); /* optional: frees value on destroy (combinators) */
	msFutureCb* callbacks;
	msFutureCb* cbTail;   /* tail pointer for O(1) append */
} msFutureBase;

/* ===== Monomorphic Future Structs =====
 * Each Future<T> gets a typed struct with base as FIRST field.
 * C guarantees: pointer to struct == pointer to first member.
 * So msFuture_double* can safely cast to msFutureBase*.
 *
 * Codegen emits MS_FUTURE_STRUCT for each instantiated Promise<T>. */

#define MS_FUTURE_STRUCT(name, valtype) \
	typedef struct name { msFutureBase base; valtype value; } name

/* Common typed futures (always available) */
MS_FUTURE_STRUCT(msFuture_double, double);
MS_FUTURE_STRUCT(msFuture_int32, int32_t);
MS_FUTURE_STRUCT(msFuture_int64, int64_t);
MS_FUTURE_STRUCT(msFuture_bool, bool);

/* Future<void> = just the base (no value field) */
typedef msFutureBase msFuture_void;

/* Future<ptr> — fallback for reference/pointer types (void* value) */
MS_FUTURE_STRUCT(msFuture_ptr, void*);

/* Backward compat: msFuture = msFuture_ptr (used by combinators, dispatch) */
typedef msFuture_ptr msFuture;

/* ===== Base Operations (work on any future via msFutureBase*) ===== */

/* Allocate a typed future. Always allocates at least base + MS_FUTURE_VALUE_MAX_SIZE
 * to prevent buffer overflow when combinators read .value on any future type. */
#define MS_FUTURE_VALUE_MAX_SIZE 16  /* sizeof(msString) — largest value type */
#define MS_FUTURE_MIN_ALLOC (sizeof(msFutureBase) + MS_FUTURE_VALUE_MAX_SIZE)
#define msFutureCreateT(type) ((type*)msAlloc(sizeof(type) > MS_FUTURE_MIN_ALLOC ? sizeof(type) : MS_FUTURE_MIN_ALLOC))

/* Untyped create — returns void* so it can be assigned to any typed future pointer.
 * Allocates enough for the LARGEST value type (msString = 16 bytes) to prevent
 * buffer overflow when msFutureCompleteT writes typed values.
 * Reference parity: newFuture[T]() allocates based on sizeof(T). Our untyped version
 * must be safe for any T, so we use the max. 8 bytes overhead for non-string futures. */
static inline void* msFutureCreate(void) {
	return msAlloc(MS_FUTURE_MIN_ALLOC);
}

/* Alias for combinator code clarity */
#define msFutureCreateUntyped msFutureCreate

/* Destroy future — clean up value (if destructor set), callbacks, free via ARC header.
 * Works generically on any future type via msFutureBase* cast.
 * valueDestructor is set by combinators (Promise.all) to free the values array. */
static inline void msFutureDestroyInner(void* fp) {
	msFutureBase* f = (msFutureBase*)fp;
	if (f == NULL) return;
	if (f->valueDestructor != NULL) {
		/* Value is the first field after base — access via msFuture_ptr layout */
		void* val = ((msFuture_ptr*)fp)->value;
		if (val != NULL) f->valueDestructor(val);
	}
	msFutureCb* cb = f->callbacks;
	while (cb) {
		msFutureCb* next = cb->next;
		free(cb);
		cb = next;
	}
	msDestroyAndDispose(f);
}

/* Non-DRC destroy (direct call) */
static inline void msFutureDestroy(void* f) { msFutureDestroyInner(f); }

/* Standard reference future.finished parity */
static inline bool msFutureFinished(void* fp) {
	return ((msFutureBase*)fp)->finished;
}

/* Fire all registered callbacks via callSoon (reference parity).
 * Deferred execution prevents reentrancy during msProcessTimers/msFutureComplete. */
static inline void msFutureFireCallbacks(msFutureBase* f) {
	msFutureCb* cb = f->callbacks;
	f->callbacks = NULL;
	f->cbTail = NULL;
	while (cb) {
		msCallSoon((msClosure){ .fn = (msClosureFn)cb->fn, .env = cb->env });
		msFutureCb* next = cb->next;
		free(cb);
		cb = next;
	}
}

/* Standard reference fail(fut, err) parity — sets error + fires callbacks.
 * Works on any future type via msFutureBase*. */
static inline void msFutureFail(void* fp, void* err) {
	msFutureBase* f = (msFutureBase*)fp;
	if (f->finished) return;
	f->error = err;
	f->failed = true;
	f->finished = true;
	msFutureFireCallbacks(f);
}

/* Cancel a pending future — clears callbacks without firing, marks finished+cancelled. */
static inline void msFutureCancel(void* fp) {
	msFutureBase* f = (msFutureBase*)fp;
	if (f->finished) return;
	msFutureCb* cb = f->callbacks;
	f->callbacks = NULL;
	f->cbTail = NULL;
	while (cb) {
		msFutureCb* next = cb->next;
		free(cb);
		cb = next;
	}
	f->cancelled = true;
	f->finished = true;
}

/* Check if future was failed */
static inline bool msFutureFailed(void* fp) { return ((msFutureBase*)fp)->failed; }

/* Check if future was cancelled */
static inline bool msFutureCancelled(void* fp) { return ((msFutureBase*)fp)->cancelled; }

/* Add callback — if already finished, defer via callSoon; else append to list. */
static inline void msFutureAddCallback(void* fp, msClosure cb) {
	msFutureBase* f = (msFutureBase*)fp;
	if (f->finished) {
		msCallSoon(cb);
		return;
	}
	msFutureCb* node = (msFutureCb*)malloc(sizeof(msFutureCb));
	node->fn = (void(*)(void*))cb.fn;
	node->env = cb.env;
	node->next = NULL;
	if (f->cbTail == NULL) {
		f->callbacks = node;
		f->cbTail = node;
	} else {
		f->cbTail->next = node;
		f->cbTail = node;
	}
}

/* ===== Typed Complete / Read (monomorphic — no boxing) ===== */

/* Complete a typed future — sets value + fires callbacks.
 * Usage: msFutureCompleteT(myDoubleFut, 3.14);
 * Works for any MS_FUTURE_STRUCT type. For void futures, use msFutureCompleteVoid. */
#define msFutureCompleteT(f, val) do { \
	if (((msFutureBase*)(f))->finished) break; \
	(f)->value = (val); \
	((msFutureBase*)(f))->isBoxed = false; \
	((msFutureBase*)(f))->finished = true; \
	msFutureFireCallbacks((msFutureBase*)(f)); \
} while(0)

/* Complete a void future (no value) */
static inline void msFutureCompleteVoid(void* fp) {
	msFutureBase* f = (msFutureBase*)fp;
	if (f->finished) return;
	f->finished = true;
	msFutureFireCallbacks(f);
}

/* Complete with void* value (boxed path — spawn pipe, combinators) */
static inline void msFutureComplete(void* fp, void* val) {
	msFuture* f = (msFuture*)fp;
	if (f->base.finished) return;
	f->value = val;
	f->base.isBoxed = true;
	f->base.finished = true;
	msFutureFireCallbacks(&f->base);
}

/* ===== Error Re-raising (Standard reference read parity) ===== */

extern MS_THREAD_LOCAL bool msErr;
extern MS_THREAD_LOCAL void* msErrPayload;

/* Check error status on a future base (used before typed read) */
static inline bool msFutureCheckErr(void* fp) {
	msFutureBase* f = (msFutureBase*)fp;
	assert(f->finished && "Future not yet finished");
	if (f->cancelled) { msErr = true; msErrPayload = NULL; return true; }
	if (f->failed) { msErr = true; msErrPayload = f->error; return true; }
	return false;
}

/* Read typed value. Usage: double v = msFutureReadT(myDoubleFut, 0.0);
 * Sets msErr if failed/cancelled and returns zeroval. */
#define msFutureReadT(f, zeroval) \
	(msFutureCheckErr(f) ? (zeroval) : (f)->value)

/* ===== Value Boxing — Inline (zero-copy, zero-malloc) =====
 * Store small values directly in the void* bits instead of heap-allocating.
 * Safe on 64-bit: sizeof(void*) = 8 >= sizeof(double) = sizeof(int64_t).
 * Double uses memcpy to avoid strict aliasing violation.
 * String boxing (msBoxString in native.h) still heap-allocates (16 bytes > pointer). */

#include <string.h> /* memcpy */

static inline void* msBoxDouble(double v) { void* p = NULL; memcpy(&p, &v, sizeof(double)); return p; }
static inline double msUnboxDouble(void* p) { double v; memcpy(&v, &p, sizeof(double)); return v; }
static inline void* msBoxInt32(int32_t v) { return (void*)(intptr_t)v; }
static inline int32_t msUnboxInt32(void* p) { return (int32_t)(intptr_t)p; }
static inline void* msBoxBool(bool v) { return (void*)(intptr_t)v; }
static inline bool msUnboxBool(void* p) { return (bool)(intptr_t)p; }

/* ===== Per-Type Smart Read Functions =====
 * Handle both boxed (spawn) and typed (async) paths via runtime isBoxed flag.
 * Consumer calls msFutureReadDouble($yf) — transparently handles both. */

static inline double msFutureReadDouble(void* fp) {
	msFutureBase* f = (msFutureBase*)fp;
	assert(f->finished && "Future not yet finished");
	if (f->cancelled || f->failed) { msErr = true; msErrPayload = f->error; return 0.0; }
	if (f->isBoxed) return msUnboxDouble(((msFuture_ptr*)fp)->value);
	return ((msFuture_double*)fp)->value;
}

static inline int32_t msFutureReadInt32(void* fp) {
	msFutureBase* f = (msFutureBase*)fp;
	assert(f->finished && "Future not yet finished");
	if (f->cancelled || f->failed) { msErr = true; msErrPayload = f->error; return 0; }
	if (f->isBoxed) return msUnboxInt32(((msFuture_ptr*)fp)->value);
	return ((msFuture_int32*)fp)->value;
}

static inline bool msFutureReadBool(void* fp) {
	msFutureBase* f = (msFutureBase*)fp;
	assert(f->finished && "Future not yet finished");
	if (f->cancelled || f->failed) { msErr = true; msErrPayload = f->error; return false; }
	if (f->isBoxed) return msUnboxBool(((msFuture_ptr*)fp)->value);
	return ((msFuture_bool*)fp)->value;
}

/* msString needs forward declaration from string header — defined after msBoxString in native.h.
 * For now, use msFutureRead (void*) + cast for string reads. */

/* Legacy untyped read (for combinators, backward compat) */
static inline void* msFutureRead(void* fp) {
	msFuture* f = (msFuture*)fp;
	assert(f->base.finished && "Future not yet finished");
	if (f->base.cancelled) { msErr = true; msErrPayload = NULL; return NULL; }
	if (f->base.failed) { msErr = true; msErrPayload = f->base.error; return NULL; }
	void* v = f->value;
	f->value = NULL;
	return v;
}

/* ===== DRC lifecycle ===== */

#define msFutureDrcDestroy(f) do { if ((f) != NULL) { msFutureDestroyInner(f); } } while(0)
#define msFutureDrcWasMoved(f) do { (f) = NULL; } while(0)

/* (Boxing functions moved above per-type read functions for forward declaration order) */

/* ===== Async Stepper Callback (createCb pattern) ===== */
/* The stepper returns the next msFutureBase* to wait on, or NULL when done.
 * msAsyncCb drives the stepper: calls it, checks the result, re-registers on yielded future.
 * This eliminates the self-referencing closure problem. */

typedef struct {
	msClosure stepper;
} msAsyncCbEnv;

void msAsyncCb(void* raw);
void msAsyncStart(void* retFut, msClosure stepper);

/* ===== String boxing (kept for spawn pipe boundary) ===== */
/* msBoxString/msUnboxString defined in native.h (needs msString type) */

#endif /* MS_FUTURE_H */
