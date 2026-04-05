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
#include <stdlib.h>
#include <string.h>
#include <assert.h>

msAwaitGroup* msAwaitGroupInit(int32_t n) {
	if (n < 0) n = 0;

	msAwaitGroup* g = (msAwaitGroup*)calloc(1, sizeof(msAwaitGroup));
	if (g == NULL) return NULL;

	g->size = n;
	atomic_store_explicit(&g->pending, n, memory_order_relaxed);
	atomic_store_explicit(&g->failed, false, memory_order_relaxed);
	g->error = NULL;

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

#ifdef _WIN32
	EnterCriticalSection(&g->cs);
	while (atomic_load_explicit(&g->pending, memory_order_acquire) > 0) {
		SleepConditionVariableCS(&g->cv, &g->cs, INFINITE);
	}
	LeaveCriticalSection(&g->cs);
#else
	pthread_mutex_lock(&g->mutex);
	while (atomic_load_explicit(&g->pending, memory_order_acquire) > 0) {
		pthread_cond_wait(&g->cv, &g->mutex);
	}
	pthread_mutex_unlock(&g->mutex);
#endif
}
