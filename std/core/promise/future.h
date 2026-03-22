/*
 * MetaScript Future Runtime — Standard reference implementation parity
 *
 * Type-erased Future with callback chains and callSoon bridge.
 * Matches standard reference Future patterns, CallbackList, callSoon.
 */
#ifndef MS_FUTURE_H
#define MS_FUTURE_H

#include <stdbool.h>
#include <stdlib.h>
#include <assert.h>

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

/* ===== Future (Standard reference implementation parity, type-erased) ===== */

typedef struct msFuture {
	bool finished;
	bool failed;          /* set by msFutureFail (even when error payload is NULL) */
	bool cancelled;       /* set by msFutureCancel */
	void* value;          /* result payload (type-erased) */
	void* error;          /* error payload (may be NULL even when failed) */
	void (*valueDestructor)(void*); /* optional: frees value on destroy (set by Promise.all etc.) */
	msFutureCb* callbacks;
	msFutureCb* cbTail;   /* tail pointer for O(1) append */
} msFuture;

/* ===== Operations ===== */

/* Standard reference newFuture[T]() parity */
static inline msFuture* msFutureCreate(void) {
	msFuture* f = (msFuture*)calloc(1, sizeof(msFuture));
	return f;
}

/* Destroy future — free value (if destructor set), callback chain, and the future itself. */
static inline void msFutureDestroyInner(msFuture* f) {
	if (f == NULL) return;
	if (f->valueDestructor != NULL && f->value != NULL) {
		f->valueDestructor(f->value);
	}
	msFutureCb* cb = f->callbacks;
	while (cb) {
		msFutureCb* next = cb->next;
		free(cb);
		cb = next;
	}
	free(f);
}

/* Non-DRC destroy (direct call) */
static inline void msFutureDestroy(msFuture* f) { msFutureDestroyInner(f); }

/* Standard reference future.finished parity */
static inline bool msFutureFinished(msFuture* f) {
	return f->finished;
}

/* Fire all registered callbacks directly (shared by complete/fail).
 * Direct invocation instead of callSoon — works correctly across threads.
 * When spawn completes on a pool thread, callbacks fire on that thread.
 * This matches most C future libraries and avoids cross-thread dispatcher issues. */
static inline void msFutureFireCallbacks(msFuture* f) {
	msFutureCb* cb = f->callbacks;
	f->callbacks = NULL;
	f->cbTail = NULL;
	while (cb) {
		((void(*)(void*))cb->fn)(cb->env);
		msFutureCb* next = cb->next;
		free(cb);
		cb = next;
	}
}

/* Standard reference complete(fut, val) parity — sets value + fires callbacks.
 * Double-complete is a safe no-op (replaces assert for release safety). */
static inline void msFutureComplete(msFuture* f, void* val) {
	if (f->finished) return;
	f->value = val;
	f->finished = true;
	msFutureFireCallbacks(f);
}

/* Standard reference fail(fut, err) parity — sets error + fires callbacks.
 * Double-fail/complete is a safe no-op (replaces assert for release safety). */
static inline void msFutureFail(msFuture* f, void* err) {
	if (f->finished) return;
	f->error = err;
	f->failed = true;
	f->finished = true;
	msFutureFireCallbacks(f);
}

/* Cancel a pending future — clears callbacks without firing, marks finished+cancelled.
 * If already finished, this is a no-op. Matches standard reference pattern: clearCallbacks() + fail(). */
static inline void msFutureCancel(msFuture* f) {
	if (f->finished) return;
	/* Free callback chain without firing them */
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
static inline bool msFutureFailed(msFuture* f) {
	return f->failed;
}

/* Check if future was cancelled */
static inline bool msFutureCancelled(msFuture* f) {
	return f->cancelled;
}

/* Standard reference read(fut) parity — returns value or re-raises error via msErr flag.
 * Caller must check msErr after calling this (codegen does it via goto).
 * Error payload is stored in msErrPayload for inspection. */
extern MS_THREAD_LOCAL bool msErr; /* from native.c — thread-local for spawn safety */
extern MS_THREAD_LOCAL void* msErrPayload; /* from native.c */

static inline void* msFutureRead(msFuture* f) {
	assert(f->finished && "Future not yet finished");
	if (f->cancelled) {
		msErr = true;
		msErrPayload = NULL;
		return NULL;
	}
	if (f->failed) {
		msErr = true;
		msErrPayload = f->error; /* may be NULL — caller checks msErr, not payload */
		return NULL;
	}
	void* v = f->value;
	f->value = NULL;  /* prevent valueDestructor double-free after waitFor consumes the value */
	return v;
}

/* Add callback — if already finished, call directly; else append to list.
 * Direct invocation avoids cross-thread dispatcher routing issues. */
static inline void msFutureAddCallback(msFuture* f, msClosure cb) {
	if (f->finished) {
		/* Already finished — call directly (not through callSoon) */
		if (cb.env != NULL) {
			((void(*)(void*))cb.fn)(cb.env);
		} else {
			((void(*)(void))cb.fn)();
		}
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

/* DRC lifecycle (Ref kind — receives variable by value, like msDecref/msPtrWasMoved) */
#define msFutureDrcDestroy(f) do { if ((f) != NULL) { msFutureDestroyInner(f); } } while(0)
#define msFutureDrcWasMoved(f) do { (f) = NULL; } while(0)

/* Value boxing for type-erased futures: box non-pointer values to void* */
static inline void* msBoxDouble(double v) { double* p = (double*)malloc(sizeof(double)); *p = v; return p; }
static inline double msUnboxDouble(void* p) { double v = *(double*)p; free(p); return v; }
static inline void* msBoxInt32(int32_t v) { int32_t* p = (int32_t*)malloc(sizeof(int32_t)); *p = v; return p; }
static inline int32_t msUnboxInt32(void* p) { int32_t v = *(int32_t*)p; free(p); return v; }
static inline void* msBoxBool(bool v) { bool* p = (bool*)malloc(sizeof(bool)); *p = v; return p; }
static inline bool msUnboxBool(void* p) { bool v = *(bool*)p; free(p); return v; }

/* ===== Async Stepper Callback (Nim createCb pattern) ===== */
/* The stepper (state machine) returns the next msFuture* to wait on, or NULL when done.
 * msAsyncCb drives the stepper: calls it, checks the result, re-registers on yielded future.
 * This eliminates the self-referencing closure problem — the stepper never references itself.
 * Defined as declarations here; implemented in dispatch.c (where arc.h is available for refcounting). */

typedef struct {
	msClosure stepper;
} msAsyncCbEnv;

void msAsyncCb(void* raw);
void msAsyncStart(msFuture* retFut, msClosure stepper);

#endif /* MS_FUTURE_H */
