#if !defined(MSOS_BARE) && !defined(MSOS_WASM) && !defined(MSOS_EMCC)
/*
 * MetaScript AwaitGroup implementation — see awaitGroup.h for design.
 *
 * The mutex guards:
 *   - `error` (first-failure winner write, waiter read)
 *   - The condvar itself (signaled under lock, waited under lock)
 *
 * The `pending` counter and `failed` flag are atomics, readable without the
 * mutex for fast-path queries. The waiter acquires the mutex only when it
 * needs to sleep; a fast-path check of `pending == 0` before locking avoids
 * the common case of all-already-done (e.g., zero-sized group).
 *
 * Completion ordering guarantee: a worker writes `results[i]` BEFORE the
 * atomic decrement of `pending`. A reader who observes pending == 0 through
 * acquire semantics is guaranteed to observe all prior writes to results[],
 * which satisfies the contract that msAwaitGroupBlocking's caller may
 * safely read results[] after the wait returns.
 */
#include "awaitGroup.h"
#include "pool.h"    /* Phase 8: msPoolHelpOne for help-first scheduling */
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <assert.h>

/* Phase 3: need monotonic time for deadline-based wait */
extern int64_t msMonoTimeMs(void);
/* Phase 4: route doneFut completion through MPSC queue to dispatcher thread.
 * Worker sets finished directly (for blocking waiters), then pushes to
 * the completion queue so callbacks fire on the dispatcher thread. */
extern void msCompletionQueuePush(void* fut, bool isFail, void* error);
extern void msCompletionQueuePushOwned(void* fut, bool isFail, void* error);
extern void msNotifyFutureComplete(void);
/* Minimal forward declaration: msFutureBase.finished is the first field (_Atomic(bool)).
 * We only need to set it from finishSlot without pulling in all of future.h.
 * Layout verified by _Static_assert in future.h (offsetof(msFutureBase, finished) == 0). */
typedef struct { _Atomic(bool) finished; } msFutureBaseMinimal;

msAwaitGroup* msAwaitGroupInit(int32_t n) {
	if (n < 0) n = 0;

	msAwaitGroup* g = (msAwaitGroup*)calloc(1, sizeof(msAwaitGroup));
	if (g == NULL) return NULL;

	g->size = n;
	atomic_store_explicit(&g->pending, n, memory_order_relaxed);
	atomic_store_explicit(&g->failed, false, memory_order_relaxed);
	atomic_store_explicit(&g->cancelled, false, memory_order_relaxed);
	atomic_store_explicit(&g->finishDone, (n == 0), memory_order_relaxed);
	g->error = NULL;
	g->deadlineMs = 0;
	g->timedOut = false;
	atomic_store_explicit(&g->doneFut, NULL, memory_order_relaxed);

	if (n > 0) {
		g->results = (void**)calloc((size_t)n, sizeof(void*));
		if (g->results == NULL) {
			free(g);
			return NULL;
		}
	} else {
		g->results = NULL;
	}

#ifdef _WIN32
	InitializeCriticalSection(&g->cs);
	InitializeConditionVariable(&g->cv);
#else
	pthread_mutex_init(&g->mutex, NULL);
	pthread_cond_init(&g->cv, NULL);
#endif

	return g;
}

void msAwaitGroupFree(msAwaitGroup* g) {
	if (g == NULL) return;

	/* Wait for the last worker to fully exit finishSlot.
	 * Without this, the caller (who saw pending==0 via help-first or
	 * fast-path) could free the group while a worker is still accessing
	 * g->doneFut or g->mutex inside finishSlot. Spin is fine — the
	 * window is nanoseconds (just the condvar signal + doneFut write). */
	while (!atomic_load_explicit(&g->finishDone, memory_order_acquire)) {
		/* yield to avoid burning CPU — sched_yield or just spin */
	}

#ifdef _WIN32
	DeleteCriticalSection(&g->cs);
#else
	pthread_mutex_destroy(&g->mutex);
	pthread_cond_destroy(&g->cv);
#endif

	if (g->results != NULL) {
		free(g->results);
	}
	free(g);
}

/* Internal: decrement pending and wake waiter if we were the last one.
 * Must be called AFTER the result slot has been written (release ordering
 * on the fetch_sub ensures the waiter's acquire sees our prior store).
 * The mutex acquisition in the signaling branch is necessary on POSIX to
 * avoid a missed-wakeup race: a waiter can be about to block right as we
 * decrement, and without the lock we might signal before it sleeps. */
