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
	uint32_t inlineValueOffset; /* byte offset of the value field within the typed future struct.
	                               On 64-bit, always == sizeof(msFutureBase). On 32-bit WASM,
	                               may differ due to alignment padding (e.g., double needs 8-byte
	                               alignment but msFutureBase is 20 bytes → 4 bytes padding). */
	void* ownerQueue;           /* the submitting loop's completion queue: the env release runs there */
	bool claimed;               /* queue slot only, under the pool lock: a waiter took it to run */
	const struct msTaskFrame* parent;  /* queue slot only: the running task that joins this one, or NULL */
} msSpawnCtx;


/* Amendment G: worker-side push that does NOT incref — the owner thread already
 * took the queue's completion ref at submit time (msSpawn / msSpawnInto). */
extern void msCompletionQueuePushOwned(void* fut, bool isFail, void* error);
extern void msCompletionQueuePushEnvRelease(void* env, void* ownerQueue);

/* Publishes the task's result, or with msErr set its msCurrException, to its target. */
static inline void msSpawnWorkerSettle(msSpawnCtx* ctx, void* result) {
	if (ctx->slotGroup != NULL) {
		/* Stack-allocated fast path: atomic decrement, no condvar, no pipe. */
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
	} else {
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
			msCompletionQueuePushOwned(ctx->fut, true, (void*)msCurrException);
			msErr = false;
			msCurrException = NULL;
		} else if (ctx->inlineCopySize > 0 && result != NULL) {
			/* Typed-inline path: memcpy boxed struct/string bytes into fut's
			 * inline value slot, free the heap box shell.
			 * Use sizeof(msFutureBase) as the value offset — NOT msFuture_ptr.value,
			 * because on 32-bit WASM, void* is 4 bytes but structs with 8-byte
			 * alignment get padded to a different offset. sizeof(msFutureBase) is
			 * the first byte after the base, which is where MS_FUTURE_STRUCT puts
			 * the value field (possible alignment padding is part of the struct). */
			memcpy((char*)ctx->fut + ctx->inlineValueOffset, result, ctx->inlineCopySize);
			free(result);
			atomic_store_explicit(&((msFutureBase*)ctx->fut)->finished, true, memory_order_release);
			msNotifyFutureComplete();
			msCompletionQueuePushOwned(ctx->fut, false, NULL);
		} else {
			/* Primitive path: void* result contains value bits directly
			 * (msBoxDouble/Int32/Bool store in pointer bits, no heap alloc).
			 * Bit-compatible with typed inline field on little-endian. */
			((msFuture_ptr*)ctx->fut)->value = result;
			atomic_store_explicit(&((msFutureBase*)ctx->fut)->finished, true, memory_order_release);
			msNotifyFutureComplete();
			msCompletionQueuePushOwned(ctx->fut, false, NULL);
		}
	}

	/* Release worker's ownership of the env via deferred MPSC push.
	 * Skip for slotGroup path — fused await guarantees env alive through wait,
	 * and msSpawnSlotSubmit didn't incref (no extra ownership to release).
	 * Amendment H: push env to the completion queue (kind=-3) instead of
	 * inline msDecref. The dispatcher drain processes it single-threaded,
	 * avoiding cross-thread rc races on the env's non-atomic rc field. */
	if (ctx->slotGroup == NULL && ctx->env != NULL) {
#if MS_FUTURE_SUBMIT_REF
		msCompletionQueuePushEnvRelease(ctx->env, ctx->ownerQueue);
#elif defined(_WIN32)
		/* Amendment H parity: MS_FUTURE_SUBMIT_REF is 0 on Windows, but an
		 * inline worker-thread msDecref still races the owning thread on the
		 * env's non-atomic rc field (heap corruption 0xC0000374 after a few
		 * thousand spawns). Route through the IOCP completion (kind=-3) so
		 * the release runs on the dispatcher drain, exactly like POSIX. */
		msPostEnvRelease(ctx->env);
#else
		msDecref(ctx->env);
#endif
	}
	/* No free — ctx is a local copy from the queue slot (Malebolgia: zero alloc) */
}

