/*
 * MetaScript Async Dispatcher — Standard reference implementation parity
 *
 * Event loop implementation: timer heap, ring buffer callback deque, runOnce/poll/waitFor.
 */
#include "runtime/system/core.h"  /* msIncRef/msDecref for async stepper lifecycle */
/* selector.h is included via dispatch.h → future.h chain, but MS_EVENT_READ may not be defined.
 * Define it here for the completion pipe registration. */
#ifndef MS_EVENT_READ
#define MS_EVENT_READ 1
#endif
#include "dispatch.h"
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdio.h>
#ifndef _WIN32
#include <unistd.h>
#include <fcntl.h>
#endif

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

/* ===== Ring Buffer Callback Deque (Standard reference pattern) ===== */

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

/* ===== Global dispatcher (Standard reference threadvar pattern) ===== */

static MS_THREAD_LOCAL msDispatcher* gDispatcher = NULL;

/* callSoon dispatcher impl — registered as msCallSoonProc */
static void msDispatcherCallSoon(msClosure cb) {
	msDispatcher* d = msGetDispatcher();
	msDequePush(&d->callbacks, cb);
}

/* ===== Platform-Specific Cross-Thread Signaling ===== */

#ifdef _WIN32
/* Windows: IOCP — PostQueuedCompletionStatus / GetQueuedCompletionStatusEx.
 * No pipe, no selector. Native completion port handles everything. */

msDispatcher* msGetDispatcher(void) {
	if (gDispatcher == NULL) {
		gDispatcher = (msDispatcher*)calloc(1, sizeof(msDispatcher));
		gDispatcher->iocp = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 0);
		msCallSoonProc = msDispatcherCallSoon;
	}
	return gDispatcher;
}

#else
/* POSIX: self-pipe pattern — pool threads write to pipe[1], event loop reads pipe[0]. */

static int gCompletionPipe[2] = {-1, -1};

msDispatcher* msGetDispatcher(void) {
	if (gDispatcher == NULL) {
		gDispatcher = (msDispatcher*)calloc(1, sizeof(msDispatcher));
		gDispatcher->selector = msSelectorCreate();
		if (gCompletionPipe[0] < 0) {
			pipe(gCompletionPipe);
			fcntl(gCompletionPipe[0], F_SETFL, O_NONBLOCK);
		}
		gDispatcher->completionPipe[0] = gCompletionPipe[0];
		gDispatcher->completionPipe[1] = gCompletionPipe[1];
		if (gDispatcher->selector) {
			msSelectorRegister(gDispatcher->selector, gDispatcher->completionPipe[0], MS_EVENT_READ, NULL);
		}
		msCallSoonProc = msDispatcherCallSoon;
	}
	return gDispatcher;
}

#endif /* _WIN32 */

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

/* Standard reference processTimers pattern
 * Pop expired timers, complete their futures.
 * Returns ms until next timer (+1 margin like standard reference), or -1 if no timers. */
int msProcessTimers(msDispatcher* d, bool* didWork) {
	int64_t now = msMonoTimeMs();
	while (d->timers.len > 0 && d->timers.data[0].finishAtMs <= now) {
		msTimer t = msTimerPop(&d->timers);
		msFutureCompleteVoid(t.fut);
		*didWork = true;
	}
	if (d->timers.len > 0) {
		int64_t diff = d->timers.data[0].finishAtMs - now;
		return (int)(diff > 0 ? diff : 0); /* No margin — step 3 re-processes timers after poll */
	}
	return -1; /* no timers */
}

/* Standard reference processPendingCallbacks pattern
 * Drain ALL pending callbacks (enables eager resume of pre-resolved chains) */
void msProcessCallbacks(msDispatcher* d, bool* didWork) {
	while (msDequeLen(&d->callbacks) > 0) {
		msClosure cb = msDequePop(&d->callbacks);
		((void(*)(void*))cb.fn)(cb.env);
		*didWork = true;
	}
}

