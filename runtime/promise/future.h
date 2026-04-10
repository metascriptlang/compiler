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
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <assert.h>

/* ARC runtime — futures participate in DRC refcounting.
 * arc.h is always included before future.h (via native.h include order).
 * Generated code emits msIncref/msDecref on future variables,
 * so futures must be allocated via msAlloc (with refcount header). */
#include "runtime/drc.h"

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
	_Atomic(bool) finished; /* atomic: cross-thread visibility for worker await */
	bool failed;          /* set by msFutureFail (even when error payload is NULL) */
	bool cancelled;       /* set by msFutureCancel */
	void* error;          /* error payload (may be NULL even when failed) */
	void (*valueDestructor)(void*); /* optional: frees value on destroy (combinators) */
	msFutureCb* callbacks;
	msFutureCb* cbTail;   /* tail pointer for O(1) append */
} msFutureBase;

/* Verify: finished is the first field. awaitGroup.c uses msFutureBaseMinimal
 * (a 1-field struct) to set finished without including all of future.h. */
_Static_assert(offsetof(msFutureBase, finished) == 0, "msFutureBase.finished must be at offset 0");

/* Primitive boxing stores value bits IN the void* pointer. Reading those bits
 * as typed inline fields (msFuture_double.value, msFuture_int32.value) is only
 * correct on little-endian where the lower bytes of the 8-byte void* contain
 * the value. arm64 and x86_64 are both little-endian. */
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "future primitive boxing requires little-endian (arm64/x86_64)"
#endif

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

/* Session 4: value field offset must be consistent across all future types.
 * msWaitForStruct and msSpawnWorkerRun cast through msFuture_ptr* to reach
 * the value bytes at the correct offset. */
_Static_assert(offsetof(msFuture_ptr, value) == offsetof(msFuture_double, value),
    "future value field offset must be consistent (double)");
_Static_assert(offsetof(msFuture_ptr, value) == offsetof(msFuture_int32, value),
    "future value field offset must be consistent (int32)");

/* ===== Base Operations (work on any future via msFutureBase*) ===== */

/* ===== CRITICAL: Future Allocation Sizing Contract =====
 *
 * After Session 4 (isBoxed removal), there is NO runtime safety net for
 * undersized future allocations. Every allocation site MUST match the
 * value type that will be written via msFutureCompleteT:
 *
 *   Value type          Allocator to use
 *   ──────────────────  ─────────────────────────────────────
 *   void                msFutureCreate()     [no value field]
 *   double/int32/bool   msFutureCreate()     [fits in void* slot]
 *   void* / Ref<T>      msFutureCreate()     [pointer = 8 bytes]
 *   msString (16 bytes) msFutureCreateInline [codegen-intercepted, sizeof(msFuture_msString)]
 *   struct / tuple       msFutureCreateInline [codegen-intercepted, sizeof(msFuture_<T>)]
 *
 * If you call msFutureCreate() and then write a value larger than
 * sizeof(void*) via msFutureCompleteT, you WILL overflow the heap
 * silently — no assert, no crash, just memory corruption.
 *
 * The transform pipeline enforces this automatically:
 *   - asyncBridge.ms:makeRetFutAlloc    selects allocator by return type
 *   - builtinLower.ms:PromiseSpawn      selects msSpawn vs msSpawnInto
 *   - actorLower.ms:buildCallProxy      selects allocator for reply futures
 *   - combinator.h:MS_DEFINE_FUTURE_*   uses msAlloc(sizeof(fut_type))
 *
 * When adding a new future allocation site, check isStructLikeType()
 * (exported from builtinLower.ms) to determine which allocator to use.
 */

/* Allocate a typed future by exact size. */
#define msFutureCreateT(type) ((type*)msAlloc(sizeof(type)))

/* Untyped create — allocates msFuture_ptr (base + void* value = 8 bytes).
 * ONLY safe for: void, double, int32, bool, pointer types.
 * NOT safe for: msString (16 bytes), struct, tuple — use msFutureCreateInline. */
static inline void* msFutureCreate(void) {
	return msAlloc(sizeof(msFuture_ptr));
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
	return atomic_load_explicit(&((msFutureBase*)fp)->finished, memory_order_acquire);
}

/* Global completion notification — wakes worker threads blocking on futures.
 * Implemented in dispatch.c (Change 4: global completion condvar). */
extern void msNotifyFutureComplete(void);

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
	msNotifyFutureComplete();
}