static inline void msSpawnWorkerRun(msSpawnCtx* ctx) {
	void* result = NULL;
	bool cancelledBeforeStart = ctx->cancelFlag != NULL
		&& atomic_load_explicit(ctx->cancelFlag, memory_order_acquire);
	if (!cancelledBeforeStart) {
#if MS_ACTOR_JOBS
		msActor* actor = msActorCurrentForJobs();
		if (__builtin_expect(actor != NULL, 0)) msCurrentActor = NULL;
#endif
		result = ctx->env != NULL ? ((void*(*)(void*))ctx->fn)(ctx->env) : ((void*(*)(void))ctx->fn)();
#if MS_ACTOR_JOBS
		if (__builtin_expect(actor != NULL, 0)) msCurrentActor = actor;
#endif
	}
	msSpawnWorkerSettle(ctx, result);
}

/* Forward declaration — pool submit defined in pool.c */
void msPoolSubmit(msSpawnCtx* ctx);

/* Spawn a closure on a worker pool thread. Returns void* (msFuture_ptr internally).
 * Reference parity: spawn result compatible with any Future[T] pointer.
 * Takes ownership of the closure env by incrementing its refcount. */
static inline void* msSpawnCancellable(msClosure fn, _Atomic(bool)* cancelFlag) {
	msFuture_ptr* fut = msFutureCreateT(msFuture_ptr);
	fut->base.spawned = true;
	msSpawnCtx ctx = { .fn = (void*)fn.fn, .env = fn.env, .fut = fut, .cancelFlag = cancelFlag, .ownerQueue = msLoopCompletionQueue() };
	if (fn.env != NULL) {
		msIncRef(fn.env);
	}
#if MS_FUTURE_SUBMIT_REF
	/* Amendment G: queue's completion ref, taken on the owner thread before the
	 * worker can publish `finished` — paired with the dispatcher drain's
	 * msFutureDrcDestroy. Worker completes via msCompletionQueuePushOwned.
	 * Amendment H: mark the future crossThreadPublished so msFutureDeferredRelease
	 * defers its decref to serialize with the drain. */
	msIncRef(fut);
	msFuturePublishCrossThread(fut);
#endif
#ifdef _WIN32
	/* Channel-exists-before-visible, Windows twin of the submit-time
	 * discipline above: ensure the scheduler-0 loop's IOCP exists before the
	 * worker can complete, so its completion post routes to the loop instead of
	 * the I15-violating inline fallback. See msEnsureLoopChannel
	 * (dispatchFull.c). */
	{
		extern void msEnsureLoopChannel(void);
		msEnsureLoopChannel();
	}
#endif
	msPoolSubmit(&ctx);  /* copied into queue slot — ctx can go out of scope */
	return fut;
}


/* Typed-inline spawn: caller pre-allocates a typed future via msFutureCreateInline<T>.
 * Worker runs the closure (still returns boxed void*), then memcpys inlineCopySize
 * bytes from the box into the fut's inline value slot and frees the box.
 * Downstream readers use msWaitForStruct (typed inline read). */
static inline void* msSpawnIntoCancellable(void* fut, msClosure fn, uint32_t copySize, uint32_t valueOffset, _Atomic(bool)* cancelFlag) {
	msSpawnCtx ctx = {
		.fn = (void*)fn.fn, .env = fn.env, .fut = fut, .cancelFlag = cancelFlag, .ownerQueue = msLoopCompletionQueue(),
		.inlineCopySize = copySize, .inlineValueOffset = valueOffset,
	};
	((msFutureBase*)fut)->spawned = true;
	if (fn.env != NULL) msIncRef(fn.env);
#if MS_FUTURE_SUBMIT_REF
	msIncRef(fut);  /* Amendment G: owner-side queue completion ref (see msSpawn) */
	msFuturePublishCrossThread(fut);  /* Amendment H */
#endif
#ifdef _WIN32
	{
		extern void msEnsureLoopChannel(void);  /* see msSpawn */
		msEnsureLoopChannel();
	}
#endif
	msPoolSubmit(&ctx);
	return fut;
}

static inline void* msSpawn(msClosure fn) {
	return msSpawnCancellable(fn, NULL);
}