/* Standard reference adjustTimeout pattern */
int msAdjustTimeout(msDispatcher* d, int pollTimeout, int nextTimerMs) {
	/* If callbacks pending, no wait */
	if (msDequeLen(&d->callbacks) > 0) return 0;
	/* No timers → use poll timeout as-is */
	if (nextTimerMs < 0) return pollTimeout;
	/* Use the smaller of poll timeout and next timer */
	if (pollTimeout < 0) return nextTimerMs;
	return nextTimerMs < pollTimeout ? nextTimerMs : pollTimeout;
}

/* Standard reference runOnce pattern */
bool msRunOnce(int timeoutMs) {
	msDispatcher* d = msGetDispatcher();
	bool didWork = false;

	/* Step 1: Process expired timers */
	int nextTimer = msProcessTimers(d, &didWork);

	/* Step 2: Poll for cross-thread completions + I/O events */
	int adj = msAdjustTimeout(d, timeoutMs, nextTimer);
#ifdef _WIN32
	/* Windows: IOCP — drain thread-pool completions (and future I/O engine completions) */
	if (d->iocp != NULL) {
		OVERLAPPED_ENTRY entries[64];
		ULONG count = 0;
		BOOL ok = GetQueuedCompletionStatusEx(d->iocp, entries, 64, &count, (DWORD)(adj >= 0 ? adj : 500), FALSE);
		if (ok) {
			for (ULONG i = 0; i < count; i++) {
				didWork = true;
				msCompletionMsg* msg = (msCompletionMsg*)entries[i].lpOverlapped;
				if (msg->isFail) msFutureFail(msg->fut, msg->error);
				else msFutureComplete(msg->fut, msg->value);
				free(msg);
			}
		}
	} else if (adj > 0 && msDequeLen(&d->callbacks) == 0) {
		msSleepMs(adj);
	}
#else
	/* POSIX: selector poll + completion pipe drain */
	if (d->selector != NULL) {
		msReadyEvent readyBuf[64];
		int nready = msSelectorPoll(d->selector, adj, readyBuf, 64);
		for (int i = 0; i < nready; i++) {
			didWork = true;
			/* Completion pipe: drain cross-thread spawn results */
			int pipeFdRead = d->completionPipe[0];
			if (readyBuf[i].fd == pipeFdRead) {
				msCompletionMsg msg;
				while (read(pipeFdRead, &msg, sizeof(msg)) == (ssize_t)sizeof(msg)) {
					if (msg.isFail) msFutureFail(msg.fut, msg.error);
					else msFutureComplete(msg.fut, msg.value);
				}
				continue;
			}
			void* ud = readyBuf[i].userdata;
			if (ud != NULL && !msFutureFinished(ud)) {
				msSelectorUnregister(d->selector, readyBuf[i].fd);
				msFutureCompleteVoid(ud);
			}
		}
	} else if (adj > 0 && msDequeLen(&d->callbacks) == 0) {
		msSleepMs(adj);  /* fallback: no selector */
	}
#endif

	/* Step 3: Process timers again (may have expired during sleep) */
	msProcessTimers(d, &didWork);

	/* Step 4: Drain callback deque */
	msProcessCallbacks(d, &didWork);

	/* Step 5: I/O engine poll is driven by std/net event loops, not here.
	 * Programs that don't use networking don't compile the engine. */

	return didWork;
}

/* Standard reference poll pattern */
void msPoll(int timeoutMs) {
	(void)msRunOnce(timeoutMs);
}

/* Standard reference waitFor pattern — delegates to runOnce (same as reference: while !finished: poll).
 * This ensures all event sources (timers, I/O selector, completion pipe, callbacks) are processed. */
void* msWaitFor(void* fp) {
	msFutureBase* fut = (msFutureBase*)fp;
	while (!fut->finished) {
		msRunOnce(500);
	}
	/* Return the void* value from the future (for backward compat with boxing path).
	 * Treats future as msFuture_ptr and reads its value field.
	 * For void futures, this returns NULL (harmless). */
	return msFutureRead(fp);
}

/* Standard reference runForever pattern */
void msRunForever(void) {
	while (1) {
		msPoll(500);
	}
}

/* Post completion from pool thread to event loop. Thread-safe.
 * POSIX: pipe write (atomic for messages < PIPE_BUF).
 * Windows: PostQueuedCompletionStatus to IOCP. */
