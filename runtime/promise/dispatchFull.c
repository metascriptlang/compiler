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
#include "locked.h"  /* msTicketLock — the runtime's one lock primitive (Amendment E) */
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

extern _Thread_local bool msIsPoolWorker;  /* pool.c — true only on pool worker threads */

/* Timers live on ONE process-global heap, not in the per-thread dispatcher.
 *
 * The thread that arms a timer is not always the thread that can service it: a
 * pool worker running a spawn task has no event loop (it parks on the
 * completion condvar and never calls msRunOnce), so a timer pushed onto its own
 * dispatcher's heap is never popped and its future never completes — the
 * program hangs. Making the heap global removes the question entirely: whoever
 * runs a loop services every armed timer, exactly like the process-global MPSC
 * completion queue on POSIX and wake-registry entry 0 on Windows.
 *
 * `msDispatcher.timers` is consequently NOT COMPILED on this target — the
 * field is gated to the single-threaded dispatchers (wasm/emcc/bare) in
 * dispatch.h, which have no worker threads and therefore no such split. A
 * `d->timers` here is a compile error, not a silently dead write.
 *
 * The lock is `msTicketLock` (locked.h) — the runtime's ONE lock primitive,
 * per Amendment E: FIFO-fair, zero-init valid, bounded spin then an
 * address-keyed park. Reusing it rather than hand-rolling a second spinlock
 * keeps one place to fix a locking bug, and the fairness matters here: an
 * arming pool worker must not be starved by a loop thread that re-takes the
 * lock every `msProcessTimers` pass.
 *
 * Amendment E's discipline rule is satisfied by construction — the lock covers
 * heap mutations ONLY, never a timer callback (which may itself call
 * setTimeout/clearTimeout and would deadlock a non-reentrant lock), and never
 * a future completion. Every critical section below is a heap push/pop/scan. */
static msTicketLock gTimerLock = { 0, 0 };
static msTimerHeap gTimers = { NULL, 0, 0 };

static inline void msTimerLock(void) { msTicketLockAcquire(&gTimerLock); }
static inline void msTimerUnlock(void) { msTicketLockRelease(&gTimerLock); }

/* callSoon dispatcher impl — registered as msCallSoonProc */
static void msDispatcherCallSoon(msClosure cb) {
	msDispatcher* d = msGetDispatcher();
	msDequePush(&d->callbacks, cb);
}

/* ===== Platform-Specific Cross-Thread Signaling ===== */

#ifdef _WIN32
/* Windows: IOCP — PostQueuedCompletionStatus / GetQueuedCompletionStatusEx.
 * No pipe, no selector. Native completion port handles everything. */

/* The IOCP twin of the POSIX process-global wake pipe — the Layer-2 channel of
 * PARALOCK Amendment A plus the scheduler-0 wake that actor.h's `sid == 0`
 * sends use via msActorWakeEventLoop.
 *
 * POSIX topology (msGetDispatcher below the #else): ONE process-global wake
 * pipe, and EVERY dispatcher's selector registers its read end — a 1-byte
 * write fans out to every event loop. The IOCP mirror therefore cannot be a
 * single first-loop-wins handle: it is a registry, and a wake posts to every
 * registered port. Same fan-out, and a loop that does not exist simply is not
 * in the registry. In every PARALOCK topology exactly one loop exists
 * (scheduler 0 = the main thread; pool workers park on condvars and never run
 * loops — the dual-path wait), so this holds one entry; the shape is kept so a
 * multi-loop topology degrades the way POSIX does rather than silently
 * missing wakes.
 *
 * Registry entry 0 — the first loop created, scheduler 0 in every real
 * topology — doubles as the completion target for threads that own no
 * dispatcher (see msPostCompletion): the POSIX worker pushes to the
 * process-global MPSC that the event loop drains; the IOCP analog is the
 * loop's own port.
 *
 * Publish ordering: reserve the slot (InterlockedIncrement) before storing the
 * handle. A waker may observe a reserved slot whose handle is not yet stored
 * (reads NULL, skips it) — harmless, because the owning thread cannot yet be
 * blocked on a port it has not finished creating. */
#define MS_WAKE_IOCP_MAX 8
static HANDLE volatile gWakeIocps[MS_WAKE_IOCP_MAX];
static volatile LONG gWakeIocpCount = 0;

