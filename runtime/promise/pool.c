#if defined(MSOS_WASM) || defined(MSOS_EMCC)
#include "runtime/core/system.h"
#include "runtime/promise/pool.h"

/* No worker thread exists on this target: every spawn runs on the spawning thread, so its
 * future is complete before anything awaits it and nothing ever helps or waits on a pool. */
_Thread_local bool msIsPoolWorker = false;
_Thread_local int msPoolWorkerSchedId = 0;
MS_TLS_PUBLISH(msIsPoolWorker)

void msPoolSubmit(struct msSpawnCtx* ctx) { msSpawnWorkerRun(ctx); }
bool msPoolRunEdge(const void* awaited, bool follow, bool descend) { (void)awaited; (void)follow; (void)descend; return false; }
bool msPoolCompensate(const void* awaited, const char* wait) { (void)awaited; (void)wait; return false; }
void msPoolCompensateEnd(void) {}
const msTaskFrame* msPoolFrameSwap(const msTaskFrame* frame) { (void)frame; return NULL; }
int32_t msPoolRunningPeek(void) { return 0; }
int32_t msPoolSparesPeek(void) { return 0; }
void msPoolUnwound(int32_t running, int32_t spares, void* error) { (void)running; (void)spares; (void)error; }
void msFutureEdgeAll(void* result, void* const* inputs, int32_t count) { (void)result; (void)inputs; (void)count; }
void msFutureEdgeSettle(void* result, int32_t index) { (void)result; (void)index; }
void msFutureEdgeAwait(void* retFut, void* awaited) { (void)retFut; (void)awaited; }
bool msPoolBusyDec(void) { return false; }
void msPoolBusyInc(void) {}
int32_t msPoolPendingPeek(void) { return 0; }
void msPoolPendingAdd(int32_t delta) { (void)delta; }

#elif !defined(MSOS_BARE)
/*
 * MetaScript Thread Pool — Malebolgia-style fixed worker pool
 *
 * Fixed N worker threads (auto-detected CPU count).
 * Circular buffer task queue with mutex + 2 condition variables.
 * Workers sleep when queue is empty, wake on signal.
 * Backpressure: submitter waits if queue is full (Malebolgia parity).
 * Local execution: if all workers busy, caller runs task inline.
 *
 * POSIX: pthreads (macOS/Linux — zero-cost, part of libc).
 * Windows: native Win32 threading (CreateThread, CRITICAL_SECTION, CONDITION_VARIABLE).
 */
#include "runtime/core/system.h"  /* pulls in thread.h + msDecref + msCurrException */
#include "runtime/promise/pool.h"
#include "runtime/io/engine.h"  /* msIoEngine, msIoEngineWake — Amendment B targeted wake */
#include "runtime/promise/locked.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>

/* ===== Platform Abstraction Macros ===== */

/* Count trailing zeros (find first set bit in idle bitmask) */
#ifdef _WIN32
#include <intrin.h>
static inline int msCtz64(uint64_t x) { unsigned long idx; _BitScanForward64(&idx, x); return (int)idx; }
#else
#define msCtz64(x) __builtin_ctzll(x)
#endif

#ifdef _WIN32

#define MS_LOCK(pool)       EnterCriticalSection(&(pool)->cs)
#define MS_UNLOCK(pool)     LeaveCriticalSection(&(pool)->cs)
#define MS_WAIT(cv, pool)   SleepConditionVariableCS(&(cv), &(pool)->cs, INFINITE)
#define MS_WAIT_MS(cv, pool, ms) SleepConditionVariableCS(&(cv), &(pool)->cs, (DWORD)(ms))
#define MS_SIGNAL(cv)       WakeConditionVariable(&(cv))
#define MS_BROADCAST(cv)    WakeAllConditionVariable(&(cv))

#else

#include <unistd.h>
#define MS_LOCK(pool)       pthread_mutex_lock(&(pool)->mutex)
#define MS_UNLOCK(pool)     pthread_mutex_unlock(&(pool)->mutex)
#define MS_WAIT(cv, pool)   pthread_cond_wait(&(cv), &(pool)->mutex)
#define MS_WAIT_MS(cv, pool, ms) msCondWaitMs(&(cv), &(pool)->mutex, (ms))
static void msCondWaitMs(pthread_cond_t* cv, pthread_mutex_t* m, int ms) {
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	ts.tv_sec += ms / 1000;
	ts.tv_nsec += (long)(ms % 1000) * 1000000L;
	if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
	pthread_cond_timedwait(cv, m, &ts);
}
#define MS_SIGNAL(cv)       pthread_cond_signal(&(cv))
#define MS_BROADCAST(cv)    pthread_cond_broadcast(&(cv))

#endif

#define MS_POOL_MAX_QUEUE 256  /* max queue size before backpressure kicks in */

/* Atomic busyCount + workerCount for lock-free shouldSend (Malebolgia parity).
 * Checked BEFORE acquiring pool mutex — avoids lock overhead on inline path. */