void msPostCompletion(void* fut, void* value, bool isFail, void* error) {
#ifdef _WIN32
	HANDLE iocp = gDispatcher != NULL ? gDispatcher->iocp : NULL;
	if (iocp != NULL) {
		msCompletionMsg* msg = (msCompletionMsg*)malloc(sizeof(msCompletionMsg));
		msg->fut = fut;
		msg->value = value;
		msg->isFail = isFail;
		msg->error = error;
		PostQueuedCompletionStatus(iocp, 0, 0, (LPOVERLAPPED)msg);
	} else {
		if (isFail) msFutureFail(fut, error);
		else msFutureComplete(fut, value);
	}
#else
	msCompletionMsg msg = { .fut = fut, .value = value, .isFail = isFail, .error = error };
	int wfd = gCompletionPipe[1];
	if (wfd >= 0) {
		write(wfd, &msg, sizeof(msg));
	} else {
		if (isFail) msFutureFail(fut, error);
		else msFutureComplete(fut, value);
	}
#endif
}

/* Standard reference sleepAsync pattern
 * Create timer future, push to heap, return future */
msFuture_void* msSleepAsync(int ms) {
	msDispatcher* d = msGetDispatcher();
	msFuture_void* fut = msFutureCreateT(msFuture_void);
	int64_t finishAt = msMonoTimeMs() + ms;
	msTimer t = { .finishAtMs = finishAt, .fut = fut };
	msTimerPush(&d->timers, t);
	return fut;
}

/* ===== Async Stepper Callback (createCb pattern) ===== */

void msAsyncCb(void* raw) {
	msAsyncCbEnv* e = (msAsyncCbEnv*)raw;

	/* Call stepper — returns next msFutureBase* to wait on, or NULL when done.
	 * Stepper returns msFutureBase* (any typed future cast to base). */
	msFutureBase* next = e->stepper.env != NULL
		? ((msFutureBase*(*)(void*))e->stepper.fn)(e->stepper.env)
		: ((msFutureBase*(*)(void))e->stepper.fn)();

	/* Eager resume: loop while yielded future is already resolved */
	while (next != NULL && next->finished) {
		next = e->stepper.env != NULL
			? ((msFutureBase*(*)(void*))e->stepper.fn)(e->stepper.env)
			: ((msFutureBase*(*)(void))e->stepper.fn)();
	}

	if (next == NULL) {
		/* Stepper finished — retFut already completed by stepper.
		 * Do NOT msDecref the stepper env here — the future's value may still
		 * reference memory inside the env. DRC handles env cleanup when the
		 * outer scope's stepper variable goes out of scope naturally. */
		free(e);
		return;
	}

	/* Not resolved — register ourselves as callback on the yielded future */
	msFutureAddCallback(next, (msClosure){ .fn = (msClosureFn)msAsyncCb, .env = raw });
}

void msAsyncStart(void* retFut, msClosure stepper) {
	(void)retFut;
	/* Ensure dispatcher exists BEFORE any spawn can happen.
	 * The stepper may call msSpawn which needs the IOCP/pipe for cross-thread completion. */
	msGetDispatcher();
	msAsyncCbEnv* env = (msAsyncCbEnv*)malloc(sizeof(msAsyncCbEnv));
	env->stepper = stepper;
	if (stepper.env) msIncRef(stepper.env);
	msAsyncCb(env);
}

/* Destroy the global dispatcher — cancel timers, drain callbacks, free memory.
 * Matches standard reference closeDispatcher pattern. Resets msCallSoonProc to NULL. */
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
	/* Destroy platform-specific I/O notification */
#ifdef _WIN32
	if (d->iocp != NULL) { CloseHandle(d->iocp); d->iocp = NULL; }
#else
	if (d->selector != NULL) msSelectorDestroy(d->selector);
	if (gCompletionPipe[0] >= 0) { close(gCompletionPipe[0]); gCompletionPipe[0] = -1; }
	if (gCompletionPipe[1] >= 0) { close(gCompletionPipe[1]); gCompletionPipe[1] = -1; }
#endif
	/* Reset globals */
	msCallSoonProc = NULL;
	free(d);
	gDispatcher = NULL;
}