/* Standard reference fail(fut, err) parity — sets error + fires callbacks.
 * Works on any future type via msFutureBase*. */
static inline void msFutureFail(void* fp, void* err) {
	msFutureBase* f = (msFutureBase*)fp;
	if (atomic_load_explicit(&f->finished, memory_order_acquire)) return;
	f->error = err;
	f->failed = true;
	atomic_store_explicit(&f->finished, true, memory_order_release);
	msFutureFireCallbacks(f);
}

/* Cancel a pending future — clears callbacks without firing, marks finished+cancelled. */
static inline void msFutureCancel(void* fp) {
	msFutureBase* f = (msFutureBase*)fp;
	if (atomic_load_explicit(&f->finished, memory_order_acquire)) return;
	msFutureCb* cb = f->callbacks;
	f->callbacks = NULL;
	f->cbTail = NULL;
	while (cb) {
		msFutureCb* next = cb->next;
		free(cb);
		cb = next;
	}
	f->cancelled = true;
	atomic_store_explicit(&f->finished, true, memory_order_release);
	msNotifyFutureComplete();
}

/* Check if future was failed */
static inline bool msFutureFailed(void* fp) { return ((msFutureBase*)fp)->failed; }

/* Check if future was cancelled */
static inline bool msFutureCancelled(void* fp) { return ((msFutureBase*)fp)->cancelled; }

/* Add callback — if already finished, defer via callSoon; else append to list. */
static inline void msFutureAddCallback(void* fp, msClosure cb) {
	msFutureBase* f = (msFutureBase*)fp;
	if (atomic_load_explicit(&f->finished, memory_order_acquire)) {
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
	if (atomic_load_explicit(&((msFutureBase*)(f))->finished, memory_order_acquire)) break; \
	(f)->value = (val); \
	atomic_store_explicit(&((msFutureBase*)(f))->finished, true, memory_order_release); \
	msFutureFireCallbacks((msFutureBase*)(f)); \
} while(0)

/* Complete a void future (no value) */
static inline void msFutureCompleteVoid(void* fp) {
	msFutureBase* f = (msFutureBase*)fp;
	if (atomic_load_explicit(&f->finished, memory_order_acquire)) return;
	atomic_store_explicit(&f->finished, true, memory_order_release);
	msFutureFireCallbacks(f);
}

/* Complete with void* value (combinators, legacy paths) */
static inline void msFutureComplete(void* fp, void* val) {
	msFuture* f = (msFuture*)fp;
	if (atomic_load_explicit(&f->base.finished, memory_order_acquire)) return;
	f->value = val;
	atomic_store_explicit(&f->base.finished, true, memory_order_release);
	msFutureFireCallbacks(&f->base);
}

/* ===== Phase 5: Future Chaining (actor suspension) ===== */

/* Chain src → dst: when src completes, copy its result into dst and fire dst's callbacks.
 * Used by actor dispatch to pipe async _impl's $retFut into CALL reply future.
 *
 * Generic untyped chain: used by combinators and as a fallback for struct returns.
 * Reads src as msFuture_ptr.value (8 bytes). Correct for ptr/double/int32/bool
 * (bit-level equivalent on 64-bit), incorrect for msString/structs > 8 bytes.
 * For typed chaining (correct for any T), use msFutureChain_<T> variants below. */
typedef struct { void* src; void* dst; } msFutureChainPair;

static inline void msFutureChainCb(void* raw, ...) {
    msFutureChainPair* pair = (msFutureChainPair*)raw;
    msFutureBase* src = (msFutureBase*)pair->src;
    if (src->failed) {
        msFutureFail(pair->dst, src->error);
    } else {
        void* val = ((msFuture*)pair->src)->value;
        msFutureComplete(pair->dst, val);
    }
    free(pair);
}

static inline void msFutureChain(void* src, void* dst) {
    if (src == NULL || dst == NULL) return;
    msFutureChainPair* pair = (msFutureChainPair*)malloc(sizeof(msFutureChainPair));
    pair->src = src;
    pair->dst = dst;
    msFutureAddCallback(src, (msClosure){
        .fn = (msClosureFn)msFutureChainCb,
        .env = (void*)pair
    });
}

/* ===== Typed Future Chain (per-T) =====
 * Reads src as msFuture_<T>* → T, writes dst as msFuture_<T>* via msFutureCompleteT.
 * Correct for ANY sizeof(T) up to MS_FUTURE_VALUE_MAX_SIZE (16 bytes).
 * Selected by actorLower based on the method's declared return type. */

#define MS_DEFINE_FUTURE_CHAIN(name, fut_type) \
static inline void name##_cb(void* raw, ...) { \
    msFutureChainPair* pair = (msFutureChainPair*)raw; \
    msFutureBase* srcBase = (msFutureBase*)pair->src; \
    if (srcBase->failed) { \
        msFutureFail(pair->dst, srcBase->error); \
    } else { \
        fut_type* srcT = (fut_type*)pair->src; \
        fut_type* dstT = (fut_type*)pair->dst; \
        msFutureCompleteT(dstT, srcT->value); \
    } \
    free(pair); \
} \
static inline void name(void* src, void* dst) { \
    if (src == NULL || dst == NULL) return; \
    msFutureChainPair* pair = (msFutureChainPair*)malloc(sizeof(msFutureChainPair)); \
    pair->src = src; \
    pair->dst = dst; \
    msFutureAddCallback(src, (msClosure){ \
        .fn = (msClosureFn)name##_cb, \
        .env = (void*)pair \
    }); \
}

