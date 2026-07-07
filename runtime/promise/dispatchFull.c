#if !defined(MSOS_BARE) && !defined(MSOS_WASM) && !defined(MSOS_EMCC)
/*
 * MetaScript Async Dispatcher — Standard reference implementation parity
 *
 * Event loop implementation: timer heap, ring buffer callback deque, runOnce/poll/waitFor.
 */
#include "runtime/core/system.h"  /* msIncRef/msDecref for async stepper lifecycle */
#include <pthread.h>             /* pthread_once for lazy init */
/* selector.h is included via dispatch.h → future.h chain, but MS_EVENT_READ may not be defined.
 * Define it here for the completion pipe registration. */
#ifndef MS_EVENT_READ
#define MS_EVENT_READ 1
#endif
#include "dispatch.h"
#include "pool.h"    /* Phase 8: msPoolHelpOne for help-first in msWaitForReady */
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdio.h>
#ifndef _WIN32
#include <unistd.h>
#include <fcntl.h>
#endif

/* ===== Actor poll hook (set by actor runtime, NULL if no actors) ===== */
static bool (*msActorPollHook)(void) = NULL;
void msSetActorPollHook(bool (*hook)(void)) { msActorPollHook = hook; }

/* Actor idle timeout cap: shortest actor idle timeout in ms (0 = no cap).
 * When > 0, msRunOnce caps its sleep to this value so idle timeouts fire on time. */
static int msActorIdleCapMs = 0;
void msSetActorIdleCap(int ms) { msActorIdleCapMs = ms; }

/* Actor destroy hook: auto-unregister from name registry.
 * Set by the TU that owns the registry. Called from any TU's msActorDestroyWithReason. */
static void (*msActorDestroyHook)(void* actor) = NULL;
void msSetActorDestroyHook(void (*hook)(void*)) { msActorDestroyHook = hook; }
void msCallActorDestroyHook(void* actor) {
	if (msActorDestroyHook != NULL) msActorDestroyHook(actor);
}


/* ===== Global Future Completion Condvar (worker thread await) =====
 * Signaled on every future completion. Worker threads block here instead
 * of spinning, since they have no event loop. Thundering herd is acceptable
 * for <64 concurrent worker waits; 1ms timeout caps worst-case latency. */

#ifdef _WIN32
static CRITICAL_SECTION gFutCompCs;
static CONDITION_VARIABLE gFutCompCv;
static volatile LONG gFutCompInitFlag = 0;

static void msInitFutComp(void) {
	if (InterlockedCompareExchange(&gFutCompInitFlag, 1, 0) == 0) {
		InitializeCriticalSection(&gFutCompCs);
		InitializeConditionVariable(&gFutCompCv);
		InterlockedExchange(&gFutCompInitFlag, 2);
	} else {
		while (InterlockedCompareExchange(&gFutCompInitFlag, 2, 2) != 2) { Sleep(0); }
	}
}

void msNotifyFutureComplete(void) {
	if (gFutCompInitFlag == 2) WakeAllConditionVariable(&gFutCompCv);
}

void msWorkerWaitOnFuture(void* fp) {
	msInitFutComp();
	msFutureBase* fut = (msFutureBase*)fp;
	EnterCriticalSection(&gFutCompCs);
	if (!atomic_load_explicit(&fut->finished, memory_order_acquire)) {
		SleepConditionVariableCS(&gFutCompCv, &gFutCompCs, 1);
	}
	LeaveCriticalSection(&gFutCompCs);
}
#else
#include <time.h>
static pthread_mutex_t gFutCompMtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  gFutCompCv  = PTHREAD_COND_INITIALIZER;

void msNotifyFutureComplete(void) {
	pthread_cond_broadcast(&gFutCompCv);
}

void msWorkerWaitOnFuture(void* fp) {
	msFutureBase* fut = (msFutureBase*)fp;
	pthread_mutex_lock(&gFutCompMtx);
	if (!atomic_load_explicit(&fut->finished, memory_order_acquire)) {
		struct timespec ts;
		clock_gettime(CLOCK_REALTIME, &ts);
		ts.tv_nsec += 1000000; /* 1ms timeout */
		if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; }
		pthread_cond_timedwait(&gFutCompCv, &gFutCompMtx, &ts);
	}
	pthread_mutex_unlock(&gFutCompMtx);
}
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

void msCompletionQueuePush(void* fut, bool isFail, void* error) {
	msPostCompletion(fut, NULL, isFail, error);
}

/* Windows IOCP takes no queue-side ref (the completion msg carries a raw
 * fut pointer), so Owned == Push here — the owner-thread submit ref is
 * gated off on Windows (MS_FUTURE_SUBMIT_REF == 0). */