msDispatcher* msGetDispatcher(void) {
	if (gDispatcher == NULL) {
		gDispatcher = (msDispatcher*)calloc(1, sizeof(msDispatcher));
		gDispatcher->iocp = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 0);
		/* Register in the wake registry — the IOCP mirror of POSIX's
		 * msSelectorRegister(gDispatcher->selector, gWakePipe[0], …) in the
		 * #else branch below. */
		LONG idx = InterlockedIncrement(&gWakeIocpCount) - 1;
		if (idx >= 0 && idx < MS_WAKE_IOCP_MAX) {
			gWakeIocps[idx] = gDispatcher->iocp;
		}
		msCallSoonProc = msDispatcherCallSoon;
	}
	return gDispatcher;
}

static HANDLE msFirstLoopIocp(void) {
	LONG n = InterlockedCompareExchange(&gWakeIocpCount, 0, 0);
	return n > 0 ? gWakeIocps[0] : NULL;
}

/* Init the cross-thread wake channel early — called by msActorRegister before
 * any actor send can happen. POSIX opens the self-pipe + MPSC queue here
 * (pthread_once); on Windows creating the dispatcher is what registers the
 * wake port, so this is the same contract ("after this returns, a wake from
 * any thread has a target") spelled in IOCP terms. Name kept because actor.h
 * declares one symbol for both platforms. */
void msEnsureWakePipe(void) {
	(void)msGetDispatcher();
}

/* Wake the event loop(s) from another thread — the IOCP twin of POSIX's 1-byte
 * write to the wake pipe: post to EVERY registered port, because any loop may
 * be the one blocked. lpOverlapped = NULL is the wake itself — the same
 * primitive Amendment B's IOCP engine-wake arm uses (msIoEngineWake,
 * engineIOCP.c) — and the drain in msRunOnce skips NULL entries the same way
 * the engine poll does. One syscall per loop, no allocation: the POSIX wake
 * cost. */
void msActorWakeEventLoop(void) {
	LONG n = InterlockedCompareExchange(&gWakeIocpCount, 0, 0);
	if (n > MS_WAKE_IOCP_MAX) n = MS_WAKE_IOCP_MAX;
	for (LONG i = 0; i < n; i++) {
		HANDLE h = gWakeIocps[i];
		if (h != NULL) PostQueuedCompletionStatus(h, 0, 0, NULL);
	}
}

/* No wake FD exists on Windows — the loop is woken through the IOCP above, not
 * through a pollable descriptor. Same -1 contract as msGetDispatcherSelectorFd
 * on Windows (below) and the wasm/emcc dispatchers, so callers that register
 * the fd in their own selector skip it. */
int32_t msGetWakePipeFd(void) { return -1; }

/* Called from the spawn submit sites (thread.h) on the OWNER thread: ensure
 * the scheduler-0 loop's port exists BEFORE a worker can complete into it —
 * channel-exists-before-visible, the Windows twin of the submit-time
 * discipline Amendment G applies to the completion ref. POSIX needs no
 * counterpart: its completion channel is the process-global MPSC, created
 * lazily by any thread's push. Worker-guarded: a nested spawn from a pool
 * worker must not mint a worker-local port nobody drains — its children's
 * completions route to registry entry 0 via msPostCompletion's fallback,
 * exactly like POSIX's global queue. */
void msEnsureLoopChannel(void) {
	extern _Thread_local bool msIsPoolWorker;  /* pool.c */
	if (!msIsPoolWorker) (void)msGetDispatcher();
}

/* Cross-thread completion core: takeRef=true takes the queue-side in-flight
 * ref (public Push contract); takeRef=false relies on the owner-thread submit
 * ref (Amendment G Owned path). Defined below, before the POSIX #else. */
static void msPostCompletionCore(void* fut, void* value, bool isFail, void* error, bool takeRef);

void msCompletionQueuePush(void* fut, bool isFail, void* error) {
	msPostCompletion(fut, NULL, isFail, error);
}

/* Owned path: the owner-thread submit ref (Amendment G, MS_FUTURE_SUBMIT_REF)
 * already holds the future across the worker's publish and this post — a ref
 * here would double-count against the drain's single release. */
void msCompletionQueuePushOwned(void* fut, bool isFail, void* error) {
	msPostCompletionCore(fut, NULL, isFail, error, false);
}

/* Amendment H (Windows): deferred closure-env release — same kind=-3 message
 * msPostEnvRelease posts, reached through the queue-named API thread.h calls
 * under MS_FUTURE_SUBMIT_REF. */
