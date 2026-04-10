/*
 * MetaScript Thread Runtime — spawn() support
 *
 * Runs a closure on a worker pool thread. The worker publishes the closure's
 * result through one of two completion targets, chosen per-task:
 *
 *   1. Future path (msSpawn → msFuture_ptr):
 *      Default single-handle await. The boxed void* return value crosses the
 *      MPSC completion queue onto the dispatcher thread, where
 *      callbacks fire under the event loop. Caller's await code reads the
 *      void* and casts/unboxes as needed.
 *
 *   2. Group path (msSpawnTaskSubmit → msAwaitGroup):
 *      Structured fan-out (PARALOCK.md §6.3). The worker writes its slot in
 *      the caller-provided AwaitGroup and decrements the group's atomic
 *      counter directly — no completion pipe, no dispatcher round-trip, no
 *      per-task future allocation. The submitting thread blocks in
 *      msAwaitGroupBlocking until all slots report.
 *
 * Both paths share msPoolSubmit and the Malebolgia-style fixed worker pool
 * (N = CPU cores). The dispatch branch lives in msSpawnWorkerRun below.
 *
 * Both paths are exercised end-to-end by the transform pipeline:
 *   - awaitLower.ms: fused await(spawn(fn)) single-slot groups
 *   - spawnGroupLower.ms: await [spawn(f), spawn(g), ...] N-slot groups
 */
#ifndef MS_THREAD_H
#define MS_THREAD_H

#include "future.h"
#include "awaitGroup.h"
#include <stdlib.h>

/* Spawn context. Workers execute fn(env) then publish the result.
 *
 * Two completion targets are supported, selected by which field is non-NULL:
 *   - fut != NULL, group == NULL (default):
 *       future path — result goes through MPSC completion queue, serialized
 *       onto the dispatcher thread so callbacks fire under the event loop.
 *   - group != NULL (fut may be NULL):
 *       group path — worker calls msAwaitGroupCompleteSlot / FailSlot
 *       directly from the worker thread. No dispatcher round-trip.
 *       Used by structured fan-out (PARALOCK Phase 2).
 *
 * Existing callers that designated-initialize with only {fn, env, fut} still
 * work: C guarantees group/slot are zero-initialized, so the worker takes
 * the future branch. */
typedef struct msSpawnCtx {
	void* fn;             /* closure function pointer */
	void* env;            /* closure environment (NULL for non-capturing) */
	void* fut;            /* msFuture_ptr* to complete (future path) */
	msAwaitGroup* group;  /* optional: group to complete (group path) */
	int32_t slot;         /* group slot index (only meaningful when group != NULL) */
	_Atomic(bool)* cancelFlag;  /* Phase 3: pointer to group's cancelled flag (NULL if no group) */
	void* slotGroup;            /* msAwaitSlot* — stack-allocated fast path (Malebolgia parity) */
	uint32_t inlineCopySize;    /* >0: closure returns boxed struct/string; worker memcpys
	                               N bytes from *result into fut's inline value slot, frees
	                               box. Requires typed-sized fut allocation. */
} msSpawnCtx;


/* Forward declarations — implemented in dispatch.c */
extern void msCompletionQueuePush(void* fut, bool isFail, void* error);