void msCompletionQueuePushOwned(void* fut, bool isFail, void* error) {
	msPostCompletion(fut, NULL, isFail, error);
}

#else
/* POSIX: MPSC queue for cross-thread completion + wake-only self-pipe.
 * Pony parity: lock-free queue replaces pipe for data delivery (100x faster).
 * The pipe now carries only 1-byte wake signals (no framing issues). */

#include "runtime/actor/mailbox.h"

static int gWakePipe[2] = {-1, -1};           /* wake-only self-pipe (1-byte signals) */
static msMpscQueue gCompletionQueue;           /* lock-free MPSC for future completions */
static bool gCompletionQueueInited = false;
static pthread_once_t gQueueOnce = PTHREAD_ONCE_INIT;

static void msInitQueueOnce(void) {
	if (gWakePipe[0] < 0) {
		pipe(gWakePipe);
		fcntl(gWakePipe[0], F_SETFL, O_NONBLOCK);
	}
	msMpscInit(&gCompletionQueue);
	gCompletionQueueInited = true;
}
void msEnsureWakePipe(void);

/* Push a future completion to the MPSC queue + wake the selector.
 * Called from worker threads. Dispatcher drains the queue and fires callbacks. */
void msCompletionQueuePush(void* fut, bool isFail, void* error) {
    msEnsureWakePipe();
    /* Queue owns a ref while the completion message is in flight: the future can
     * finish (worker sets finished) and be freed by its owner before the drain pops
     * this message, leaving a stale replyFuture → UAF in msFutureFireCallbacks.
     * Non-atomic incref is safe — the MPSC push/pop barrier orders this worker incref
     * before the dispatcher's matching decref; no other thread touches this rc. */
    if (fut != NULL) msIncRef(fut);
    msMessage* msg = msMsgAlloc(/*kind=*/isFail ? -1 : 0, /*replyFut=*/fut);
    msMsgSetPtr(msg, 0, error);
    msMpscPush(&gCompletionQueue, msg);
    /* Always wake — no amortization. Two writers (actor send + spawn completion)
     * sharing one flag caused missed wakes and 500ms selector stalls. The wake
     * pipe absorbs duplicates (64KB buffer, 1 byte each, drained in bulk). */
    if (gWakePipe[1] >= 0) {
        char c = 1;
        (void)write(gWakePipe[1], &c, 1);
    }
}

/* Same as msCompletionQueuePush but WITHOUT the internal incref: the owner
 * thread already took the queue's in-flight ref at submit time (msSpawn /
 * msSpawnInto / msAwaitGroupSetDoneFut), before the future could become
 * visible-as-finished. That ordering closes the publish->push UAF window —
 * the worker publishes `finished` then pushes, and between those an owner
 * observing `finished` could free the future before a push-time incref ran.
 * The submit-time ref makes the owner's msDecRefIsLast see rc>=1 (not last),
 * so it can't free until the dispatcher drain's msFutureDrcDestroy runs. */
void msCompletionQueuePushOwned(void* fut, bool isFail, void* error) {
    msEnsureWakePipe();
    msMessage* msg = msMsgAlloc(/*kind=*/isFail ? -1 : 0, /*replyFut=*/fut);
    msMsgSetPtr(msg, 0, error);
    msMpscPush(&gCompletionQueue, msg);
    if (gWakePipe[1] >= 0) {
        char c = 1;
        (void)write(gWakePipe[1], &c, 1);
    }
}

/* Amendment H: batch release — push N deferred decrefs as a chain with one
 * atomic exchange (msMpscPushChain). Called by msFutureReleaseFlush at batch
 * boundaries. Each message has kind=-2 (release: decref only, no callback).
 * The dispatcher drain processes them single-threaded, serializing with the
 * drain decref — no race on the rc field, no atomic needed. */
void msCompletionQueuePushReleaseBatch(void** futs, int count) {
    if (count <= 0) return;
    msEnsureWakePipe();
    msMessage* first = NULL;
    msMessage* last = NULL;
    for (int i = 0; i < count; i++) {
        if (futs[i] == NULL) continue;
        msMessage* msg = msMsgAlloc(/*kind=*/-2, /*replyFut=*/futs[i]);
        if (last != NULL) {
            atomic_store_explicit(&last->next, msg, memory_order_relaxed);
        } else {
            first = msg;
        }
        last = msg;
    }
    if (first == NULL) return;
    msMpscPushChain(&gCompletionQueue, first, last);
    if (gWakePipe[1] >= 0) {
        char c = 1;
        (void)write(gWakePipe[1], &c, 1);
    }
}

