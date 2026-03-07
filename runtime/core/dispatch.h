/*
 * MetaScript Async Dispatcher — Standard reference implementation parity
 *
 * Event loop, timer heap, ring buffer callback deque.
 * Matches standard reference dispatcher pattern,
 * runOnce, poll, waitFor, runForever, sleepAsync.
 */
#ifndef MS_DISPATCH_H
#define MS_DISPATCH_H

#include "future.h"
#include "selector.h"
#include <stdint.h>
#include <stdbool.h>

/* ===== Callback Ring Buffer (Standard reference pattern) ===== */

typedef struct msCallbackDeque {
	msClosure* items;
	int head;
	int tail;
	int cap;
} msCallbackDeque;

/* ===== Timer Heap (Standard reference pattern) ===== */

typedef struct msTimer {
	int64_t finishAtMs;    /* monotonic milliseconds */
	msFuture* fut;         /* Future[void] to complete when timer expires */
} msTimer;

typedef struct msTimerHeap {
	msTimer* data;
	int len;
	int cap;
} msTimerHeap;

/* ===== Dispatcher (Standard reference pattern) ===== */

typedef struct msDispatcher {
	msTimerHeap timers;
	msCallbackDeque callbacks;
	msSelector* selector;    /* I/O event notification (kqueue/epoll/poll) */
} msDispatcher;

/* ===== API ===== */

/* Standard reference getGlobalDispatcher pattern — lazy init, thread-local */
msDispatcher* msGetDispatcher(void);

/* Destroy the global dispatcher — cancel timers, drain callbacks, free memory.
 * Matches standard reference closeDispatcher pattern. Resets msCallSoonProc to NULL. */
void msDestroyDispatcher(void);

/* Check if dispatcher exists (without creating one) */
bool msHasDispatcher(void);

/* Standard reference processTimers pattern — pop expired timers, complete futures.
 * Returns ms until next timer (+1 margin), or -1 if no timers. */
int msProcessTimers(msDispatcher* d, bool* didWork);

/* Standard reference processPendingCallbacks pattern — drain callback deque */
void msProcessCallbacks(msDispatcher* d, bool* didWork);

/* Standard reference adjustTimeout pattern */
int msAdjustTimeout(msDispatcher* d, int pollTimeout, int nextTimerMs);

/* Standard reference runOnce pattern — one event loop iteration */
bool msRunOnce(int timeoutMs);

/* Standard reference poll(timeout) pattern — alias for runOnce */
void msPoll(int timeoutMs);

/* Standard reference waitFor(fut) pattern — block until future completes */
void* msWaitFor(msFuture* fut);

/* Standard reference runForever() pattern — infinite poll loop */
void msRunForever(void);

/* Standard reference sleepAsync(ms) pattern — push timer, return future */
msFuture* msSleepAsync(int ms);

/* Platform monotonic time in milliseconds */
int64_t msMonoTimeMs(void);

/* Platform sleep in milliseconds */
void msSleepMs(int ms);

#endif /* MS_DISPATCH_H */