void msCompletionQueuePushEnvRelease(void* env) {
	msPostEnvRelease(env);
}

/* Amendment H on Windows: deferred future releases ride the same IOCP as
 * completions, one kind=-2 message per future (POSIX chains them through the
 * MPSC; the IOCP has no chaining, so one post each). The drain decrefs on the
 * loop thread, serializing with the drain's own decref. */
void msCompletionQueuePushReleaseBatch(void** futs, int count) {
	if (count <= 0) return;
	HANDLE iocp = gDispatcher != NULL ? gDispatcher->iocp : NULL;
	if (iocp == NULL) iocp = msFirstLoopIocp();
	if (iocp == NULL) {
		/* No loop exists yet — single-threaded process, inline decref is safe. */
		for (int i = 0; i < count; i++) msFutureDrcDestroy(futs[i]);
		return;
	}
	for (int i = 0; i < count; i++) {
		if (futs[i] == NULL) continue;
		msCompletionMsg* msg = (msCompletionMsg*)malloc(sizeof(msCompletionMsg));
		if (msg == NULL) { msFutureDrcDestroy(futs[i]); continue; }
		msg->fut = NULL;
		msg->value = futs[i];
		msg->isFail = false;
		msg->error = NULL;
		msg->kind = -2;
		PostQueuedCompletionStatus(iocp, 0, 0, (LPOVERLAPPED)msg);
	}
}

bool msCompletionQueueDrain(void) { return false; }

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