/* Ensure wake pipe + MPSC queue are initialized (called by actor init).
 * Separate from msGetDispatcher because actors may send messages before
 * any await/event-loop code runs — the wake pipe must exist for those
 * early sends to signal correctly. */
void msEnsureWakePipe(void) {
    pthread_once(&gQueueOnce, msInitQueueOnce);
}

/* Get the read end of the wake pipe fd.
 * Used by HTTP async event loops to register with their own selector,
 * so spawn completions can wake the HTTP selector (not just the dispatcher's). */
int32_t msGetWakePipeFd(void) {
    msEnsureWakePipe();
    return gWakePipe[0];
}

/* Wake event loop from another thread (Pony-style: unpark scheduler).
 * Used by actor subsystem when scheduling work on the main thread.
 * Always writes (no amortization) — same rationale as msCompletionQueuePush. */
void msActorWakeEventLoop(void) {
    if (gWakePipe[1] >= 0) {
        char c = 1;
        (void)write(gWakePipe[1], &c, 1);
    }
}

/* Drain all pending completions from the MPSC queue.
 * Fires callbacks on the dispatcher thread (correct thread for async steppers). */
bool msCompletionQueueDrain(void) {
    bool didWork = false;
    msEnsureWakePipe();
    msMessage* msg;
    while ((msg = msMpscPop(&gCompletionQueue)) != NULL) {
        void* fut = msg->replyFuture;
        /* Don't free msg — it's the queue's new tail/stub (Vyukov MPSC invariant).
         * It gets freed on the NEXT pop when a newer message takes its place. */
        if (msg->kind == -2) {
            /* Amendment H: deferred release — decref only, no callback.
             * Both this and the drain decref run on the dispatcher thread. */
            if (fut != NULL) msFutureDrcDestroy(fut);
        } else if (fut != NULL) {
            /* Fire callbacks for BOTH success and failure — the worker pre-set
             * value/error/failed/finished (Step 1), mirroring the Windows IOCP path.
             * msFutureFail here would hit its finished-guard and strand async
             * steppers awaiting a failed spawn (I15). Every isFail producer MUST
             * pre-set failed/error/finished before pushing. */
            msFutureFireCallbacks((msFutureBase*)fut);
            msFutureDrcDestroy(fut);  /* release the queue's in-flight ref (paired with push incref) */
        }
        didWork = true;
    }
    return didWork;
}

