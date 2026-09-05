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
	void* fut;             /* msFuture_void* to complete; NULL for callback timers */
	msClosure cb;          /* setTimeout/setInterval callback (fut == NULL) */
	int64_t id;            /* handle returned to the caller; 0 for sleep timers */
	int64_t periodMs;      /* > 0 → interval: re-armed after each fire */
	bool cancelled;        /* clearTimeout/clearInterval marks, the loop skips */
} msTimer;

typedef struct msTimerHeap {
	msTimer* data;
	int len;
	int cap;
} msTimerHeap;

/* ===== Cross-Thread Completion ===== */
#if !defined(MSOS_EMCC) && !defined(MSOS_WASM) && !defined(MSOS_BARE)
typedef struct {
	void* fut;          /* msFuture_ptr* - spawn results use void* value */
	void* value;
	bool isFail;
	void* error;
	int32_t kind;       /* 0 = future completion; -3 = deferred env release (value = env) */
} msCompletionMsg;
#endif

/* ===== Dispatcher ===== */

typedef struct msDispatcher {
#if defined(MSOS_EMCC) || defined(MSOS_WASM) || defined(MSOS_BARE)
	/* Single-threaded targets own their timers per dispatcher — there is one
	 * dispatcher and one thread, so "who services this heap" cannot be asked.
	 * The threaded dispatcher (dispatchFull.c) keeps timers on ONE process-
	 * global heap instead, because the thread that ARMS a timer (a pool worker
	 * running a spawn task) is not the thread that can service it. Exact
	 * complement of the gate below: a target has either this field or a
	 * completion port, never both. */
	msTimerHeap timers;
#endif
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

/* ===== Timers (the JS-shaped surface behind std setTimeout/setInterval) ===== */
double msSetTimeout(msClosure cb, double ms);
double msSetInterval(msClosure cb, double ms);
void msClearTimeout(double id);
void msClearInterval(double id);
int msAdjustTimeout(msDispatcher* d, int pollTimeout, int nextTimerMs);

/* ===== Exit drain (drain.c) — Node semantics: program ends when the loop is empty ===== */
void msDrainUntilIdle(void);
int msReportOrphanFailures(void);
void msNoteOrphanFailure(void* fut);
void msClearOrphanFailure(void* fut);
/* Live busy-worker count (pool.c; 0 on single-threaded targets) */
int32_t msPoolBusyPeek(void);

bool msRunOnce(int timeoutMs);
int32_t msGetWakePipeFd(void);
void msPoll(int timeoutMs);
void* msWaitFor(void* fut);
void msWaitForReady(void* fut);
void msRunForever(void);

/* Post completion from pool thread to event loop (libuv pattern) */
void msPostCompletion(void* fut, void* value, bool isFail, void* error);
void msPostEnvRelease(void* env);

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