void msCompletionQueuePushEnvRelease(void* env) {
    if (env == NULL) return;
    msEnsureWakePipe();
    msMessage* msg = msMsgAlloc(/*kind=*/-3, /*replyFut=*/env);
    msMpscPush(&gCompletionQueue, msg);
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
        if (msg->kind == -3) {
            /* Deferred env release — decref only, no callback.
             * Pushed by spawn workers to avoid cross-thread rc races on closure
             * environments. Processed single-threaded on the dispatcher.
             * TypeInfo.destroyFn handles $up (dollarup_) decref — generated by
             * destructorLifting when $up is typed as Ref<parentEnvType>. */
            if (fut != NULL) {
                const msTypeInfo* __t = msHeader(fut)->type;
                if (msDecRefIsLast(fut)) {
                    MS_DESTROY_DISPATCH(__t, fut);
                    msDestroyAndDispose(fut);
                }
            }
        } else if (msg->kind == -2) {
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
	(void)d; /* timers are process-global here — see gTimers */
	int64_t now = msMonoTimeMs();
	for (;;) {
		msTimerLock();
		if (gTimers.len == 0 || gTimers.data[0].finishAtMs > now) {
			msTimerUnlock();
			break;
		}
		msTimer t = msTimerPop(&gTimers);
		/* Re-arm an interval BEFORE releasing the lock so a callback calling
		 * clearInterval(id) finds the next entry in the heap and can cancel it;
		 * the re-armed entry inherits the env reference, so no extra
		 * incref/release pairs. */
		if (t.periodMs > 0 && !t.cancelled && t.cb.fn != NULL) {
			msTimer next = t;
			next.finishAtMs = now + t.periodMs;
			msTimerPush(&gTimers, next);
		}
		msTimerUnlock();
		*didWork = true;
		/* Everything below runs WITHOUT the lock: a timer callback may arm or
		 * cancel timers, and the spinlock is not reentrant. */
		if (t.fut != NULL) { msFutureCompleteVoid(t.fut); continue; }
		if (t.cancelled || t.cb.fn == NULL) {
			if (t.cb.env != NULL) msPostEnvRelease(t.cb.env);
			continue;
		}
		((void(*)(void*))t.cb.fn)(t.cb.env);
		/* An interval's env rides its re-armed entry; only a one-shot releases. */
		if (t.periodMs == 0 && t.cb.env != NULL) msPostEnvRelease(t.cb.env);
	}
	msTimerLock();
	int64_t nextAt = gTimers.len > 0 ? gTimers.data[0].finishAtMs : -1;
	msTimerUnlock();
	if (nextAt >= 0) {
		int64_t diff = nextAt - now;
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
		/* POSIX parity: its selector poll uses `didWork ? 0 : adj` — zero wait
		 * when this tick already ran work (Step 1b drained actor mailboxes and
		 * completed futures an msWaitFor spinner is polling). Without this,
		 * every poll-style wait pays the full GetQueued timeout AFTER its
		 * future resolved — 15.6ms per iteration at default timer resolution
		 * (probed: actor CALL loop measured 64 it/s vs ~20k it/s with the fix
		 * path; a 100k-iteration CALL program went from ~26 min to ~1 s). */
		DWORD waitMs = didWork ? 0 : (DWORD)(adj >= 0 ? adj : 500);
		BOOL ok = GetQueuedCompletionStatusEx(d->iocp, entries, 64, &count, waitMs, FALSE);
		if (ok) {
			for (ULONG i = 0; i < count; i++) {
				msCompletionMsg* msg = (msCompletionMsg*)entries[i].lpOverlapped;
				/* NULL = a cross-thread wake (msActorWakeEventLoop - the same
				 * Amendment B IOCP-arm primitive msIoEngineWake uses). Nothing
				 * to dispatch; engineIOCP.c's poll skips these identically.
				 * Not counted as work: a wake-only batch leaves the loop free
				 * to re-poll, exactly like POSIX draining wake-pipe bytes
				 * without setting didWork. */
				if (msg == NULL) continue;
				didWork = true;
				if (msg->kind == -3) {
					/* Deferred env release (Amendment H parity with the POSIX
					 * kind=-3 drain): decref on the loop thread — the env's rc
					 * field is non-atomic. Same destroy sequence as the POSIX
					 * branch in msCompletionQueueDrain. */
					void* env = msg->value;
					if (env != NULL) {
						const msTypeInfo* __t = msHeader(env)->type;
						if (msDecRefIsLast(env)) {
							MS_DESTROY_DISPATCH(__t, env);
							msDestroyAndDispose(env);
						}
					}
					free(msg);
					continue;
				}
				if (msg->kind == -2) {
					/* Deferred future release (Amendment H parity with the
					 * POSIX kind=-2 drain): the owner thread's deferred decref
					 * pushed by msCompletionQueuePushReleaseBatch. Runs here,
					 * serialized with the drain's own decref — never racy. */
					if (msg->value != NULL) msFutureDrcDestroy(msg->value);
					free(msg);
					continue;
				}
				if (msg->fut != NULL) {
					msFutureFireCallbacks((msFutureBase*)msg->fut);
					/* Release the queue's in-flight ref, paired with the incref in
					 * msPostCompletion - same contract as the POSIX drain above. */
					msFutureDrcDestroy(msg->fut);
				}
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
	/* Re-increment ONLY if the decrement took — see msPoolBusyDec (pool.c). */
	bool dec = worker && msPoolBusyDec();
	while (!atomic_load_explicit(&fut->finished, memory_order_acquire)) {
		if (msPoolHelpOne()) continue;
		if (!worker) {
			msRunOnce(MS_ACTIVE_WAIT_MS);
		} else {
			msWorkerWaitOnFuture(fp);
		}
	}
	if (dec) msPoolBusyInc();  /* back to own work */
	return msFutureRead(fp);
}

void msWaitForReady(void* fp) {
	msFutureBase* fut = (msFutureBase*)fp;
	bool worker = msIsWorkerWait();
	if (!worker) msGetDispatcher(); /* ensure event loop exists on main thread */
	bool dec = worker && msPoolBusyDec();  /* see msWaitFor */
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
	if (dec) msPoolBusyInc();  /* back to own work */
}

/* Standard reference runForever pattern */
void msRunForever(void) {
	while (1) {
		msPoll(500);
	}
}

/* Post completion from pool thread to event loop. Thread-safe.
 * POSIX: MPSC queue push (lock-free, Pony parity).
 * Windows: PostQueuedCompletionStatus to IOCP (native MPSC).
 * Core: takeRef=true takes the queue-side in-flight ref (public Push
 * contract, both platforms); takeRef=false relies on the owner-thread
 * submit ref (Amendment G Owned path — Windows IOCP only). The forward
 * declaration lives OUTSIDE any #ifdef so the POSIX build sees it before
 * the definition (static-after-use is an error there). */
static void msPostCompletionCore(void* fut, void* value, bool isFail, void* error, bool takeRef);

void msPostCompletion(void* fut, void* value, bool isFail, void* error) {
	msPostCompletionCore(fut, value, isFail, error, true);
}

static void msPostCompletionCore(void* fut, void* value, bool isFail, void* error, bool takeRef) {
#ifdef _WIN32
	HANDLE iocp = gDispatcher != NULL ? gDispatcher->iocp : NULL;
	if (iocp == NULL) {
		/* This thread owns no dispatcher — a pool worker (dual-path wait:
		 * workers park on condvars, never create one). POSIX pushes to the
		 * process-global MPSC that the event loop drains; the IOCP mirror is
		 * the loop's own port, registry entry 0 — the scheduler-0 main loop in
		 * every PARALOCK topology. Completing inline here instead (the old
		 * fallback) calls msFutureComplete/msFutureFail, which hit the
		 * finished-guard the worker's Step-1 publish already set: callbacks
		 * never fire and async steppers hang — exactly the Amendment A / I15
		 * violation the drain path exists to prevent. Route to the loop so
		 * the drain — the one place that fires via msFutureFireCallbacks —
		 * runs them. */
		iocp = msFirstLoopIocp();
	}
	if (iocp != NULL) {
		msCompletionMsg* msg = (msCompletionMsg*)malloc(sizeof(msCompletionMsg));
		if (msg == NULL) {
			/* No message to hand the loop — complete inline rather than
			 * dereference NULL, matching the no-dispatcher branch below. */
			if (isFail) msFutureFail(fut, error);
			else msFutureComplete(fut, value);
			return;
		}
		/* Queue-side in-flight ref, same contract as the POSIX
		 * msCompletionQueuePush incref: PostQueuedCompletionStatus is
		 * asynchronous — the dispatcher pops this message in a later msRunOnce
		 * turn, and without a ref the future could be freed while this raw
		 * pointer is still in flight. Released by the IOCP drain in msRunOnce
		 * right after msFutureFireCallbacks.
		 *
		 * takeRef=false ONLY for the Owned path (msCompletionQueuePushOwned,
		 * called by spawn workers): with MS_FUTURE_SUBMIT_REF=1 the
		 * owner-thread submit incref (Amendment G) already holds the future
		 * across publish and post — a second ref here would double-count
		 * against the drain's single release. The incref must also not run on
		 * the worker for the same reason the release must not: rc is
		 * non-atomic and the owner thread decrefs concurrently. */
		if (takeRef && fut != NULL) msIncRef(fut);
		msg->fut = fut;
		msg->value = value;
		msg->isFail = isFail;
		msg->error = error;
		msg->kind = 0;
		PostQueuedCompletionStatus(iocp, 0, 0, (LPOVERLAPPED)msg);
	} else {
		if (isFail) msFutureFail(fut, error);
		else msFutureComplete(fut, value);
	}
#else
	(void)takeRef; /* POSIX increfs inside msCompletionQueuePush */
	msCompletionQueuePush(fut, isFail, error);
#endif
}

/* Amendment H (Windows mirror of msCompletionQueuePushEnvRelease): deferred
 * closure-env release. Spawn workers must not decref the closure env on their
 * own thread — the env's rc field is non-atomic and races the owning thread's
 * own decref (observed as heap corruption 0xC0000374 after a few thousand
 * struct spawns). POSIX routes the release through the completion queue so it
 * runs single-threaded on the dispatcher drain; post the same kind=-3 message
 * through the IOCP here. POSIX keeps its native queue path. */
#ifdef _WIN32
void msPostEnvRelease(void* env) {
	HANDLE iocp = gDispatcher != NULL ? gDispatcher->iocp : NULL;
	if (iocp == NULL) iocp = msFirstLoopIocp();
	if (iocp == NULL) {
		/* No loop exists yet — the process is effectively single-threaded at
		 * this point, so an inline decref is race-free. */
		msDecref(env);
		return;
	}
	msCompletionMsg* msg = (msCompletionMsg*)malloc(sizeof(msCompletionMsg));
	if (msg == NULL) { msDecref(env); return; }
	msg->fut = NULL;
	msg->value = env;
	msg->isFail = false;
	msg->error = NULL;
	msg->kind = -3;
	PostQueuedCompletionStatus(iocp, 0, 0, (LPOVERLAPPED)msg);
}
#else
void msPostEnvRelease(void* env) {
	msCompletionQueuePushEnvRelease(env);
}
#endif

/* Arm one timer on the process-global heap.
 *
 * A non-worker caller also ENSURES the loop exists: it is the thread that will
 * run it, and the exit drain bails out early when the calling thread owns no
 * dispatcher (msDrainUntilIdle's msHasDispatcher guard), so a top-level
 * `await sleepAsync(...)` needs the dispatcher created here as before.
 *
 * A pool worker must NOT create one — a worker-local dispatcher registers a
 * port nobody drains (the 2026-09-05 spawn-inside-actor hang). It arms onto the
 * shared heap and wakes the loop instead, so the loop recomputes its poll
 * timeout against a deadline that may now be sooner than the one it slept on. */
static void msTimerArm(msTimer t) {
	bool worker = msIsPoolWorker;
	if (!worker) (void)msGetDispatcher();
	msTimerLock();
	msTimerPush(&gTimers, t);
	msTimerUnlock();
	if (worker) msActorWakeEventLoop();
}

/* Standard reference sleepAsync pattern
 * Create timer future, push to heap, return future */
msFuture_void* msSleepAsync(int ms) {
	msFuture_void* fut = msFutureCreateT(msFuture_void);
	int64_t finishAt = msMonoTimeMs() + ms;
	msTimer t = { .finishAtMs = finishAt, .fut = fut };
	msTimerArm(t);
	return fut;
}

/* ===== setTimeout / setInterval =====
 * The callback outlives the call that scheduled it, so the closure's env is
 * retained here and released once the timer can no longer fire. Cancellation is
 * lazy: the entry stays on the heap and is skipped (and its env released) when
 * it comes due — cheaper than an O(n) heap removal for a rare operation. */
static _Atomic(int64_t) gTimerSeq = 0;

static int64_t msArmTimer(msClosure cb, double ms, int64_t periodMs) {
	if (cb.env != NULL) msIncRef(cb.env);
	/* The id counter is shared now that any thread can arm; a plain increment
	 * would hand two threads the same id and let one clearTimeout cancel the
	 * other's timer. */
	int64_t id = (int64_t)atomic_fetch_add_explicit(&gTimerSeq, 1, memory_order_relaxed) + 1;
	int64_t delay = (int64_t)ms;
	if (delay < 0) delay = 0;
	msTimer t = {
		.finishAtMs = msMonoTimeMs() + delay,
		.fut = NULL,
		.cb = cb,
		.id = id,
		.periodMs = periodMs,
		.cancelled = false,
	};
	msTimerArm(t);
	return id;
}

static void msCancelTimer(int64_t id) {
	msTimerLock();
	for (int i = 0; i < gTimers.len; i += 1) {
		if (gTimers.data[i].id == id) {
			gTimers.data[i].cancelled = true;
			gTimers.data[i].periodMs = 0;
			break;
		}
	}
	msTimerUnlock();
}

double msSetTimeout(msClosure cb, double ms) { return (double)msArmTimer(cb, ms, 0); }

double msSetInterval(msClosure cb, double ms) {
	int64_t period = (int64_t)ms;
	if (period < 1) period = 1;
	return (double)msArmTimer(cb, ms, period);
}

void msClearTimeout(double id) { msCancelTimer((int64_t)id); }

void msClearInterval(double id) { msCancelTimer((int64_t)id); }

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
	 * Worker threads: skip dispatcher creation — on Windows too. A worker-local
	 * dispatcher is NOT acceptable: it registers the worker's own IOCP in the wake
	 * registry, and msPostCompletionCore then routes that worker's completions to
	 * the worker's port — which no thread ever drains (workers never run msRunOnce).
	 * The steppers riding those completions never fire, and a spawn-inside-actor
	 * program hangs with its actor suspended forever (proven 2026-09-05: the
	 * probabilistic spawn-inside-actor hang, Windows-only, was exactly this —
	 * workers steal actor visits and dispatch async methods, minting dead ports).
	 * Workers rely on inline callback execution (msCallSoonProc == NULL → msCallSoon
	 * fires immediately) and msFirstLoopIocp() for completion routing, like POSIX. */
	bool isWorker = false;
	{ extern _Thread_local bool msIsPoolWorker; isWorker = msIsPoolWorker; }
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
	/* Cancel all pending timers. The heap is process-global (see gTimers) and is
	 * torn down here unconditionally — the same treatment the other two
	 * process-global resources in this function get (gWakePipe, gCompletionQueue
	 * below). Under the lock, so a pool worker arming concurrently either lands
	 * its timer before the drain or finds a NULL heap after it, never a half-freed
	 * one. */
	msTimerLock();
	while (gTimers.len > 0) {
		msTimer t = msTimerPop(&gTimers);
		if (t.fut != NULL) msFutureCancel(t.fut);
		else if (t.cb.env != NULL) msDecref(t.cb.env);
	}
	free(gTimers.data);
	gTimers.data = NULL;
	gTimers.cap = 0;
	msTimerUnlock();
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
