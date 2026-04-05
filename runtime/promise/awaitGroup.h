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
	void* error;                  /* first error payload (protected by mutex) */
	void** results;               /* size-length array of void* result values */

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

#endif /* MS_AWAITGROUP_H */