static _Atomic(int32_t) msPoolBusyCount = 0;
static int32_t msPoolWorkerCount = 0;

static _Atomic(int32_t) msPoolPendingCount = 0;

int32_t msPoolPendingPeek(void) {
	return atomic_load_explicit(&msPoolPendingCount, memory_order_acquire);
}

void msPoolPendingAdd(int32_t delta) {
	atomic_fetch_add_explicit(&msPoolPendingCount, delta, memory_order_acq_rel);
}

/* Thread-local: true when current thread is a pool worker executing a task.
 * Used by shouldSend: only inline when caller is already a worker (recursive spawn).
 * Main thread always queues to ensure initial fan-out reaches workers.
 * Matches Malebolgia's activeProducer flag. */
_Thread_local bool msIsPoolWorker = false;
_Thread_local int msPoolWorkerSchedId = 0;
MS_TLS_PUBLISH(msIsPoolWorker)

/* ===== CPU Detection ===== */

static int msDetectCPUs(void) {
#ifdef _WIN32
	SYSTEM_INFO si;
	GetSystemInfo(&si);
	return si.dwNumberOfProcessors > 0 ? (int)si.dwNumberOfProcessors : 4;
#elif defined(_SC_NPROCESSORS_ONLN)
	int n = (int)sysconf(_SC_NPROCESSORS_ONLN);
	return n > 0 ? n : 4;
#else
	return 4; /* fallback */
#endif
}

/* ===== Queue Length (must hold lock) ===== */

static inline int msPoolQueueLen(msThreadPool* pool) {
	return (pool->tail - pool->head + pool->cap) % pool->cap;
}

/* A waiter that runs a queued task marks its slot claimed and leaves it in place. */
static inline void msPoolSkipClaimed(msThreadPool* pool) {
	while (pool->head != pool->tail && pool->queue[pool->head].claimed) {
		pool->head = (pool->head + 1) % pool->cap;
	}
}

static inline bool msPoolHasUnclaimed(msThreadPool* pool) {
	for (int i = pool->head; i != pool->tail; i = (i + 1) % pool->cap) {
		if (!pool->queue[i].claimed) return true;
	}
	return false;
}

/* Threads past workerCount are spares: started by a waiter that would park while
 * tasks stay queued, retired once the waiters that asked for them resume. A retired
 * spare keeps serving its own loop channel, so it parks instead of exiting. */
enum { MS_THREAD_WORKER = 0, MS_THREAD_SPARE = 1, MS_THREAD_RETIRED = 2 };
static uint8_t msPoolThreadState[MS_POOL_MAX_WORKERS];  /* under the pool lock */
static _Atomic(int) msPoolThreadCount = 0;
static int msPoolSparesActive = 0;  /* under the pool lock */
static int msPoolSparesWanted = 0;  /* under the pool lock */
static msThreadPool* gPool = NULL;

/* ===== Actor polling from worker threads (Phase 5: Parallel Actors) =====
 * Pool doesn't include actor.h to avoid static-in-header duplication.
 * Instead, actor.h registers a poll function + scheduler ID setter via hooks. */

/* Set once by the first actor, possibly while workers already run: atomic, the setter
 * published before the poll function a worker checks first. */
typedef bool (*msPoolActorPollHook)(void);
typedef void (*msPoolSchedIdHook)(int id);
/* Actor poll hook: called by workers to drain their local actor queues */
static _Atomic(msPoolActorPollHook) msPoolActorPollFn = NULL;

/* Scheduler ID setter: called once per worker to assign scheduler ID */
static _Atomic(msPoolSchedIdHook) msPoolSchedIdSetterFn = NULL;


/* Per-worker actor wake flag: set by msPoolWakeWorker, checked in sleep predicate.
 * Prevents lost-wake race: if the condvar signal arrives while the worker is
 * still running (between poll return and entering wait), the signal is lost.
 * The flag survives across the race window and prevents the worker from sleeping. */
static _Atomic(bool) msPoolActorWake[MS_POOL_MAX_WORKERS] = {false};

/* Called by actor.h to register the poll + ID setter functions */
void msPoolSetActorHooks(bool (*pollFn)(void), void (*idSetterFn)(int)) {
    atomic_store_explicit(&msPoolSchedIdSetterFn, idSetterFn, memory_order_release);
    atomic_store_explicit(&msPoolActorPollFn, pollFn, memory_order_release);
}

static _Thread_local void (**msThreadDestructionFns)(void) = NULL;
static _Thread_local int32_t msThreadDestructionLen = 0;
static _Thread_local int32_t msThreadDestructionCap = 0;

void msOnThreadDestruction(void (*handler)(void)) {
    if (msThreadDestructionLen == msThreadDestructionCap) {
        int32_t cap = msThreadDestructionCap == 0 ? 4 : msThreadDestructionCap * 2;
        void (**fns)(void) = realloc(msThreadDestructionFns, (size_t)cap * sizeof(*fns));
        if (fns == NULL) {
            fprintf(stderr, "msOnThreadDestruction: out of memory for %d handlers\n", cap);
            abort();
        }
        msThreadDestructionFns = fns;
        msThreadDestructionCap = cap;
    }
    msThreadDestructionFns[msThreadDestructionLen++] = handler;
}