static void finishSlot(msAwaitGroup* g) {
	int32_t prev = atomic_fetch_sub_explicit(&g->pending, 1, memory_order_acq_rel);
	if (prev <= 1) {
		/* We were the last — wake any waiter. */
#ifdef _WIN32
		EnterCriticalSection(&g->cs);
		WakeAllConditionVariable(&g->cv);
		LeaveCriticalSection(&g->cs);
#else
		pthread_mutex_lock(&g->mutex);
		pthread_cond_broadcast(&g->cv);
		pthread_mutex_unlock(&g->mutex);
#endif
		/* Phase 4: complete done future for async cooperative path.
		 * Set finished directly (blocking waiters), push to MPSC queue
		 * (dispatcher fires callbacks for async steppers). */
		void* df = atomic_load_explicit(&g->doneFut, memory_order_acquire);
		if (df != NULL) {
			atomic_store_explicit(&((msFutureBaseMinimal*)df)->finished, true, memory_order_release);
			msNotifyFutureComplete();
			msCompletionQueuePushOwned(df, false, NULL);
		}
		/* Signal that the last worker has fully exited finishSlot.
		 * msAwaitGroupFree must wait for this before freeing the group,
		 * because the caller may observe pending==0 (via help-first or
		 * fast-path) and call free while we're still in this function. */
		atomic_store_explicit(&g->finishDone, true, memory_order_release);
	}
}

void msAwaitGroupCompleteSlot(msAwaitGroup* g, int32_t slot, void* value) {
	if (g == NULL) return;
	if (slot < 0 || slot >= g->size) return;
	g->results[slot] = value;
	finishSlot(g);
}

void msAwaitGroupFailSlot(msAwaitGroup* g, int32_t slot, void* error) {
	if (g == NULL) return;
	if (slot < 0 || slot >= g->size) return;

	/* First failure wins. Use compare_exchange to atomically claim the
	 * "failed" state; the loser drops its error payload silently. */
	bool expected = false;
	if (atomic_compare_exchange_strong_explicit(
			&g->failed, &expected, true,
			memory_order_acq_rel, memory_order_relaxed)) {
#ifdef _WIN32
		EnterCriticalSection(&g->cs);
		g->error = error;
		LeaveCriticalSection(&g->cs);
#else
		pthread_mutex_lock(&g->mutex);
		g->error = error;
		pthread_mutex_unlock(&g->mutex);
#endif
	}

	/* Still decrement pending so waiters unblock even on failure. */
	g->results[slot] = NULL;
	finishSlot(g);
}

void msAwaitGroupBlocking(msAwaitGroup* g) {
	if (g == NULL) return;

	/* Fast path: everyone already done (including the n==0 case). */
	if (atomic_load_explicit(&g->pending, memory_order_acquire) == 0) {
		return;
	}

	/* Phase 8: Help-first scheduling — before parking on the condvar, try
	 * to dequeue and execute tasks from the global pool queue inline. This
	 * prevents deadlock when all pool workers are blocked in await groups
	 * while their child tasks sit in the global queue.
	 *
	 * Lock ordering: we never hold both group mutex and pool mutex at once.
	 * Drop group lock → msPoolHelpOne (acquires/releases pool lock internally)
	 * → re-acquire group lock. */
#ifdef _WIN32
	EnterCriticalSection(&g->cs);
	while (atomic_load_explicit(&g->pending, memory_order_acquire) > 0) {
		LeaveCriticalSection(&g->cs);
		if (msPoolHelpOne()) {
			EnterCriticalSection(&g->cs);
			continue;
		}
		EnterCriticalSection(&g->cs);
		if (atomic_load_explicit(&g->pending, memory_order_acquire) > 0) {
			SleepConditionVariableCS(&g->cv, &g->cs, INFINITE);
		}
	}
	LeaveCriticalSection(&g->cs);
#else
	pthread_mutex_lock(&g->mutex);
	while (atomic_load_explicit(&g->pending, memory_order_acquire) > 0) {
		pthread_mutex_unlock(&g->mutex);
		if (msPoolHelpOne()) {
			pthread_mutex_lock(&g->mutex);
			continue;
		}
		pthread_mutex_lock(&g->mutex);
		if (atomic_load_explicit(&g->pending, memory_order_acquire) > 0) {
			pthread_cond_wait(&g->cv, &g->mutex);
		}
	}
	pthread_mutex_unlock(&g->mutex);
#endif
}