static inline void msSpawnWorkerRun(msSpawnCtx* ctx) {
	void* result = NULL;
	if (ctx->env != NULL) {
		result = ((void*(*)(void*))ctx->fn)(ctx->env);
	} else {
		result = ((void*(*)(void))ctx->fn)();
	}

	if (ctx->slotGroup != NULL) {
		/* Stack-allocated fast path: atomic decrement, no condvar, no pipe.
		 * Waiter spins via msPoolHelpOne + sched_yield (Malebolgia parity). */
		if (msErr) {
			msAwaitSlotFail(ctx->slotGroup, (void*)msCurrException);
			msErr = false;
			msCurrException = NULL;
		} else {
			msAwaitSlotComplete(ctx->slotGroup, ctx->slot, result);
		}
	} else if (ctx->group != NULL) {
		/* Group path: worker completes the slot directly. AwaitGroup's own
		 * mutex + acq_rel fetch_sub handles cross-thread publication; no
		 * need to route through the dispatcher. */
		if (msErr) {
			msAwaitGroupFailSlot(ctx->group, ctx->slot, (void*)msCurrException);
			msErr = false;
			msCurrException = NULL;
		} else {
			msAwaitGroupCompleteSlot(ctx->group, ctx->slot, result);
		}
	} else if (ctx->fut != NULL) {
		/* Future path: split completion (Pony MPSC parity).
		 * Step 1: Store value + mark finished directly from worker thread.
		 *         Blocking waiters (msWaitForReady) see finished immediately.
		 * Step 2: Push to MPSC queue for callback firing on dispatcher thread.
		 *         Async steppers (msAsyncCb) get callbacks on the correct thread. */
		if (msErr) {
			((msFutureBase*)ctx->fut)->error = (void*)msCurrException;
			((msFutureBase*)ctx->fut)->failed = true;
			atomic_store_explicit(&((msFutureBase*)ctx->fut)->finished, true, memory_order_release);
			msNotifyFutureComplete();
			msCompletionQueuePush(ctx->fut, true, (void*)msCurrException);
			msErr = false;
			msCurrException = NULL;
		} else if (ctx->inlineCopySize > 0 && result != NULL) {
			/* Typed-inline path: memcpy boxed struct/string bytes into fut's
			 * inline value slot, free the heap box shell. */
			memcpy(&((msFuture_ptr*)ctx->fut)->value, result, ctx->inlineCopySize);
			free(result);
			atomic_store_explicit(&((msFutureBase*)ctx->fut)->finished, true, memory_order_release);
			msNotifyFutureComplete();
			msCompletionQueuePush(ctx->fut, false, NULL);
		} else {
			/* Primitive path: void* result contains value bits directly
			 * (msBoxDouble/Int32/Bool store in pointer bits, no heap alloc).
			 * Bit-compatible with typed inline field on little-endian. */
			((msFuture_ptr*)ctx->fut)->value = result;
			atomic_store_explicit(&((msFutureBase*)ctx->fut)->finished, true, memory_order_release);
			msNotifyFutureComplete();
			msCompletionQueuePush(ctx->fut, false, NULL);
		}
	} else {
		/* Defensive: no completion target — clear errors to prevent stale state. */
		if (msErr) { msErr = false; msCurrException = NULL; }
	}

	/* Release worker's ownership of the env.
	 * Skip for slotGroup path — fused await guarantees env alive through wait,
	 * and msSpawnSlotSubmit didn't incref (no extra ownership to release). */
	if (ctx->slotGroup == NULL && ctx->env != NULL) {
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


/* Typed-inline spawn: caller pre-allocates a typed future via msFutureCreateInline<T>.
 * Worker runs the closure (still returns boxed void*), then memcpys inlineCopySize
 * bytes from the box into the fut's inline value slot and frees the box.
 * Downstream readers use msWaitForStruct (typed inline read). */
static inline void* msSpawnInto(void* fut, msClosure fn, uint32_t copySize) {
	msSpawnCtx ctx = {
		.fn = (void*)fn.fn, .env = fn.env, .fut = fut, .inlineCopySize = copySize,
	};
	if (fn.env != NULL) msIncRef(fn.env);
	msPoolSubmit(&ctx);
	return fut;
}

/* Submit a spawn task whose completion targets a group slot instead of a future.
 *
 * Used by PARALOCK structured fan-out (PARALOCK.md §6.3): the caller creates
 * an msAwaitGroup of size N via msAwaitGroupInit, submits N closures via
 * msSpawnTaskSubmit (slots 0..N-1), then calls msAwaitGroupBlocking and
 * finally msAwaitGroupFree. No future is allocated per task — the group's
 * results[] array holds the values, and cross-thread publication is handled
 * by the AwaitGroup's acq_rel counter + mutex protocol (see awaitGroup.c).
 *
 * Argument order matches PARALOCK.md §6.3 lifecycle example: (group, slot, fn).
 *
 * Caller owns the group and must keep it alive until all submitted slots
 * have completed (msAwaitGroupBlocking guarantees this). */
static inline void msSpawnTaskSubmit(msAwaitGroup* group, int32_t slot, msClosure fn) {
	msSpawnCtx ctx = {
		.fn = (void*)fn.fn,
		.env = fn.env,
		.fut = NULL,
		.group = group,
		.slot = slot,
		.cancelFlag = group ? &group->cancelled : NULL,
	};
	if (fn.env != NULL) {
		msIncRef(fn.env);
	}
	msPoolSubmit(&ctx);
}

/* Stack-allocated fast path: submit a spawn task targeting an msAwaitSlot.
 * Zero heap allocation — slot lives on caller's stack, waiter blocks via
 * msAwaitSlotWait (spin + help-first). Malebolgia parity. */
static inline void msSpawnSlotSubmit(void* s, int32_t slot, msClosure fn) {
	msSpawnCtx ctx = {
		.fn = (void*)fn.fn,
		.env = fn.env,
		.slotGroup = s,
		.slot = slot,
	};
	/* No msIncRef — fused path guarantees env alive through msAwaitSlotWait.
	 * Worker skips msDecref for slotGroup path (see msSpawnWorkerRun). */
	msPoolSubmit(&ctx);
}

#endif /* MS_THREAD_H */
