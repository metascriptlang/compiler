/*
 * MetaScript Thread Runtime — spawn() support
 *
 * Runs a closure on a worker pool thread, completes an msFuture when done.
 * Uses a Malebolgia-style fixed thread pool (N = CPU cores).
 *
 * Memory ownership (reference parity with spawn scratch-object pattern):
 * - msSpawn takes ownership of the closure env via msIncRef
 * - The worker thread holds its own reference to the env
 * - When the task finishes, msDecref releases the worker's reference
 * - The caller's DRC may also decref the env (via msClosureDestroy)
 * - The env is freed when the last reference drops to zero
 */
#ifndef MS_THREAD_H
#define MS_THREAD_H

#include "future.h"
#include <stdlib.h>

typedef struct msSpawnCtx {
	void* fn;           /* closure function pointer */
	void* env;          /* closure environment (NULL for non-capturing) */
	msFuture* fut;      /* future to complete when task finishes */
} msSpawnCtx;

/* Task runner — calls closure, completes or fails future, cleans up.
 * Used by pool workers. Extracted so pool.c can call it. */
static inline void msSpawnWorkerRun(msSpawnCtx* ctx) {
	void* result = NULL;
	if (ctx->env != NULL) {
		result = ((void*(*)(void*))ctx->fn)(ctx->env);
	} else {
		result = ((void*(*)(void))ctx->fn)();
	}
	/* Check for exception — propagate to future instead of silent loss */
	if (msErr) {
		msFutureFail(ctx->fut, (void*)msCurrException);
		msErr = false;
		msCurrException = NULL;
	} else {
		msFutureComplete(ctx->fut, result);
	}
	/* Release worker's ownership of the env (ref acquired in msSpawn) */
	if (ctx->env != NULL) {
		msDecref(ctx->env);
	}
	free(ctx);
}

/* Forward declaration — pool submit defined in pool.c */
void msPoolSubmit(msSpawnCtx* ctx);

/* Spawn a closure on a worker pool thread. Returns future that completes when done.
 *
 * Takes ownership of the closure env by incrementing its refcount.
 * The worker holds its own reference — safe even if caller's scope exits first. */
static inline msFuture* msSpawn(msClosure fn) {
	msFuture* fut = msFutureCreate();
	msSpawnCtx* ctx = (msSpawnCtx*)malloc(sizeof(msSpawnCtx));
	ctx->fn = (void*)fn.fn;
	ctx->env = fn.env;
	ctx->fut = fut;
	/* Take worker's ownership of env — prevents caller DRC from freeing it prematurely */
	if (fn.env != NULL) {
		msIncRef(fn.env);
	}
	msPoolSubmit(ctx);
	return fut;
}

#endif /* MS_THREAD_H */
