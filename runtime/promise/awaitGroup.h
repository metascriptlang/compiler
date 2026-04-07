/*
 * MetaScript AwaitGroup — structured fan-out primitive (PARALOCK Phase 2)
 *
 * A single synchronization point for N concurrent tasks. Callers submit N
 * tasks, then wait on the group as a unit. Used by the spawnLower transform
 * to lower structured parallel patterns like:
 *
 *     const (a, b, c) = await (spawn(f), spawn(g), spawn(h));
 *     const rs = await xs.map(x => spawn(() => work(x)));
 *
 * Replaces the current per-handle msFuture + msFutureAddCallback path for
 * aggregate awaits, cutting N separate callback registrations down to one
 * atomic counter + one wake.
 *
 * Threading model:
 *   - The owning thread calls msAwaitGroupInit, dispatches N tasks into the
 *     thread pool (each carrying its own slot index), then calls
 *     msAwaitGroupBlocking. It is the only reader of results[] once the
 *     wait returns.
 *   - Worker threads call msAwaitGroupCompleteSlot / msAwaitGroupFailSlot
 *     when their task finishes. The last one to decrement the pending
 *     counter signals the waiter.
 *   - results[i] is written by the worker running slot i BEFORE the atomic
 *     fetch_sub on pending (acq_rel). A reader that observes pending == 0
 *     via an acquire load is guaranteed to see all prior slot writes.
 *     g->error writes in FailSlot are protected by the mutex and ordered
 *     behind the same fetch_sub, so the waiter sees them post-wait.
 *
 * What this primitive does NOT do (intentionally, scoped to Stage 1):
 *   - Cancellation: no cancel flag yet, no timeout. Phase 3.
 *   - Async callback wait: no msAwaitGroupWaitAsync yet. Phase 4.
 *   - Help-first scheduling: the waiter just blocks, doesn't steal work
 *     from the pool queue. Nested spawn+await on tiny pools can deadlock.
 *     Phase 8.
 *   - DRC integration. The group is allocated with plain malloc/free and
 *     is NOT refcounted. Stage 1 is a standalone primitive with transform-
 *     owned lifecycle (create → complete × N → wait → destroy, all inside
 *     one generated scope), so ref sharing does not apply. Stage 2 will
 *     revisit this when wiring into msSpawnCtx / the compiler pipeline.
 */
#ifndef MS_AWAITGROUP_H
#define MS_AWAITGROUP_H

#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

/* ===== Types ===== */

typedef struct msAwaitGroup {
	int32_t size;                 /* total slot count, immutable after create */
	_Atomic(int32_t) pending;     /* starts at size, decremented per completion */
	_Atomic(bool) failed;         /* set by first failing slot */
	_Atomic(bool) cancelled;      /* Phase 3: set by timeout or explicit cancel */
	_Atomic(bool) finishDone;     /* set after the last worker exits finishSlot — msAwaitGroupFree must wait for this */
	void* error;                  /* first error payload (protected by mutex) */
	void** results;               /* size-length array of void* result values */
	int64_t deadlineMs;           /* Phase 3: absolute monotonic deadline (0 = none) */
	bool timedOut;                /* Phase 3: set when blocking returns due to timeout */
	_Atomic(void*) doneFut;       /* Phase 4: msFuture_void* completed when all slots done (NULL = blocking path) */

#ifdef _WIN32
	CRITICAL_SECTION cs;
	CONDITION_VARIABLE cv;
#else
	pthread_mutex_t mutex;
	pthread_cond_t cv;
#endif
} msAwaitGroup;

/* ===== Lifecycle ===== */

/* Allocate a group for `n` tasks. Caller owns the group and is responsible
 * for calling msAwaitGroupFree once all slots have completed AND the
 * results have been read (or the group has been waited on).
 *
 * n must be >= 0. n == 0 produces a pre-completed group (pending=0 at init). */
msAwaitGroup* msAwaitGroupInit(int32_t n);

/* Release the group's resources. Safe to call only after all slots have
 * completed — calling during an outstanding submission is UB. The transform
 * pass emits this call after msAwaitGroupBlocking returns. */
void msAwaitGroupFree(msAwaitGroup* g);

/* ===== Completion (called by workers) ===== */

/* Record a successful completion for slot `i`. The value is stored in
 * results[i] and the pending counter is decremented. If this is the last
 * outstanding slot, the waiter is signaled.
 *
 * Safe to call from worker threads. Thread-safe with respect to other slots
 * (different i) via the atomic counter; thread-safe with respect to the
 * waiter via the mutex/condvar protocol.
 *
 * Requirement: 0 <= i < g->size, and this slot has not already been completed. */
void msAwaitGroupCompleteSlot(msAwaitGroup* g, int32_t slot, void* value);

/* Record a failed completion for slot `i`. If this is the first failure, the
 * error is captured in g->error and g->failed is set. Subsequent failures
 * are dropped (first-reported-wins policy, matches Promise.all semantics).
 * Pending counter is still decremented so waiters unblock. */
void msAwaitGroupFailSlot(msAwaitGroup* g, int32_t slot, void* error);

/* ===== Wait (called by owner / waiter) ===== */

/* Block the calling thread until all N slots have completed (successfully
 * or with failure). Returns immediately if all slots were already complete.
 *
 * After this call returns:
 *   - All results[] entries are safe to read
 *   - g->failed indicates if any slot failed
 *   - g->error holds the first error encountered (or NULL if all succeeded)
 *
 * SYNC CONTEXT ONLY. This is the Phase 2 variant. Phase 4 will add an async
 * variant that registers a callback instead of blocking.
 *
 * Deadlock caveat: if the calling thread is itself a pool worker and all
 * pool workers end up blocked in msAwaitGroupBlocking on groups whose
 * tasks are queued behind them, the pool deadlocks. Phase 8 adds help-first
 * scheduling (waiting workers steal tasks from the queue) to prevent this. */