static _Thread_local struct msSpawnCtx* msPoolRuns = NULL;
static _Thread_local int32_t msPoolRunsCap = 0;

static void msAfterThreadRuns(void) {
    for (int32_t i = msThreadDestructionLen - 1; i >= 0; i--) msThreadDestructionFns[i]();
    msRootsThreadTeardown();
    free(msPoolRuns);
    msPoolRuns = NULL;
    msPoolRunsCap = 0;
    free(msThreadDestructionFns);
    msThreadDestructionFns = NULL;
    msThreadDestructionLen = 0;
    msThreadDestructionCap = 0;
}

static _Thread_local const msTaskFrame* msPoolFrame = NULL;
static _Thread_local int32_t msPoolRunning = 0;
static _Thread_local int32_t msPoolSpares = 0;

const msTaskFrame* msPoolFrameSwap(const msTaskFrame* frame) {
	const msTaskFrame* outer = msPoolFrame;
	msPoolFrame = frame;
	return outer;
}

int32_t msPoolRunningPeek(void) { return msPoolRunning; }
int32_t msPoolSparesPeek(void) { return msPoolSpares; }

void msPoolUnwound(int32_t running, int32_t spares, void* error) {
	while (msPoolSpares > spares) msPoolCompensateEnd();
	while (msPoolRunning > running) {
		struct msSpawnCtx* task = &msPoolRuns[--msPoolRunning];
		/* The fault that unwound it is already reported: no unhandled rejection at exit. */
		if (task->slotGroup == NULL && task->group == NULL) atomic_store_explicit(&((msFutureBase*)task->fut)->errorObserved, true, memory_order_relaxed);
		msIncRef(error);
		msCurrException = (msException*)error;
		msErr = true;
		msSpawnWorkerSettle(task, NULL);
		atomic_fetch_sub_explicit(&msPoolPendingCount, 1, memory_order_release);
	}
}

/* Decrement only after the run: the run posts the task's completion, which the exit
 * drain must be able to see once the count it reads reaches 0. */
static void msPoolRunQueued(struct msSpawnCtx* task) {
	msTaskFrame frame = {
		task->fut != NULL ? task->fut : task->slotGroup != NULL ? task->slotGroup : (const void*)task->group,
		task->parent,
	};
	const msTaskFrame* outer = msPoolFrame;
	msPoolFrame = &frame;
	if (msPoolRunning == msPoolRunsCap) {
		msPoolRunsCap = msPoolRunsCap == 0 ? 8 : msPoolRunsCap * 2;
		msPoolRuns = (struct msSpawnCtx*)realloc(msPoolRuns, (size_t)msPoolRunsCap * sizeof(struct msSpawnCtx));
		if (msPoolRuns == NULL) {
			fprintf(stderr, "msPoolRunQueued: out of memory for %d running tasks\n", msPoolRunsCap);
			abort();
		}
	}
	msPoolRuns[msPoolRunning++] = *task;
	msSpawnWorkerRun(task);
	msPoolRunning--;
	msPoolFrame = outer;
	atomic_fetch_sub_explicit(&msPoolPendingCount, 1, memory_order_release);
}

/* ===== Worker Loop ===== */