msDispatcher* msGetDispatcher(void) {
	if (gDispatcher == NULL) {
		gDispatcher = (msDispatcher*)calloc(1, sizeof(msDispatcher));
		gDispatcher->selector = msSelectorCreate();
		msEnsureWakePipe();  /* wake pipe + MPSC queue (may already be initialized by actor init) */
		if (gDispatcher->selector) {
			msSelectorRegister(gDispatcher->selector, gWakePipe[0], MS_EVENT_READ, NULL);
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

/* Expose the dispatcher's selector fd (kqueue/epoll). Returns -1 when no
 * dispatcher is initialized or the backend has no fd (poll/Windows). Used
 * by I/O engine to chain-poll the dispatcher's selector with its own. */
int msGetDispatcherSelectorFd(void) {
#ifdef _WIN32
	/* Windows dispatcher uses IOCP, not a selector with an fd. */
	return -1;
#else
	if (gDispatcher == NULL || gDispatcher->selector == NULL) return -1;
	return msSelectorGetFd(gDispatcher->selector);
#endif
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
	/* Cap to actor idle timeout if set (ensures idle scan fires on time) */
	if (msActorIdleCapMs > 0 && (pollTimeout < 0 || msActorIdleCapMs < pollTimeout)) {
		pollTimeout = msActorIdleCapMs;
	}
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

	/* Step 1b: Drain actor mailboxes FIRST — actors may re-enqueue and write
	 * to the wake pipe. Processing them before the selector ensures the
	 * selector sees any pending wake bytes from re-enqueue, avoiding a
	 * 500ms stall when actor batches overflow. */
	if (msActorPollHook != NULL) {
		bool actorWork = msActorPollHook();
		didWork = actorWork || didWork;
	}

	/* Step 2: Poll for cross-thread completions + I/O events */
	int adj = msAdjustTimeout(d, timeoutMs, nextTimer);
#ifdef _WIN32
	/* Windows: IOCP — drain thread-pool completions (and future I/O engine completions).
	 * Worker already set value + finished (Step 1, see thread.h:99-103); main thread
	 * just fires callbacks (Step 2). Using msFutureComplete/msFutureFail here would
	 * hit the finished-guard and skip callbacks — leaving async steppers stuck. */
	if (d->iocp != NULL) {
		OVERLAPPED_ENTRY entries[64];
		ULONG count = 0;
		BOOL ok = GetQueuedCompletionStatusEx(d->iocp, entries, 64, &count, (DWORD)(adj >= 0 ? adj : 500), FALSE);
		if (ok) {
			for (ULONG i = 0; i < count; i++) {
				didWork = true;
				msCompletionMsg* msg = (msCompletionMsg*)entries[i].lpOverlapped;
				if (msg->fut != NULL) msFutureFireCallbacks((msFutureBase*)msg->fut);
				free(msg);
			}
		}
	} else if (adj > 0 && msDequeLen(&d->callbacks) == 0) {
		msSleepMs(adj);
	}
#else
	/* POSIX: pre-poll MPSC drain + selector poll + post-poll drain.
	 * Completions arrive via lock-free MPSC queue (not pipe). The wake pipe
	 * only carries 1-byte signals to unblock the selector. */
	if (msCompletionQueueDrain()) didWork = true;  /* pre-poll: process without blocking */
	if (d->selector != NULL) {
		msReadyEvent readyBuf[64];
		int nready = msSelectorPoll(d->selector, didWork ? 0 : adj, readyBuf, 64);
		for (int i = 0; i < nready; i++) {
			didWork = true;
			/* Wake pipe: drain bytes, actual data is in MPSC queue */
			if (readyBuf[i].fd == gWakePipe[0]) {
				char buf[64];
				(void)read(gWakePipe[0], buf, sizeof(buf));
				continue;
			}
			/* I/O events (unchanged) */
			void* ud = readyBuf[i].userdata;
			if (ud != NULL && !msFutureFinished(ud)) {
				msSelectorUnregister(d->selector, readyBuf[i].fd);
				msFutureCompleteVoid(ud);
			}
		}
		/* Post-poll: drain completions that arrived during selector block */
		if (msCompletionQueueDrain()) didWork = true;
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

	/* Step 6: Actor poll moved to step 1b (before selector). */

	/* Amendment H: flush deferred future releases accumulated on this thread
	 * during actor processing / async stepper execution. Pushes them as a
	 * chain to the completion queue for the drain to process single-threaded. */
	msFutureReleaseFlush();

	return didWork;
}

/* Standard reference poll pattern */
void msPoll(int timeoutMs) {
	(void)msRunOnce(timeoutMs);
}

/* Dual-path wait: main thread runs event loop (msRunOnce), workers use condvar.
 * Uses the pool's TLS worker flag — set in msPoolWorkerLoop at thread entry. */
static inline bool msIsWorkerWait(void) {
	extern _Thread_local bool msIsPoolWorker;
	return msIsPoolWorker;
}

/* Active-wait timeout for msWaitFor/msWaitForReady.
 * Short timeout (5ms) bounds worst-case latency when pipe wakes miss the
 * selector (timing race between worker completion and kqueue poll start).
 * Cost: ~1 kqueue syscall per 5ms while waiting — negligible.
 * Production runtimes use similar bounds (Tokio ~50μs, Go ~10ms, Pony ~1ms). */
#define MS_ACTIVE_WAIT_MS 5

void* msWaitFor(void* fp) {
	msFutureBase* fut = (msFutureBase*)fp;
	bool worker = msIsWorkerWait();
	if (!worker) msGetDispatcher(); /* ensure event loop exists on main thread */
	if (worker) msPoolBusyDec();  /* signal availability while waiting */
	while (!atomic_load_explicit(&fut->finished, memory_order_acquire)) {
		if (msPoolHelpOne()) continue;
		if (!worker) {
			msRunOnce(MS_ACTIVE_WAIT_MS);
		} else {
			msWorkerWaitOnFuture(fp);
		}
	}
	if (worker) msPoolBusyInc();  /* back to own work */
	return msFutureRead(fp);
}

void msWaitForReady(void* fp) {
	msFutureBase* fut = (msFutureBase*)fp;
	bool worker = msIsWorkerWait();
	if (!worker) msGetDispatcher(); /* ensure event loop exists on main thread */
	if (worker) msPoolBusyDec();  /* signal availability while waiting */
	int spins = 0;
	bool helped = false;
	while (!atomic_load_explicit(&fut->finished, memory_order_acquire)) {
		if (msPoolHelpOne()) { spins = 0; helped = true; continue; }
		if (!worker) {
			msRunOnce(MS_ACTIVE_WAIT_MS);
		} else if (helped && spins < 32) {
			spins++;
			msYield();
		} else {
			msWorkerWaitOnFuture(fp);
			spins = 0;
			helped = false;
		}
	}
	if (worker) msPoolBusyInc();  /* back to own work */
}

/* Standard reference runForever pattern */
void msRunForever(void) {
	while (1) {
		msPoll(500);
	}
}

/* Post completion from pool thread to event loop. Thread-safe.
 * POSIX: MPSC queue push (lock-free, Pony parity).
 * Windows: PostQueuedCompletionStatus to IOCP (native MPSC). */
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
	msCompletionQueuePush(fut, isFail, error);
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
	 * Stepper returns msFutureBase* (any typed future cast to base).
	 *
	 * DRC convention: stepper increfs the returned future before returning
	 * (caller takes ownership of the +1 ref). msAsyncCb decrefs after using
	 * the pointer to register the callback — the stepper's env field still
	 * holds the future's permanent ref, keeping it alive while suspended. */
	msFutureBase* next = e->stepper.env != NULL
		? ((msFutureBase*(*)(void*))e->stepper.fn)(e->stepper.env)
		: ((msFutureBase*(*)(void))e->stepper.fn)();

	/* Eager resume: loop while yielded future is already resolved.
	 * Each stepper return brings a +1 ref; decref the previous yield
	 * before overwriting `next` to avoid leaking one future per eager step. */
	while (next != NULL && atomic_load_explicit(&next->finished, memory_order_acquire)) {
		msFutureDrcDestroy(next);
		next = e->stepper.env != NULL
			? ((msFutureBase*(*)(void*))e->stepper.fn)(e->stepper.env)
			: ((msFutureBase*(*)(void))e->stepper.fn)();
	}

	if (next == NULL) {
		/* Stepper completed — drop the env reference taken in msAsyncStart.
		 * The eager path of msAsyncStart runs msAsyncCb synchronously: env count
		 * is still elevated by the runtime's msIncRef at this point, and the
		 * caller's scope-exit msClosureDestroy + msDecref(env) bring it back to
		 * 0 → destroyFn fires.
		 *
		 * The suspended path is more subtle: msClosureDestroy + msDecref(env)
		 * have already run at the original call's scope-exit by the time the
		 * callback fires here. Env memory is held alive only by the runtime's
		 * +1 (this decref here). After this msDecref, msDecRefIsLast sees rc=0
		 * → destroyFn fires → memory freed. The raw msAsyncCbEnv* pointer that
		 * carried env through the callback chain is then released via free(e). */
		if (e->stepper.env != NULL) msDecref(e->stepper.env);
		free(e);
		return;
	}

	/* Not resolved — register ourselves as callback on the yielded future,
	 * then drop our +1 ref (env field keeps the future alive while suspended). */
	msFutureAddCallback(next, (msClosure){ .fn = (msClosureFn)msAsyncCb, .env = raw });
	msFutureDrcDestroy(next);
}

void msAsyncStart(void* retFut, msClosure stepper) {
	(void)retFut;
	/* Main thread: ensure dispatcher exists (needs IOCP/pipe for cross-thread completion).
	 * Worker threads: skip dispatcher creation. Workers have no event loop — they rely on
	 * inline callback execution (msCallSoonProc == NULL → msCallSoon fires immediately)
	 * and the global completion condvar for blocking waits.
	 *
	 * Detection: if msCallSoonProc is set, dispatcher already exists (main thread re-entry).
	 * If not set but completion pipe isn't initialized yet, this is the first call on the
	 * main thread — must create. If pipe IS initialized but this thread has no dispatcher,
	 * we're a worker — skip. */
	bool isWorker = false;
#ifdef _WIN32
	/* Windows: no simple global check. Always create on first call per thread.
	 * Worker threads that call msAsyncStart get a local dispatcher — acceptable
	 * because msWorkerWaitOnFuture handles the wait correctly regardless. */
#else
	{ extern _Thread_local bool msIsPoolWorker; isWorker = msIsPoolWorker; }
#endif
	if (!isWorker) {
		msGetDispatcher();
	}
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
	if (gWakePipe[0] >= 0) { close(gWakePipe[0]); gWakePipe[0] = -1; }
	if (gWakePipe[1] >= 0) { close(gWakePipe[1]); gWakePipe[1] = -1; }
	if (gCompletionQueueInited) { msMpscDestroy(&gCompletionQueue); gCompletionQueueInited = false; }
#endif
	/* Reset globals */
	msCallSoonProc = NULL;
	free(d);
	gDispatcher = NULL;
}

#endif /* !MSOS_BARE && !MSOS_WASM && !MSOS_EMCC */

/* Emscripten dispatcher: see dispatchEmcc.c */