void msAwaitGroupBlocking(msAwaitGroup* g);

/* Block until all slots done OR deadline expires (Phase 3).
 * deadlineMs is an absolute monotonic timestamp (from msMonoTimeMs + offset).
 * Sets g->timedOut = true and g->cancelled = true if deadline expires before
 * all slots complete. Workers check cancelled at safe points to early-return. */
void msAwaitGroupBlockingWithDeadline(msAwaitGroup* g, int64_t deadlineMs);

/* Cancel all pending tasks. Sets the cancelled flag so workers can check at
 * safe points and early-return. Does NOT block or wait for workers to stop. */
void msAwaitGroupCancel(msAwaitGroup* g);

/* ===== Queries (non-blocking, for advanced use) ===== */

/* Returns true if all slots have completed (successfully or failed). */
static inline bool msAwaitGroupFinished(msAwaitGroup* g) {
	return g != NULL && atomic_load_explicit(&g->pending, memory_order_acquire) == 0;
}

/* Returns true if any slot reported a failure. Only meaningful after
 * msAwaitGroupFinished returns true (or msAwaitGroupBlocking returns). */
static inline bool msAwaitGroupFailed(msAwaitGroup* g) {
	return g != NULL && atomic_load_explicit(&g->failed, memory_order_acquire);
}

/* Read the result for slot `i`. Only valid after the group has finished.
 * Returns NULL for failed slots. */
static inline void* msAwaitGroupResult(msAwaitGroup* g, int32_t slot) {
	if (g == NULL || slot < 0 || slot >= g->size) return NULL;
	return g->results[slot];
}

/* Read the first error encountered. Returns NULL if no slot failed. */
static inline void* msAwaitGroupError(msAwaitGroup* g) {
	return g != NULL ? g->error : NULL;
}

/* Phase 3: Did the timed wait expire before all slots completed? */
static inline bool msAwaitGroupTimedOut(msAwaitGroup* g) {
	return g != NULL && g->timedOut;
}

/* Phase 4b: set the done future for async cooperative group await.
 * Called by transform-generated code before submitting tasks. */
static inline void msAwaitGroupSetDoneFut(msAwaitGroup* g, void* fut) {
	if (g != NULL) atomic_store_explicit(&g->doneFut, fut, memory_order_release);
}

/* Phase 3: Fast-path cancellation check for spawn safe points.
 * Called at loop backedges inside spawn closures. Single branch on
 * relaxed atomic load — ~1ns overhead per check. */
static inline bool msSpawnCheckCancel(msAwaitGroup* g) {
	return g != NULL && atomic_load_explicit(&g->cancelled, memory_order_relaxed);
}

/* ===== msAwaitSlot — Stack-Allocated Fast Path (Malebolgia parity) ===== */

/* Minimal completion target for fused await-spawn. Stack-allocated (24 bytes),
 * no mutex, no condvar. Waiter spins via help-first (msPoolHelpOne).
 * Replaces heap-allocated msAwaitGroup for the common `await spawn(fn)` pattern. */

extern bool msPoolHelpOne(void);  /* pool.h — avoid circular include */
extern void msPoolBusyDec(void);
extern void msPoolBusyInc(void);

typedef struct msAwaitSlot {
    _Atomic(int32_t) pending;     /* starts at N, decremented per completion */
    _Atomic(bool) failed;
    void* error;
    void* result;                 /* single-slot result (void*, boxed) */
} msAwaitSlot;

/* Thread-local slot pool — avoids heap alloc while keeping void* API.
 * Each thread gets MS_SLOT_POOL_SIZE slots. Slots are reused LIFO.
 * Safe because fused await-spawn has strict scope: create → submit → wait → done.
 * Defined in awaitGroup.c to avoid per-TU TLS duplication. */
void* msAwaitSlotCreate(int32_t n);
void msAwaitSlotRelease(void* sp);

static inline void msAwaitSlotComplete(void* sp, int32_t idx, void* value) {
    msAwaitSlot* s = (msAwaitSlot*)sp;
    if (idx == 0) s->result = value;
    atomic_fetch_sub_explicit(&s->pending, 1, memory_order_acq_rel);
}

static inline void msAwaitSlotFail(void* sp, void* error) {
    msAwaitSlot* s = (msAwaitSlot*)sp;
    atomic_store_explicit(&s->failed, true, memory_order_release);
    s->error = error;
    atomic_fetch_sub_explicit(&s->pending, 1, memory_order_acq_rel);
}

/* msIsPoolWorker declared in pool.c — true only for pool worker threads */
extern _Thread_local bool msIsPoolWorker;

static inline void msAwaitSlotWait(void* sp) {
    msAwaitSlot* s = (msAwaitSlot*)sp;
    bool isWorker = msIsPoolWorker;
    if (isWorker) msPoolBusyDec();  /* signal: I'm available to help while waiting */
    while (atomic_load_explicit(&s->pending, memory_order_acquire) > 0) {
        if (msPoolHelpOne()) continue;
        sched_yield();
    }
    if (isWorker) msPoolBusyInc();  /* back to own work */
}

static inline void* msAwaitSlotResult(void* sp) {
    return ((msAwaitSlot*)sp)->result;
}

#endif /* MS_AWAITGROUP_H */
