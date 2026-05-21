/*
 * MetaScript Async Dispatcher — Standard reference implementation parity
 *
 * Event loop, timer heap, ring buffer callback deque.
 * All future-typed APIs use void* or msFutureBase* for type-erased dispatch.
 */
#ifndef MS_DISPATCH_H
#define MS_DISPATCH_H

#include "future.h"
#include <stdint.h>
#include <stdbool.h>
#if !defined(MSOS_EMCC) && !defined(MSOS_WASM) && !defined(MSOS_BARE)
  #ifndef _WIN32
  #include "runtime/actor/selector.h"
  #endif
  #ifdef _WIN32
  #include <winsock2.h>
  #include <windows.h>
  #endif
#endif

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

/* ===== Cross-Thread Completion ===== */
#if !defined(MSOS_EMCC) && !defined(MSOS_WASM) && !defined(MSOS_BARE)
typedef struct {
	void* fut;          /* msFuture_ptr* — spawn results use void* value */
	void* value;
	bool isFail;
	void* error;
} msCompletionMsg;
#endif

/* ===== Dispatcher ===== */

typedef struct msDispatcher {
	msTimerHeap timers;
	msCallbackDeque callbacks;
#if !defined(MSOS_EMCC) && !defined(MSOS_WASM) && !defined(MSOS_BARE)
  #ifdef _WIN32
	HANDLE iocp;             /* I/O Completion Port for cross-thread signaling */
  #else
	msSelector* selector;    /* I/O event notification (kqueue/epoll/poll) */
	int completionPipe[2];   /* [0]=read (event loop), [1]=write (pool threads) */
  #endif
#endif
} msDispatcher;

/* ===== API ===== */

msDispatcher* msGetDispatcher(void);
void msDestroyDispatcher(void);
bool msHasDispatcher(void);

/* Returns the dispatcher's selector fd (kqueue/epoll), or -1 if not
 * available. Used by std/http to chain-poll the dispatcher's wake pipe
 * with its own HTTP selector. */
int msGetDispatcherSelectorFd(void);

int msProcessTimers(msDispatcher* d, bool* didWork);
void msProcessCallbacks(msDispatcher* d, bool* didWork);
int msAdjustTimeout(msDispatcher* d, int pollTimeout, int nextTimerMs);

bool msRunOnce(int timeoutMs);
int32_t msGetWakePipeFd(void);
void msPoll(int timeoutMs);
void* msWaitFor(void* fut);
void msWaitForReady(void* fut);
void msRunForever(void);

/* Post completion from pool thread to event loop (libuv pattern) */
void msPostCompletion(void* fut, void* value, bool isFail, void* error);

/* Standard reference sleepAsync(ms) — returns msFuture_void* */
msFuture_void* msSleepAsync(int ms);

int64_t msMonoTimeMs(void);
void msSleepMs(int ms);

/* Global future completion notification — wakes worker threads blocking on futures.
 * Called by msFutureFireCallbacks after setting finished=true. */
void msNotifyFutureComplete(void);

/* Worker-side future wait — blocks on global condvar until any future completes.
 * Used by dual-path msWaitForReady on worker threads (no event loop). */
void msWorkerWaitOnFuture(void* fut);

#endif /* MS_DISPATCH_H */