void msAwaitGroupBlockingWithDeadline(msAwaitGroup* g, int64_t deadlineMs) {
	if (g == NULL) return;
	g->deadlineMs = deadlineMs;

	/* Fast path: already done. */
	if (atomic_load_explicit(&g->pending, memory_order_acquire) == 0) {
		return;
	}

	/* Phase 8: same help-first pattern as msAwaitGroupBlocking, with
	 * deadline check after each steal attempt. */
#ifdef _WIN32
	EnterCriticalSection(&g->cs);
	while (atomic_load_explicit(&g->pending, memory_order_acquire) > 0) {
		LeaveCriticalSection(&g->cs);
		if (msPoolHelpOne()) {
			EnterCriticalSection(&g->cs);
			continue;
		}
		EnterCriticalSection(&g->cs);
		if (atomic_load_explicit(&g->pending, memory_order_acquire) <= 0) break;
		int64_t now = msMonoTimeMs();
		if (now >= deadlineMs) {
			g->timedOut = true;
			atomic_store_explicit(&g->cancelled, true, memory_order_release);
			LeaveCriticalSection(&g->cs);
			return;
		}
		DWORD remainMs = (DWORD)(deadlineMs - now);
		SleepConditionVariableCS(&g->cv, &g->cs, remainMs);
	}
	LeaveCriticalSection(&g->cs);
#else
	pthread_mutex_lock(&g->mutex);
	while (atomic_load_explicit(&g->pending, memory_order_acquire) > 0) {
		pthread_mutex_unlock(&g->mutex);
		if (msPoolHelpOne()) {
			pthread_mutex_lock(&g->mutex);
			continue;
		}
		pthread_mutex_lock(&g->mutex);
		if (atomic_load_explicit(&g->pending, memory_order_acquire) <= 0) break;
		int64_t now = msMonoTimeMs();
		if (now >= deadlineMs) {
			g->timedOut = true;
			atomic_store_explicit(&g->cancelled, true, memory_order_release);
			pthread_mutex_unlock(&g->mutex);
			return;
		}
		/* Convert remaining time to absolute CLOCK_REALTIME timespec.
		 * POSIX pthread_cond_timedwait requires CLOCK_REALTIME.
		 * macOS lacks pthread_condattr_setclock for CLOCK_MONOTONIC.
		 * Clock-jump risk: NTP adjustments can cause early/late wake —
		 * mitigated by the while-loop recheck of deadline vs monotonic now. */
		struct timespec ts;
		clock_gettime(CLOCK_REALTIME, &ts);
		int64_t remainMs = deadlineMs - now;
		ts.tv_sec += remainMs / 1000;
		ts.tv_nsec += (remainMs % 1000) * 1000000;
		if (ts.tv_nsec >= 1000000000) {
			ts.tv_sec += 1;
			ts.tv_nsec -= 1000000000;
		}
		pthread_cond_timedwait(&g->cv, &g->mutex, &ts);
	}
	pthread_mutex_unlock(&g->mutex);
#endif
}

void msAwaitGroupCancel(msAwaitGroup* g) {
	if (g == NULL) return;
	atomic_store_explicit(&g->cancelled, true, memory_order_release);
}

/* ===== msAwaitSlot — Thread-Local Pool with Heap Fallback ===== */

#define MS_SLOT_POOL_SIZE 64
static _Thread_local msAwaitSlot msSlotPool[MS_SLOT_POOL_SIZE];
static _Thread_local int32_t msSlotPoolIdx = 0;

/* Amendment H: TLS definitions for deferred future release. MUST be defined
 * here (not static in the header) so all TUs share the same per-thread state —
 * a static _Thread_local in a header gives each TU its own copy, breaking
 * the cross-TU "test program msDecref → pool.c msFutureReleaseFlush at exit"
 * flow. Pony parity: msMsgPools uses the same extern-in-header + define-in-.c
 * pattern (mailbox.h:76, defined in actor.c). */
_Thread_local void* msFutureReleaseBuf[MS_FUTURE_RELEASE_CAP];
_Thread_local int msFutureReleaseCount = 0;

void* msAwaitSlotCreate(int32_t n) {
	msAwaitSlot* s;
	if (msSlotPoolIdx < MS_SLOT_POOL_SIZE) {
		s = &msSlotPool[msSlotPoolIdx++];
	} else {
		/* Heap fallback for deep recursion + work stealing (24 bytes) */
		s = (msAwaitSlot*)malloc(sizeof(msAwaitSlot));
	}
	atomic_store_explicit(&s->pending, n, memory_order_relaxed);
	atomic_store_explicit(&s->failed, false, memory_order_relaxed);
	s->error = NULL;
	s->result = NULL;
	return (void*)s;
}

void msAwaitSlotRelease(void* sp) {
	msAwaitSlot* s = (msAwaitSlot*)sp;
	/* Check if pointer is within the TLS pool or heap-allocated */
	if (s >= &msSlotPool[0] && s < &msSlotPool[MS_SLOT_POOL_SIZE]) {
		/* Pool slot — only reclaim if this is the top-of-stack (strict LIFO).
		 * Help-first work stealing causes non-LIFO release order: the outer
		 * frame releases slot 0 before slot 3 (sequential await order).
		 * A blind idx-- would drop below still-active slots, and the next
		 * create would alias an in-use slot — corrupting results.
		 * Fix: only reclaim the topmost. Lower slots stay allocated until
		 * the stack unwinds. Pool has 64 entries (1.5KB), heap fallback
		 * handles overflow from very deep recursion. */
		if (msSlotPoolIdx > 0 && s == &msSlotPool[msSlotPoolIdx - 1]) {
			msSlotPoolIdx--;
		}
	} else {
		/* Heap fallback — free */
		free(s);
	}
}

#endif /* !MSOS_BARE && !MSOS_WASM */