#ifdef _WIN32
static DWORD WINAPI msPoolWorkerLoop(LPVOID arg) {
#else
static void* msPoolWorkerLoop(void* arg) {
#endif
	msThreadPool* pool = gPool;
	int myWorkerIdx = (int)((intptr_t)arg >> 1);  /* index into workerConds[] */
	int mySchedID = myWorkerIdx + 1;              /* workers are 1..N, main thread is 0 */
	bool spare = ((intptr_t)arg & 1) != 0;
	msIsPoolWorker = true;
	msPoolWorkerSchedId = mySchedID;
	/* A spare takes no actor: its id stays past msSchedulerCount. */
	msPoolSchedIdHook setSchedId = atomic_load_explicit(&msPoolSchedIdSetterFn, memory_order_acquire);
	if (!spare && setSchedId != NULL) setSchedId(mySchedID);

	extern int msWorkerTimerDelayMs(void);
	extern bool msWorkerLoopPending(void);
	while (1) {
		int timerMs = msWorkerTimerDelayMs();
		MS_LOCK(pool);
		if (spare && msPoolThreadState[myWorkerIdx] == MS_THREAD_SPARE && msPoolSparesActive > msPoolSparesWanted) {
			msPoolThreadState[myWorkerIdx] = MS_THREAD_RETIRED;
			msPoolSparesActive--;
		}
		bool retired = spare && msPoolThreadState[myWorkerIdx] == MS_THREAD_RETIRED;
		msPoolSkipClaimed(pool);
		/* Wait on OWN condvar — targeted wake, no spurious wakeups.
		 * Check spawn queue AND actor wake flag: prevents lost-wake race where
		 * msPoolWakeWorker signals while we're still running (signal lost). */
		if ((retired || pool->head == pool->tail) &&
			!atomic_load_explicit(&msPoolActorWake[myWorkerIdx], memory_order_acquire) &&
			!msWorkerLoopPending() &&
			!pool->shutdown) {
			if (!retired) atomic_fetch_or_explicit(&pool->idleMask, (uint64_t)1 << myWorkerIdx, memory_order_release);
			if (timerMs >= 0) MS_WAIT_MS(pool->workerConds[myWorkerIdx], pool, timerMs);
			else MS_WAIT(pool->workerConds[myWorkerIdx], pool);
			if (!retired) atomic_fetch_and_explicit(&pool->idleMask, ~((uint64_t)1 << myWorkerIdx), memory_order_acquire);
		}
		/* Clear actor wake flag after waking (inside lock, before poll) */
		atomic_store_explicit(&msPoolActorWake[myWorkerIdx], false, memory_order_relaxed);
		retired = spare && msPoolThreadState[myWorkerIdx] == MS_THREAD_RETIRED;
		msPoolSkipClaimed(pool);
		/* Check shutdown with empty queue — exit cleanly */
		if (pool->shutdown && (retired || pool->head == pool->tail)) {
			MS_UNLOCK(pool);
			/* Amendment H: final TLS flush before worker exit — any deferred
			 * releases accumulated during the last task must be pushed to the
			 * MPSC queue so msPoolShutdown's final drain can process them.
			 * Without this, the entries leak (LSan catches it on Linux). */
			msFutureReleaseFlush();
			msAfterThreadRuns();
			break;
		}
		/* Dequeue spawn task if available — copy struct out (Malebolgia: zero alloc) */
		struct msSpawnCtx item = {0};
		bool hasTask = false;
		if (!retired && pool->head != pool->tail) {
			item = pool->queue[pool->head];
			pool->head = (pool->head + 1) % pool->cap;
			msPoolSkipClaimed(pool);
			pool->busyCount++;
			atomic_fetch_add_explicit(&msPoolBusyCount, 1, memory_order_relaxed);
			hasTask = true;
			MS_SIGNAL(pool->space);
			/* Chain-wake: if more tasks in queue, wake next idle worker.
			 * Rapid submits may signal the same worker (idle bit not cleared
			 * fast enough). Chain-wake ensures each queued task gets a worker. */
			if (pool->head != pool->tail) {
				uint64_t idle = atomic_load_explicit(&pool->idleMask, memory_order_acquire);
				if (idle != 0) {
					int wake = msCtz64(idle);
					MS_SIGNAL(pool->workerConds[wake]);
				}
			}
		}
		MS_UNLOCK(pool);

		/* Execute spawn task from local copy (queue slot is now free) */
		if (hasTask) {
			msPoolRunQueued(&item);
			MS_LOCK(pool);
			pool->busyCount--;
			atomic_fetch_sub_explicit(&msPoolBusyCount, 1, memory_order_relaxed);
			MS_UNLOCK(pool);
			msFutureReleaseFlush();
		}
		extern bool msWorkerLoopPump(void);
		if (msWorkerLoopPump()) continue;

		/* Poll local actors (opportunistic between spawn tasks).
		 * If actor work was found, loop back immediately to check for more
		 * (actor re-enqueue may have added new work during processing). */
		msPoolActorPollHook poll = spare ? NULL : atomic_load_explicit(&msPoolActorPollFn, memory_order_acquire);
		if (poll != NULL) {
			atomic_load_explicit(&msPoolSchedIdSetterFn, memory_order_relaxed)(mySchedID);
			atomic_fetch_add_explicit(&msPoolPendingCount, 1, memory_order_relaxed);
			bool polled = poll();
			atomic_fetch_sub_explicit(&msPoolPendingCount, 1, memory_order_release);
			if (polled) continue;
		}
	}
#ifdef _WIN32
	return 0;
#else
	return NULL;
#endif
}

/* ===== Per-scheduler targeted wake registry (PARALOCK Amendment B / I16) ===== */
/* A serve loop parks in its I/O engine poll, not the pool condvar, so a cross-thread
 * actor send must also break that scheduler's engine poll. The serve thread publishes
 * its engine here (via msIoEngineAddWakeFd); msPoolWakeWorker routes the wake through
 * msIoEngineWake — backend-specific, so it works on every poll mechanism.
 * Atomic: published on the serve thread, read on the sender thread. */
#define MS_SCHED_WAKE_MAX 64  /* = MS_MAX_SCHEDULERS (runtime/actor/actor.h) */
static _Atomic(msIoEngine*) gSchedWakeEngine[MS_SCHED_WAKE_MAX];

void msSchedWakeRegister(int sid, msIoEngine* e) {
	if (sid >= 0 && sid < MS_SCHED_WAKE_MAX)
		atomic_store_explicit(&gSchedWakeEngine[sid], e, memory_order_release);
}

void msSchedWakeUnregisterEngine(msIoEngine* e) {
	for (int i = 0; i < MS_SCHED_WAKE_MAX; i++) {
		if (atomic_load_explicit(&gSchedWakeEngine[i], memory_order_acquire) == e)
			atomic_store_explicit(&gSchedWakeEngine[i], NULL, memory_order_release);
	}
}

/* Wake a specific worker by scheduler ID (targeted: actors signal only their owner) */
void msPoolWakeWorker(int schedulerID) {
	msThreadPool* pool = msPoolGet();
	if (pool == NULL) return;
	int idx = schedulerID - 1;  /* scheduler 1 → workerConds[0] */
	if (idx < 0 || idx >= atomic_load_explicit(&msPoolThreadCount, memory_order_acquire)) return;
	/* Set wake flag BEFORE signaling — survives if worker hasn't entered wait yet */
	atomic_store_explicit(&msPoolActorWake[idx], true, memory_order_release);
	MS_LOCK(pool);
	MS_SIGNAL(pool->workerConds[idx]);
	MS_UNLOCK(pool);
	/* Amendment B: a serve-loop worker parks in its I/O engine poll, where the condvar
	 * above is invisible — also break this scheduler's registered engine poll. Targeted
	 * (only this sid), self-clearing, no herd. NULL when the scheduler isn't running
	 * a serve loop (pure pool worker → condvar above already woke it). */
	if (schedulerID >= 0 && schedulerID < MS_SCHED_WAKE_MAX) {
		msIoEngine* e = atomic_load_explicit(&gSchedWakeEngine[schedulerID], memory_order_acquire);
		if (e != NULL) msIoEngineWake(e);
	}
}

/* Wake all pool workers (shutdown, fallback) */
void msPoolWakeWorkers(void) {
	msThreadPool* pool = msPoolGet();
	if (pool == NULL) return;
	MS_LOCK(pool);
	int count = atomic_load_explicit(&msPoolThreadCount, memory_order_relaxed);
	for (int i = 0; i < count; i++) {
		MS_SIGNAL(pool->workerConds[i]);
	}
	MS_UNLOCK(pool);
}

/* ===== Singleton Init ===== */

#ifdef _WIN32
static LONG gPoolInitFlag = 0;
#else
static pthread_once_t gPoolOnce = PTHREAD_ONCE_INIT;
#endif

static bool msPoolStartThread(msThreadPool* pool, int idx, bool spare) {
	intptr_t start = ((intptr_t)idx << 1) | (spare ? 1 : 0);
#ifdef _WIN32
	pool->workers[idx] = CreateThread(NULL, 0, msPoolWorkerLoop, (LPVOID)start, 0, NULL);
	return pool->workers[idx] != NULL;
#else
	/* 4MB stack per worker — inline fallback (shouldSend) can create deep
	 * recursion chains (fib: spawn→submit→inline→fib→spawn...). Default
	 * 512KB overflows at moderate depth. Matches Malebolgia's assumption
	 * that workers run user code with recursive spawn patterns. */
	pthread_attr_t attr;
	pthread_attr_init(&attr);
	pthread_attr_setstacksize(&attr, 4 * 1024 * 1024);
	bool ok = pthread_create(&pool->workers[idx], &attr, msPoolWorkerLoop, (void*)start) == 0;
	pthread_attr_destroy(&attr);
	return ok;
#endif
}

static void msPoolInit(void) {
	gPool = (msThreadPool*)calloc(1, sizeof(msThreadPool));
	int cpus = msDetectCPUs();
	gPool->workerCount = cpus < MS_POOL_MAX_WORKERS ? cpus : MS_POOL_MAX_WORKERS;
	gPool->cap = MS_POOL_MAX_QUEUE;
	gPool->queue = (msSpawnCtx*)calloc(gPool->cap, sizeof(msSpawnCtx));

#ifdef _WIN32
	InitializeCriticalSection(&gPool->cs);
	for (int i = 0; i < MS_POOL_MAX_WORKERS; i++) {
		InitializeConditionVariable(&gPool->workerConds[i]);
	}
	InitializeConditionVariable(&gPool->space);
	gPool->workers = (HANDLE*)calloc(MS_POOL_MAX_WORKERS, sizeof(HANDLE));
#else
	pthread_mutex_init(&gPool->mutex, NULL);
	for (int i = 0; i < MS_POOL_MAX_WORKERS; i++) {
		pthread_cond_init(&gPool->workerConds[i], NULL);
	}
	pthread_cond_init(&gPool->space, NULL);
	gPool->workers = (pthread_t*)calloc(MS_POOL_MAX_WORKERS, sizeof(pthread_t));
#endif
	int created = 0;
	while (created < gPool->workerCount && msPoolStartThread(gPool, created, false)) created++;
	gPool->workerCount = created;
	msPoolWorkerCount = created;  /* init lock-free shouldSend threshold */
	atomic_store_explicit(&msPoolThreadCount, created, memory_order_release);
	atexit(msPoolShutdown);
}

msThreadPool* msPoolGet(void) {
#ifdef _WIN32
	if (InterlockedCompareExchange(&gPoolInitFlag, 1, 0) == 0) {
		msPoolInit();
		InterlockedExchange(&gPoolInitFlag, 2); /* signal: init complete */
	} else {
		while (InterlockedCompareExchange(&gPoolInitFlag, 2, 2) != 2) {
			Sleep(0); /* yield until init completes */
		}
	}
#else
	pthread_once(&gPoolOnce, msPoolInit);
#endif
	return gPool;
}

/* ===== Submit Task ===== */

void msPoolSubmit(struct msSpawnCtx* ctx) {
	/* Lock-free inline check — Malebolgia's shouldSend parity.
	 * Only inline when caller is a WORKER (recursive spawn inside a task).
	 * Main thread always queues to ensure initial fan-out reaches workers.
	 * This matches Malebolgia's activeProducer: main thread is always a producer. */
	if (msIsPoolWorker &&
	    atomic_load_explicit(&msPoolBusyCount, memory_order_relaxed) >= msPoolWorkerCount) {
		msSpawnWorkerRun(ctx);
		return;
	}

	msThreadPool* pool = msPoolGet();
	MS_LOCK(pool);

	/* Under lock: only check queue capacity and shutdown.
	 * busyCount authority is the lock-free atomic (adjusted by Change 2 dec/inc in wait). */
	if (msPoolQueueLen(pool) >= pool->cap - 1 || pool->shutdown) {
		MS_UNLOCK(pool);
		msSpawnWorkerRun(ctx);
		return;
	}

	/* Enqueue — copy struct into slot (Malebolgia: zero alloc, no pointer) */
	pool->queue[pool->tail] = *ctx;
	/* A held or isolated spawn's future may outlive the task that made it: only a slot
	 * or a group is joined by its parent. */
	pool->queue[pool->tail].parent = ctx->slotGroup != NULL || ctx->group != NULL ? msPoolFrame : NULL;
	pool->tail = (pool->tail + 1) % pool->cap;
	atomic_fetch_add_explicit(&msPoolPendingCount, 1, memory_order_relaxed);
	/* Signal one IDLE worker (find via bitmask — guaranteed to be sleeping) */
	uint64_t idle = atomic_load_explicit(&pool->idleMask, memory_order_acquire);
	if (idle != 0) {
		int wake = msCtz64(idle);  /* first set bit = first idle worker */
		MS_SIGNAL(pool->workerConds[wake]);
	}
	/* If no idle workers, task waits in queue — next worker finishing a task will dequeue it */
	MS_UNLOCK(pool);
}

/* ===== Waits run only what they depend on ===== */

/* Guards every msFutureEdge slot and is held while a waiter walks them: a target
 * stays alive while its slot is set, because its owner drops the target only after
 * clearing the slot under this lock. */
static msTicketLock gEdgeLock = { 0, 0 };

void msFutureEdgeAll(void* result, void* const* inputs, int32_t count) {
	msFutureEdge* e = (msFutureEdge*)malloc(sizeof(msFutureEdge) + (size_t)count * sizeof(void*));
	if (e == NULL) {
		fprintf(stderr, "msFutureEdgeAll: out of memory for %d inputs\n", count);
		abort();
	}
	e->count = count;
	for (int32_t i = 0; i < count; i++) e->to[i] = inputs[i];
	atomic_store_explicit(&((msFutureBase*)result)->edge, e, memory_order_release);
}

void msFutureEdgeSettle(void* result, int32_t index) {
	msFutureEdge* e = atomic_load_explicit(&((msFutureBase*)result)->edge, memory_order_relaxed);
	if (e == NULL) return;
	msTicketLockAcquire(&gEdgeLock);
	e->to[index] = NULL;
	msTicketLockRelease(&gEdgeLock);
}

/* `awaited` NULL: the function resumed. */
void msFutureEdgeAwait(void* retFut, void* awaited) {
	if (retFut == NULL) return;
	msFutureBase* r = (msFutureBase*)retFut;
	msFutureEdge* e = atomic_load_explicit(&r->edge, memory_order_relaxed);
	if (e == NULL) {
		if (awaited == NULL) return;
		e = (msFutureEdge*)malloc(sizeof(msFutureEdge) + sizeof(void*));
		if (e == NULL) {
			fprintf(stderr, "msFutureEdgeAwait: out of memory\n");
			abort();
		}
		e->count = 1;
		e->to[0] = awaited;
		msTicketLockAcquire(&gEdgeLock);
		atomic_store_explicit(&r->edge, e, memory_order_release);
		msTicketLockRelease(&gEdgeLock);
		return;
	}
	msTicketLockAcquire(&gEdgeLock);
	e->to[0] = awaited;
	msTicketLockRelease(&gEdgeLock);
}

#define MS_EDGE_WALK_MAX 64

/* The unsettled futures `root` transitively waits on, root first; under gEdgeLock. */
static int msEdgeCollect(const void** set) {
	int n = 1;
	for (int i = 0; i < n; i++) {
		msFutureEdge* e = atomic_load_explicit(&((msFutureBase*)set[i])->edge, memory_order_acquire);
		if (e == NULL) continue;
		for (int32_t k = 0; k < e->count && n < MS_EDGE_WALK_MAX; k++) {
			void* t = e->to[k];
			if (t == NULL || atomic_load_explicit(&((msFutureBase*)t)->finished, memory_order_acquire)) continue;
			bool seen = false;
			for (int j = 0; j < n && !seen; j++) seen = set[j] == t;
			if (!seen) set[n++] = t;
		}
	}
	return n;
}

#define MS_FRAME_WALK_MAX 16

static inline bool msPoolTaskIn(const struct msSpawnCtx* task, const void** set, int n, bool descend) {
	for (int i = 0; i < n; i++) {
		const void* a = set[i];
		if (task->fut == a || (const void*)task->group == a || task->slotGroup == a) return true;
		if (!descend) continue;
		const msTaskFrame* f = task->parent;
		for (int d = 0; f != NULL && d < MS_FRAME_WALK_MAX; d++, f = f->parent) {
			if (f->target == a) return true;
		}
	}
	return false;
}

bool msPoolRunEdge(const void* awaited, bool follow, bool descend) {
	msThreadPool* pool = msPoolGet();
	const void* set[MS_EDGE_WALK_MAX];
	set[0] = awaited;
	int n = 1;
	bool walk = follow && atomic_load_explicit(&((const msFutureBase*)awaited)->edge, memory_order_acquire) != NULL;
	if (walk) {
		msTicketLockAcquire(&gEdgeLock);
		n = msEdgeCollect(set);
	}
	struct msSpawnCtx task;
	bool found = false;
	MS_LOCK(pool);
	/* Newest first: the deepest task, and a fused await's child is the last submit. */
	for (int i = pool->tail; i != pool->head && !found; ) {
		i = (i - 1 + pool->cap) % pool->cap;
		struct msSpawnCtx* queued = &pool->queue[i];
		if (queued->claimed || !msPoolTaskIn(queued, set, n, descend)) continue;
		task = *queued;
		queued->claimed = true;
		msPoolSkipClaimed(pool);
		found = true;
	}
	MS_UNLOCK(pool);
	if (walk) msTicketLockRelease(&gEdgeLock);
	if (!found) return false;
	msPoolRunQueued(&task);
	return true;
}

/* True when `awaited` may wait on something no queued or running task of its own
 * closure produces: an unsettled future with no edge that no spawn completes (a
 * resolver, an actor reply, a timer, a race), or a closure past the walk bound. */
static bool msEdgeLessLeaf(const void* awaited) {
	const void* set[MS_EDGE_WALK_MAX];
	set[0] = awaited;
	msTicketLockAcquire(&gEdgeLock);
	int n = msEdgeCollect(set);
	bool edgeLess = n == MS_EDGE_WALK_MAX;
	for (int i = 0; i < n && !edgeLess; i++) {
		const msFutureBase* f = (const msFutureBase*)set[i];
		edgeLess = !atomic_load_explicit(&f->finished, memory_order_acquire)
			&& atomic_load_explicit(&f->edge, memory_order_acquire) == NULL && !f->spawned;
	}
	msTicketLockRelease(&gEdgeLock);
	return edgeLess;
}

extern void (*msFatalTrap)(void);
extern void msSleepMs(int ms);

bool msPoolCompensate(const void* awaited, const char* wait) {
	if (atomic_load_explicit(&msPoolBusyCount, memory_order_relaxed) >= msPoolWorkerCount) return false;
	if (!msEdgeLessLeaf(awaited)) return false;
	msThreadPool* pool = msPoolGet();
	MS_LOCK(pool);
	if (!msPoolHasUnclaimed(pool)) {
		MS_UNLOCK(pool);
		return false;
	}
	uint64_t idle = atomic_load_explicit(&pool->idleMask, memory_order_acquire);
	if (idle != 0) {
		MS_SIGNAL(pool->workerConds[msCtz64(idle)]);
		MS_UNLOCK(pool);
		return false;
	}
	int count = atomic_load_explicit(&msPoolThreadCount, memory_order_relaxed);
	for (int i = pool->workerCount; i < count; i++) {
		if (msPoolThreadState[i] != MS_THREAD_RETIRED) continue;
		msPoolThreadState[i] = MS_THREAD_SPARE;
		msPoolSparesActive++;
		msPoolSparesWanted++;
		msPoolSpares++;
		atomic_store_explicit(&msPoolActorWake[i], true, memory_order_release);
		MS_SIGNAL(pool->workerConds[i]);
		MS_UNLOCK(pool);
		return true;
	}
	if (count < MS_POOL_MAX_WORKERS) {
		msPoolThreadState[count] = MS_THREAD_SPARE;
		if (msPoolStartThread(pool, count, true)) {
			atomic_store_explicit(&msPoolThreadCount, count + 1, memory_order_release);
			msPoolSparesActive++;
			msPoolSparesWanted++;
			msPoolSpares++;
			MS_UNLOCK(pool);
			return true;
		}
		msPoolThreadState[count] = MS_THREAD_WORKER;
	}
	MS_UNLOCK(pool);
	/* One report: a second waiter reaching the limit waits for the first to exit. */
	static atomic_flag reported = ATOMIC_FLAG_INIT;
	if (atomic_flag_test_and_set(&reported)) for (;;) msSleepMs(1000);
	fprintf(stderr, "Error: %s blocks while spawned tasks stay queued, and none of the %d pool threads is free to run them (%s)\n",
		wait, count, count < MS_POOL_MAX_WORKERS ? "a thread could not be started" : "thread limit reached");
	if (msFatalTrap != NULL) msFatalTrap();
	/* Not exit(): its pool shutdown joins the threads this wait starves. */
	_exit(1);
}

void msPoolCompensateEnd(void) {
	msThreadPool* pool = msPoolGet();
	msPoolSpares--;
	MS_LOCK(pool);
	msPoolSparesWanted--;
	/* Every idle spare retires at its next turn while more are active than wanted. One
	 * signal per end is not enough: ends that come before the signalled spare runs
	 * would all signal that same spare. */
	if (pool->workerCount < MS_POOL_MAX_WORKERS) {
		for (uint64_t idle = atomic_load_explicit(&pool->idleMask, memory_order_acquire) >> pool->workerCount; idle != 0; idle &= idle - 1) {
			MS_SIGNAL(pool->workerConds[pool->workerCount + msCtz64(idle)]);
		}
	}
	MS_UNLOCK(pool);
}

/* ===== Busy Signaling (for wait paths) ===== */

/* Called when a worker enters a wait loop (msAwaitSlotWait, msWaitForReady).
 * Decrements the atomic busyCount so shouldSend sees available capacity,
 * allowing new spawns to be queued instead of inlined.
 *
 * Returns whether it actually decremented. The decrement SATURATES at 0 —
 * nested help-first wait chains reach it routinely (a waiter helps, the helped
 * task waits, that waiter helps again …) — so a caller that unconditionally
 * re-increments on exit adds a count it never removed, and the counter drifts
 * upward for good, and shouldSend then inlines spawns the idle pool could take.
 * Pair every Dec with an Inc ONLY when this returned true. */
bool msPoolBusyDec(void) {
	int32_t prev = atomic_load_explicit(&msPoolBusyCount, memory_order_relaxed);
	while (prev > 0) {
		if (atomic_compare_exchange_weak_explicit(&msPoolBusyCount, &prev, prev - 1,
				memory_order_relaxed, memory_order_relaxed)) return true;
	}
	return false;
}

void msPoolBusyInc(void) {
	atomic_fetch_add_explicit(&msPoolBusyCount, 1, memory_order_relaxed);
}

/* ===== Shutdown ===== */

void msPoolShutdown(void) {
	if (gPool == NULL || msIsPoolWorker) return;
	MS_LOCK(gPool);
	gPool->shutdown = true;
	int threads = atomic_load_explicit(&msPoolThreadCount, memory_order_relaxed);
	for (int i = 0; i < threads; i++) {
		MS_SIGNAL(gPool->workerConds[i]);
	}
	MS_BROADCAST(gPool->space);
	MS_UNLOCK(gPool);

#ifdef _WIN32
	for (int i = 0; i < threads; i++) {
		if (GetThreadId(gPool->workers[i]) != GetCurrentThreadId()) WaitForSingleObject(gPool->workers[i], INFINITE);
		CloseHandle(gPool->workers[i]);
	}
	free(gPool->workers);
	free(gPool->queue);
	DeleteCriticalSection(&gPool->cs);
#else
	for (int i = 0; i < threads; i++) {
		if (!pthread_equal(gPool->workers[i], pthread_self())) pthread_join(gPool->workers[i], NULL);
	}
	free(gPool->workers);
	free(gPool->queue);
	pthread_mutex_destroy(&gPool->mutex);
	for (int i = 0; i < MS_POOL_MAX_WORKERS; i++) {
		pthread_cond_destroy(&gPool->workerConds[i]);
	}
	pthread_cond_destroy(&gPool->space);
#endif

	/* Amendment H: after workers have exited (each flushed its TLS on the way
	 * out above), flush the dispatcher/main thread's TLS and run a final drain
	 * so any deferred releases still queued are processed before the process
	 * exits. Without this, deferred releases produced after the last msRunOnce
	 * (e.g. array destroy at end of the last loop iteration) leak. LSan on
	 * Linux catches this; macOS ASAN has no LSan by default so it's invisible
	 * there. */
	msFutureReleaseFlush();
	extern bool msCompletionQueueDrainAll(void);
	while (msCompletionQueueDrainAll()) {}
	msOrcCollect();

	free(gPool);
	gPool = NULL;
}

#endif /* MSOS_WASM || MSOS_EMCC, else !MSOS_BARE */
