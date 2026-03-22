/*
 * MetaScript Async Dispatcher — Standard reference implementation parity
 *
 * Event loop, timer heap, ring buffer callback deque.
 * All future-typed APIs use void* or msFutureBase* for type-erased dispatch.
 */
#ifndef MS_DISPATCH_H
#define MS_DISPATCH_H

#include "future.h"
#include "std/runtime/selector.h"
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
	void* fut;             /* msFuture_void* to complete when timer expires */
} msTimer;

typedef struct msTimerHeap {
	msTimer* data;
	int len;
	int cap;
} msTimerHeap;

/* ===== Cross-Thread Completion (libuv self-pipe pattern) ===== */
/* Pool threads write completion messages to a pipe. Event loop reads + completes futures. */

typedef struct {
	void* fut;          /* msFuture_ptr* — spawn results use void* value */
	void* value;
	bool isFail;
	void* error;
} msCompletionMsg;

/* ===== Dispatcher (Standard reference pattern) ===== */

typedef struct msDispatcher {
	msTimerHeap timers;
	msCallbackDeque callbacks;
	msSelector* selector;    /* I/O event notification (kqueue/epoll/poll) */
	int completionPipe[2];   /* [0]=read (event loop), [1]=write (pool threads) */
} msDispatcher;

/* ===== API ===== */

msDispatcher* msGetDispatcher(void);
void msDestroyDispatcher(void);
bool msHasDispatcher(void);

int msProcessTimers(msDispatcher* d, bool* didWork);
void msProcessCallbacks(msDispatcher* d, bool* didWork);
int msAdjustTimeout(msDispatcher* d, int pollTimeout, int nextTimerMs);

bool msRunOnce(int timeoutMs);
void msPoll(int timeoutMs);
void* msWaitFor(void* fut);
void msRunForever(void);

/* Post completion from pool thread to event loop (libuv pattern) */
void msPostCompletion(void* fut, void* value, bool isFail, void* error);

/* Standard reference sleepAsync(ms) — returns msFuture_void* */
msFuture_void* msSleepAsync(int ms);

int64_t msMonoTimeMs(void);
void msSleepMs(int ms);

#endif /* MS_DISPATCH_H */