MS_DEFINE_FUTURE_CHAIN(msFutureChain_double, msFuture_double)
MS_DEFINE_FUTURE_CHAIN(msFutureChain_int32, msFuture_int32)
MS_DEFINE_FUTURE_CHAIN(msFutureChain_int64, msFuture_int64)
MS_DEFINE_FUTURE_CHAIN(msFutureChain_bool, msFuture_bool)
MS_DEFINE_FUTURE_CHAIN(msFutureChain_ptr, msFuture_ptr)

/* ===== Error Re-raising (Standard reference read parity) ===== */

extern MS_THREAD_LOCAL bool msErr;
extern MS_THREAD_LOCAL void* msErrPayload;

/* Check error status on a future base (used before typed read) */
static inline bool msFutureCheckErr(void* fp) {
	msFutureBase* f = (msFutureBase*)fp;
	assert(atomic_load_explicit(&f->finished, memory_order_acquire) && "Future not yet finished");
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

/* ===== Per-Type Read Functions =====
 * All futures now store values inline (typed field). No boxing/unboxing.
 * Primitive spawns: msBoxDouble stores double bits IN the void*, which are
 * bit-compatible with the typed field on little-endian (arm64/x86_64).
 * String/struct spawns: msSpawnInto memcpys from heap box into inline slot. */

static inline double msFutureReadDouble(void* fp) {
	msFutureBase* f = (msFutureBase*)fp;
	assert(atomic_load_explicit(&f->finished, memory_order_acquire) && "Future not yet finished");
	if (f->cancelled || f->failed) { msErr = true; msErrPayload = f->error; return 0.0; }
	return ((msFuture_double*)fp)->value;
}

static inline int32_t msFutureReadInt32(void* fp) {
	msFutureBase* f = (msFutureBase*)fp;
	assert(atomic_load_explicit(&f->finished, memory_order_acquire) && "Future not yet finished");
	if (f->cancelled || f->failed) { msErr = true; msErrPayload = f->error; return 0; }
	return ((msFuture_int32*)fp)->value;
}

static inline bool msFutureReadBool(void* fp) {
	msFutureBase* f = (msFutureBase*)fp;
	assert(atomic_load_explicit(&f->finished, memory_order_acquire) && "Future not yet finished");
	if (f->cancelled || f->failed) { msErr = true; msErrPayload = f->error; return false; }
	return ((msFuture_bool*)fp)->value;
}

/* msString needs forward declaration from string header — defined after msBoxString in native.h.
 * For now, use msFutureRead (void*) + cast for string reads. */

/* Legacy untyped read (for combinators, backward compat) */
static inline void* msFutureRead(void* fp) {
	msFuture* f = (msFuture*)fp;
	assert(atomic_load_explicit(&f->base.finished, memory_order_acquire) && "Future not yet finished");
	if (f->base.cancelled) { msErr = true; msErrPayload = NULL; return NULL; }
	if (f->base.failed) { msErr = true; msErrPayload = f->base.error; return NULL; }
	void* v = f->value;
	f->value = NULL;
	return v;
}

/* ===== DRC lifecycle ===== */

/* DRC scope cleanup: decref and destroy only if last reference.
 * Futures may escape via return values (msIncRef'd), so unconditional
 * destroy is wrong — must respect refcount. */
#define msFutureDrcDestroy(f) do { if ((f) != NULL && msDecRefIsLast(f)) { msFutureDestroyInner(f); } } while(0)
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
