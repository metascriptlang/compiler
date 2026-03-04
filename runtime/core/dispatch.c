/*
 * MetaScript Async Dispatcher — Nim asyncdispatch.nim parity
 *
 * Event loop implementation: timer heap, ring buffer callback deque, runOnce/poll/waitFor.
 */
#include "dispatch.h"
#include <stdlib.h>
#include <string.h>
#include <assert.h>

/* ===== Platform-specific time + sleep ===== */

#ifdef _WIN32
#include <windows.h>
int64_t msMonoTimeMs(void) {
	LARGE_INTEGER freq, cnt;
	QueryPerformanceFrequency(&freq);
	QueryPerformanceCounter(&cnt);
	return (int64_t)(cnt.QuadPart * 1000 / freq.QuadPart);
}
void msSleepMs(int ms) {
	if (ms > 0) Sleep((DWORD)ms);
}
#else
#include <time.h>
#include <unistd.h>
int64_t msMonoTimeMs(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
void msSleepMs(int ms) {
	if (ms > 0) {
		struct timespec ts;
		ts.tv_sec = ms / 1000;
		ts.tv_nsec = (ms % 1000) * 1000000L;
		nanosleep(&ts, NULL);
	}
}
#endif

/* ===== Ring Buffer Callback Deque (Nim's Deque[proc()]) ===== */

static int msDequeLen(msCallbackDeque* d) {
	if (d->cap == 0) return 0;
	return (d->tail - d->head + d->cap) % d->cap;
}

static void msDequeGrow(msCallbackDeque* d) {
	int oldCap = d->cap;
	int newCap = oldCap == 0 ? 8 : oldCap * 2;
	msClosure* newItems = (msClosure*)malloc(newCap * sizeof(msClosure));
	/* Copy existing items in order */
	int len = msDequeLen(d);
	for (int i = 0; i < len; i++) {
		newItems[i] = d->items[(d->head + i) % oldCap];
	}
	free(d->items);
	d->items = newItems;
	d->head = 0;
	d->tail = len;
	d->cap = newCap;
}

static void msDequePush(msCallbackDeque* d, msClosure cb) {
	if (d->cap == 0 || msDequeLen(d) >= d->cap - 1) {
		msDequeGrow(d);
	}
	d->items[d->tail] = cb;
	d->tail = (d->tail + 1) % d->cap;
}

static msClosure msDequePop(msCallbackDeque* d) {
	assert(msDequeLen(d) > 0 && "Deque is empty");
	msClosure cb = d->items[d->head];
	d->head = (d->head + 1) % d->cap;
	return cb;
}

/* ===== Global dispatcher (Nim's gDisp threadvar) ===== */

static MS_THREAD_LOCAL msDispatcher* gDispatcher = NULL;

/* callSoon dispatcher impl — registered as msCallSoonProc */
static void msDispatcherCallSoon(msClosure cb) {
	msDispatcher* d = msGetDispatcher();
	msDequePush(&d->callbacks, cb);
}

/* Nim's getGlobalDispatcher — lazy init */
msDispatcher* msGetDispatcher(void) {
	if (gDispatcher == NULL) {
		gDispatcher = (msDispatcher*)calloc(1, sizeof(msDispatcher));
		gDispatcher->selector = msSelectorCreate();
		/* Register callSoon with future system (Nim's initCallSoonProc) */
		msCallSoonProc = msDispatcherCallSoon;
	}
	return gDispatcher;
}

/* Check if dispatcher exists (without creating one) */
bool msHasDispatcher(void) {
	return gDispatcher != NULL;
}

/* ===== Timer Heap (binary min-heap on finishAtMs) ===== */

static void msTimerHeapGrow(msTimerHeap* h) {
	int newCap = h->cap == 0 ? 8 : h->cap * 2;
	h->data = (msTimer*)realloc(h->data, newCap * sizeof(msTimer));
	h->cap = newCap;
}

static void msTimerSiftUp(msTimerHeap* h, int i) {
	while (i > 0) {
		int parent = (i - 1) / 2;
		if (h->data[parent].finishAtMs <= h->data[i].finishAtMs) break;
		msTimer tmp = h->data[parent];
		h->data[parent] = h->data[i];
		h->data[i] = tmp;
		i = parent;
	}
}

static void msTimerSiftDown(msTimerHeap* h, int i) {
	int n = h->len;
	while (1) {
		int smallest = i;
		int left = 2 * i + 1;
		int right = 2 * i + 2;
		if (left < n && h->data[left].finishAtMs < h->data[smallest].finishAtMs)
			smallest = left;
		if (right < n && h->data[right].finishAtMs < h->data[smallest].finishAtMs)
			smallest = right;
		if (smallest == i) break;
		msTimer tmp = h->data[smallest];
		h->data[smallest] = h->data[i];
		h->data[i] = tmp;
		i = smallest;
	}
}

static void msTimerPush(msTimerHeap* h, msTimer t) {
	if (h->len >= h->cap) msTimerHeapGrow(h);
	h->data[h->len] = t;
	msTimerSiftUp(h, h->len);
	h->len++;
}

static msTimer msTimerPop(msTimerHeap* h) {
	assert(h->len > 0);
	msTimer min = h->data[0];
	h->len--;
	if (h->len > 0) {
		h->data[0] = h->data[h->len];
		msTimerSiftDown(h, 0);
	}
	return min;
}

/* ===== Event Loop Functions ===== */

/* Nim's processTimers (lines 249-264)
 * Pop expired timers, complete their futures.
 * Returns ms until next timer (+1 margin like Nim), or -1 if no timers. */
int msProcessTimers(msDispatcher* d, bool* didWork) {
	int64_t now = msMonoTimeMs();
	while (d->timers.len > 0 && d->timers.data[0].finishAtMs <= now) {
		msTimer t = msTimerPop(&d->timers);
		msFutureComplete(t.fut, NULL);
		*didWork = true;
	}
	if (d->timers.len > 0) {
		int64_t diff = d->timers.data[0].finishAtMs - now;
		return (int)(diff > 0 ? diff + 1 : 1); /* +1 margin matches Nim */
	}
	return -1; /* no timers */
}

/* Nim's processPendingCallbacks (lines 266-270)
 * Drain ALL pending callbacks (enables eager resume of pre-resolved chains) */
void msProcessCallbacks(msDispatcher* d, bool* didWork) {
	while (msDequeLen(&d->callbacks) > 0) {
		msClosure cb = msDequePop(&d->callbacks);
		((void(*)(void*))cb.fn)(cb.env);
		*didWork = true;
	}
}

/* Nim's adjustTimeout (lines 272-282) */
int msAdjustTimeout(msDispatcher* d, int pollTimeout, int nextTimerMs) {
	/* If callbacks pending, no wait */
	if (msDequeLen(&d->callbacks) > 0) return 0;
	/* No timers → use poll timeout as-is */
	if (nextTimerMs < 0) return pollTimeout;
	/* Use the smaller of poll timeout and next timer */
	if (pollTimeout < 0) return nextTimerMs;
	return nextTimerMs < pollTimeout ? nextTimerMs : pollTimeout;
}

/* Nim's runOnce POSIX (lines 1397-1453) */
bool msRunOnce(int timeoutMs) {
	msDispatcher* d = msGetDispatcher();
	bool didWork = false;

	/* Step 1: Process expired timers */
	int nextTimer = msProcessTimers(d, &didWork);

	/* Step 2: I/O selector — poll for ready events, or sleep as fallback */
	int adj = msAdjustTimeout(d, timeoutMs, nextTimer);
	if (d->selector != NULL) {
		msReadyEvent readyBuf[64];
		int nready = msSelectorPoll(d->selector, adj, readyBuf, 64);
		for (int i = 0; i < nready; i++) {
			didWork = true;
			msFuture* fut = (msFuture*)readyBuf[i].userdata;
			if (fut != NULL && !fut->finished) {
				msFutureComplete(fut, (void*)(intptr_t)readyBuf[i].events);
			}
		}
	} else if (adj > 0 && msDequeLen(&d->callbacks) == 0) {
		msSleepMs(adj);  /* fallback: no selector */
	}

	/* Step 3: Process timers again (may have expired during sleep) */
	msProcessTimers(d, &didWork);

	/* Step 4: Drain callback deque */
	msProcessCallbacks(d, &didWork);

	return didWork;
}

/* Nim's poll (line 1708) */
void msPoll(int timeoutMs) {
	(void)msRunOnce(timeoutMs);
}

/* Nim's waitFor (lines 2020-2025)
 * Block until future completes, then read (re-raising errors via msErr) */
void* msWaitFor(msFuture* fut) {
	while (!fut->finished) {
		msPoll(500);
	}
	return msFutureRead(fut);
}

/* Nim's runForever (lines 2015-2018) */
void msRunForever(void) {
	while (1) {
		msPoll(500);
	}
}

/* Nim's sleepAsync (lines 1920-1930)
 * Create timer future, push to heap, return future */
msFuture* msSleepAsync(int ms) {
	msDispatcher* d = msGetDispatcher();
	msFuture* fut = msFutureCreate();
	int64_t finishAt = msMonoTimeMs() + ms;
	msTimer t = { .finishAtMs = finishAt, .fut = fut };
	msTimerPush(&d->timers, t);
	return fut;
}

/* Destroy the global dispatcher — cancel timers, drain callbacks, free memory.
 * Matches Nim's closeDispatcher(). Resets msCallSoonProc to NULL. */
void msDestroyDispatcher(void) {
	msDispatcher* d = gDispatcher;
	if (d == NULL) return;
	/* Cancel all pending timers */
	while (d->timers.len > 0) {
		msTimer t = msTimerPop(&d->timers);
		msFutureCancel(t.fut);
	}
	free(d->timers.data);
	/* Drain remaining callbacks (execute them) */
	while (msDequeLen(&d->callbacks) > 0) {
		msClosure cb = msDequePop(&d->callbacks);
		((void(*)(void*))cb.fn)(cb.env);
	}
	free(d->callbacks.items);
	/* Destroy I/O selector */
	if (d->selector != NULL) msSelectorDestroy(d->selector);
	/* Reset globals */
	msCallSoonProc = NULL;
	free(d);
	gDispatcher = NULL;
}