static inline void* msSpawnInto(void* fut, msClosure fn, uint32_t copySize, uint32_t valueOffset) {
	return msSpawnIntoCancellable(fut, fn, copySize, valueOffset, NULL);
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
		.cancelFlag = &group->cancelled,
		.ownerQueue = msLoopCompletionQueue(),
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
		.cancelFlag = &((msAwaitSlot*)s)->cancelled,
	};
	/* No msIncRef — fused path guarantees env alive through msAwaitSlotWait.
	 * Worker skips msDecref for slotGroup path (see msSpawnWorkerRun). */
	msPoolSubmit(&ctx);
}

/* msPoolRunEdge runs queued tasks on this thread and msSpawnWorkerRun reads msErr as
 * the task's own: keep the caller's in-flight exception out of the wait. */
static inline void msAwaitSlotSettle(void* sp) {
	bool err = msErr;
	msException* exc = msCurrException;
	msErr = false;
	msCurrException = NULL;
	msAwaitSlot* s = (msAwaitSlot*)sp;
	atomic_store_explicit(&s->cancelled, true, memory_order_release);
	msAwaitSlotWait(sp);
	if (atomic_load_explicit(&s->failed, memory_order_acquire)) msNoteOrphanError(s->error);
	msAwaitSlotRelease(sp);
	msErr = err;
	msCurrException = exc;
}

/* The futures of the spawns a routine keeps in a value (an array, a combinator
 * argument), each held by one reference until the routine exits. */
typedef struct msSpawnHeld {
	void** futs;
	int64_t len;
	int64_t cap;
	_Atomic(bool) cancelled;
} msSpawnHeld;

static inline void* msSpawnHeldCreate(void) {
	return msMemAlloc0(sizeof(msSpawnHeld));
}

static inline void msSpawnHeldKeep(void* hp, void* fut) {
	msSpawnHeld* h = (msSpawnHeld*)hp;
	if (h->len == h->cap) {
		int64_t live = 0;
		for (int64_t i = 0; i < h->len; i += 1) {
			void* f = h->futs[i];
			if (atomic_load_explicit(&((msFutureBase*)f)->finished, memory_order_acquire)) msDecref(f);
			else h->futs[live++] = f;
		}
		h->len = live;
		if (h->len == h->cap) {
			int64_t oldCap = h->cap;
			h->cap = oldCap > 0 ? oldCap * 2 : 4;
			h->futs = (void**)msRealloc(h->futs, (size_t)oldCap * sizeof(void*), (size_t)h->cap * sizeof(void*));
		}
	}
	msIncRef(fut);
	h->futs[h->len] = fut;
	h->len += 1;
}

/* The held spawns submit with the list's cancel flag, so the exit can skip the
 * tasks no worker has admitted yet. */
static inline void* msSpawnHeldSubmit(void* hp, msClosure fn) {
	void* fut = msSpawnCancellable(fn, &((msSpawnHeld*)hp)->cancelled);
	msSpawnHeldKeep(hp, fut);
#if MS_ACTOR_JOBS
	if (__builtin_expect(msActorCurrentForJobs() != NULL, 0)) msActorLendNote(fut);
#endif
	return fut;
}

static inline void* msSpawnIntoHeldSubmit(void* fut, msClosure fn, void* hp, uint32_t copySize, uint32_t valueOffset) {
	msSpawnIntoCancellable(fut, fn, copySize, valueOffset, &((msSpawnHeld*)hp)->cancelled);
	msSpawnHeldKeep(hp, fut);
#if MS_ACTOR_JOBS
	if (__builtin_expect(msActorCurrentForJobs() != NULL, 0)) msActorLendNote(fut);
#endif
	return fut;
}

/* Runs at every exit of the routine: cancel what is not admitted, then join
 * every held task, with the same in-flight exception discipline as
 * msAwaitSlotSettle. */
static inline void msSpawnHeldSettle(void* hp) {
	bool err = msErr;
	msException* exc = msCurrException;
	msErr = false;
	msCurrException = NULL;
	msSpawnHeld* h = (msSpawnHeld*)hp;
	atomic_store_explicit(&h->cancelled, true, memory_order_release);
	for (int64_t i = 0; i < h->len; i += 1) {
		msWaitForReady(h->futs[i]);
		msDecref(h->futs[i]);
	}
	free(h->futs);
	free(h);
	msErr = err;
	msCurrException = exc;
}

#endif /* MS_THREAD_H */
