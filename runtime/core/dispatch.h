/*
 * MetaScript Async Dispatcher — Nim asyncdispatch.nim parity
 *
 * Event loop, timer heap, ring buffer callback deque.
 * Matches Nim's PDispatcherBase, processTimers, processPendingCallbacks,
 * runOnce, poll, waitFor, runForever, sleepAsync.
 */
#ifndef MS_DISPATCH_H
#define MS_DISPATCH_H

#include "future.h"
#include "selector.h"
#include <stdint.h>
#include <stdbool.h>

/* ===== Callback Ring Buffer (Nim's Deque[proc()]) ===== */

typedef struct msCallbackDeque {
	msClosure* items;
	int head;
	int tail;
	int cap;
} msCallbackDeque;

/* ===== Timer Heap (Nim's HeapQueue[tuple[finishAt, fut]]) ===== */

typedef struct msTimer {
	int64_t finishAtMs;    /* monotonic milliseconds */
	msFuture* fut;         /* Future[void] to complete when timer expires */
} msTimer;

typedef struct msTimerHeap {
	msTimer* data;
	int len;
	int cap;
} msTimerHeap;

/* ===== Dispatcher (Nim's PDispatcher) ===== */

typedef struct msDispatcher {
	msTimerHeap timers;
	msCallbackDeque callbacks;
	msSelector* selector;    /* I/O event notification (kqueue/epoll/poll) */
} msDispatcher;

/* ===== API ===== */

/* Nim's getGlobalDispatcher — lazy init, thread-local */
msDispatcher* msGetDispatcher(void);

/* Destroy the global dispatcher — cancel timers, drain callbacks, free memory.
 * Matches Nim's closeDispatcher(). Resets msCallSoonProc to NULL. */
void msDestroyDispatcher(void);

/* Check if dispatcher exists (without creating one) */
bool msHasDispatcher(void);

/* Nim's processTimers — pop expired timers, complete futures.
 * Returns ms until next timer (+1 margin), or -1 if no timers. */
int msProcessTimers(msDispatcher* d, bool* didWork);

/* Nim's processPendingCallbacks — drain callback deque */
void msProcessCallbacks(msDispatcher* d, bool* didWork);

/* Nim's adjustTimeout */
int msAdjustTimeout(msDispatcher* d, int pollTimeout, int nextTimerMs);

/* Nim's runOnce — one event loop iteration */
bool msRunOnce(int timeoutMs);

/* Nim's poll(timeout) — alias for runOnce */
void msPoll(int timeoutMs);

/* Nim's waitFor(fut) — block until future completes */
void* msWaitFor(msFuture* fut);

/* Nim's runForever() — infinite poll loop */
void msRunForever(void);

/* Nim's sleepAsync(ms) — push timer, return future */
msFuture* msSleepAsync(int ms);

/* Platform monotonic time in milliseconds */
int64_t msMonoTimeMs(void);

/* Platform sleep in milliseconds */
void msSleepMs(int ms);

#endif /* MS_DISPATCH_H */
