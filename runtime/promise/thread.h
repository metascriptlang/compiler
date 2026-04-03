/*
 * MetaScript Thread Runtime — spawn() support
 *
 * Runs a closure on a worker pool thread, completes an msFuture when done.
 * Uses a Malebolgia-style fixed thread pool (N = CPU cores).
 *
 * Spawn uses msFuture_ptr (void* value) at the thread boundary.
 * The boxed value crosses the completion pipe and gets stored in the future.
 * Caller's await code reads the void* and casts/unboxes as needed.
 */
#ifndef MS_THREAD_H
#define MS_THREAD_H

#include "future.h"
#include <stdlib.h>

typedef struct msSpawnCtx {
	void* fn;           /* closure function pointer */
	void* env;          /* closure environment (NULL for non-capturing) */
	void* fut;          /* msFuture_ptr* to complete when task finishes */
} msSpawnCtx;


/* Forward declaration — implemented in dispatch.c */
extern void msPostCompletion(void* fut, void* value, bool isFail, void* error);

static inline void msSpawnWorkerRun(msSpawnCtx* ctx) {
	void* result = NULL;
	if (ctx->env != NULL) {
		result = ((void*(*)(void*))ctx->fn)(ctx->env);
	} else {
		result = ((void*(*)(void))ctx->fn)();
	}
	/* Post result to event loop thread via completion pipe */
	if (msErr) {
		msPostCompletion(ctx->fut, NULL, true, (void*)msCurrException);
		msErr = false;
		msCurrException = NULL;
	} else {
		msPostCompletion(ctx->fut, result, false, NULL);
	}
	/* Release worker's ownership of the env */
	if (ctx->env != NULL) {
		msDecref(ctx->env);
	}
	/* No free — ctx is a local copy from the queue slot (Malebolgia: zero alloc) */
}

/* Forward declaration — pool submit defined in pool.c */
void msPoolSubmit(msSpawnCtx* ctx);

/* Spawn a closure on a worker pool thread. Returns void* (msFuture_ptr internally).
 * Reference parity: spawn result compatible with any Future[T] pointer.
 * Takes ownership of the closure env by incrementing its refcount. */
static inline void* msSpawn(msClosure fn) {
	msFuture_ptr* fut = msFutureCreateT(msFuture_ptr);
	msSpawnCtx ctx = { .fn = (void*)fn.fn, .env = fn.env, .fut = fut };
	if (fn.env != NULL) {
		msIncRef(fn.env);
	}
	msPoolSubmit(&ctx);  /* copied into queue slot — ctx can go out of scope */
	return fut;
}

#endif /* MS_THREAD_H */
