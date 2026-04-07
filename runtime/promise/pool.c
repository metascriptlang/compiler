#ifndef MS_BARE
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
#define MS_SIGNAL(cv)       WakeConditionVariable(&(cv))
#define MS_BROADCAST(cv)    WakeAllConditionVariable(&(cv))

#else

#include <unistd.h>
#define MS_LOCK(pool)       pthread_mutex_lock(&(pool)->mutex)
#define MS_UNLOCK(pool)     pthread_mutex_unlock(&(pool)->mutex)
#define MS_WAIT(cv, pool)   pthread_cond_wait(&(cv), &(pool)->mutex)
#define MS_SIGNAL(cv)       pthread_cond_signal(&(cv))
#define MS_BROADCAST(cv)    pthread_cond_broadcast(&(cv))

#endif

#define MS_POOL_MAX_QUEUE 256  /* max queue size before backpressure kicks in */

/* Atomic busyCount + workerCount for lock-free shouldSend (Malebolgia parity).
 * Checked BEFORE acquiring pool mutex — avoids lock overhead on inline path. */
static _Atomic(int32_t) msPoolBusyCount = 0;
static int32_t msPoolWorkerCount = 0;

/* Thread-local: true when current thread is a pool worker executing a task.
 * Used by shouldSend: only inline when caller is already a worker (recursive spawn).
 * Main thread always queues to ensure initial fan-out reaches workers.
 * Matches Malebolgia's activeProducer flag. */
_Thread_local bool msIsPoolWorker = false;

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

/* ===== Actor polling from worker threads (Phase 5: Parallel Actors) =====
 * Pool doesn't include actor.h to avoid static-in-header duplication.
 * Instead, actor.h registers a poll function + scheduler ID setter via hooks. */

/* Actor poll hook: called by workers to drain their local actor queues */
static bool (*msPoolActorPollFn)(void) = NULL;

/* Scheduler ID setter: called once per worker to assign scheduler ID */
static void (*msPoolSchedIdSetterFn)(int id) = NULL;

/* Scheduler ID assignment counter (workers get 1..N-1, main thread gets 0) */
static _Atomic(int) msWorkerSchedIdx = 0;

/* Called by actor.h to register the poll + ID setter functions */
void msPoolSetActorHooks(bool (*pollFn)(void), void (*idSetterFn)(int)) {
    msPoolActorPollFn = pollFn;
    msPoolSchedIdSetterFn = idSetterFn;
}

/* ===== Worker Loop ===== */

#ifdef _WIN32
static DWORD WINAPI msPoolWorkerLoop(LPVOID arg) {
#else
static void* msPoolWorkerLoop(void* arg) {
#endif
	msThreadPool* pool = (msThreadPool*)arg;
	msIsPoolWorker = true;
	/* Assign scheduler ID: workers are 1..N-1 (main thread is 0) */
	int mySchedID = atomic_fetch_add(&msWorkerSchedIdx, 1) + 1;
	int myWorkerIdx = mySchedID - 1;  /* 0-based index into workerConds[] */
	if (msPoolSchedIdSetterFn != NULL) msPoolSchedIdSetterFn(mySchedID);

	while (1) {
		MS_LOCK(pool);
		/* Wait on OWN condvar — targeted wake, no spurious wakeups.
		 * Set idle bit so submit can find us. Clear on wake. */
		if (pool->head == pool->tail && !pool->shutdown) {
			atomic_fetch_or_explicit(&pool->idleMask, (uint64_t)1 << myWorkerIdx, memory_order_release);
			MS_WAIT(pool->workerConds[myWorkerIdx], pool);
			atomic_fetch_and_explicit(&pool->idleMask, ~((uint64_t)1 << myWorkerIdx), memory_order_acquire);
		}
		/* Check shutdown with empty queue — exit cleanly */
		if (pool->shutdown && pool->head == pool->tail) {
			MS_UNLOCK(pool);
			break;
		}
		/* Dequeue spawn task if available — copy struct out (Malebolgia: zero alloc) */
		struct msSpawnCtx item = {0};
		bool hasTask = false;
		if (pool->head != pool->tail) {
			item = pool->queue[pool->head];
			pool->head = (pool->head + 1) % pool->cap;
			pool->busyCount++;
			atomic_fetch_add_explicit(&msPoolBusyCount, 1, memory_order_relaxed);
			hasTask = true;
			MS_SIGNAL(pool->space);
		}
		MS_UNLOCK(pool);

		/* Execute spawn task from local copy (queue slot is now free) */
		if (hasTask) {
			msSpawnWorkerRun(&item);
			MS_LOCK(pool);
			pool->busyCount--;
			atomic_fetch_sub_explicit(&msPoolBusyCount, 1, memory_order_relaxed);
			MS_UNLOCK(pool);
		}

		/* Poll local actors (opportunistic between spawn tasks) */
		if (msPoolActorPollFn != NULL) msPoolActorPollFn();
	}
#ifdef _WIN32
	return 0;
#else
	return NULL;
#endif
}

/* Wake a specific worker by scheduler ID (targeted: actors signal only their owner) */
void msPoolWakeWorker(int schedulerID) {
	msThreadPool* pool = msPoolGet();
	if (pool == NULL) return;
	int idx = schedulerID - 1;  /* scheduler 1 → workerConds[0] */
	if (idx < 0 || idx >= pool->workerCount) return;
	MS_LOCK(pool);
	MS_SIGNAL(pool->workerConds[idx]);
	MS_UNLOCK(pool);
}

/* Wake all pool workers (shutdown, fallback) */
void msPoolWakeWorkers(void) {
	msThreadPool* pool = msPoolGet();
	if (pool == NULL) return;
	MS_LOCK(pool);
	for (int i = 0; i < pool->workerCount; i++) {
		MS_SIGNAL(pool->workerConds[i]);
	}
	MS_UNLOCK(pool);
}

/* ===== Singleton Init ===== */

static msThreadPool* gPool = NULL;

#ifdef _WIN32
static LONG gPoolInitFlag = 0;
#else
static pthread_once_t gPoolOnce = PTHREAD_ONCE_INIT;
#endif

static void msPoolInit(void) {
	gPool = (msThreadPool*)calloc(1, sizeof(msThreadPool));
	gPool->workerCount = msDetectCPUs();
	msPoolWorkerCount = gPool->workerCount;  /* init lock-free shouldSend threshold */
	gPool->cap = MS_POOL_MAX_QUEUE;
	gPool->queue = (msSpawnCtx*)calloc(gPool->cap, sizeof(msSpawnCtx));

#ifdef _WIN32
	InitializeCriticalSection(&gPool->cs);
	for (int i = 0; i < gPool->workerCount && i < MS_POOL_MAX_WORKERS; i++) {
		InitializeConditionVariable(&gPool->workerConds[i]);
	}
	InitializeConditionVariable(&gPool->space);
	gPool->workers = (HANDLE*)calloc(gPool->workerCount, sizeof(HANDLE));
	int created = 0;
	for (int i = 0; i < gPool->workerCount; i++) {
		gPool->workers[i] = CreateThread(NULL, 0, msPoolWorkerLoop, gPool, 0, NULL);
		if (gPool->workers[i] != NULL) created++;
	}
#else
	pthread_mutex_init(&gPool->mutex, NULL);
	for (int i = 0; i < gPool->workerCount && i < MS_POOL_MAX_WORKERS; i++) {
		pthread_cond_init(&gPool->workerConds[i], NULL);
	}
	pthread_cond_init(&gPool->space, NULL);
	gPool->workers = (pthread_t*)calloc(gPool->workerCount, sizeof(pthread_t));
	/* 4MB stack per worker — inline fallback (shouldSend) can create deep
	 * recursion chains (fib: spawn→submit→inline→fib→spawn...). Default
	 * 512KB overflows at moderate depth. Matches Malebolgia's assumption
	 * that workers run user code with recursive spawn patterns. */
	pthread_attr_t attr;
	pthread_attr_init(&attr);
	pthread_attr_setstacksize(&attr, 4 * 1024 * 1024);
	int created = 0;
	for (int i = 0; i < gPool->workerCount; i++) {
		if (pthread_create(&gPool->workers[i], &attr, msPoolWorkerLoop, gPool) == 0) {
			created++;
		}
	}
	pthread_attr_destroy(&attr);
#endif

	if (created < gPool->workerCount) {
		gPool->workerCount = created;
	}
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
	pool->tail = (pool->tail + 1) % pool->cap;
	/* Signal one IDLE worker (find via bitmask — guaranteed to be sleeping) */
	uint64_t idle = atomic_load_explicit(&pool->idleMask, memory_order_acquire);
	if (idle != 0) {
		int wake = msCtz64(idle);  /* first set bit = first idle worker */
		MS_SIGNAL(pool->workerConds[wake]);
	}
	/* If no idle workers, task waits in queue — next worker finishing a task will dequeue it */
	MS_UNLOCK(pool);
}

/* ===== Phase 8: Help-First Scheduling ===== */

bool msPoolHelpOne(void) {
	msThreadPool* pool = msPoolGet();
	MS_LOCK(pool);
	if (pool->head == pool->tail) {
		MS_UNLOCK(pool);
		return false;
	}
	struct msSpawnCtx task = pool->queue[pool->head];
	pool->head = (pool->head + 1) % pool->cap;
	MS_SIGNAL(pool->space);  /* wake any backpressured submitter */
	MS_UNLOCK(pool);
	msSpawnWorkerRun(&task);
	return true;
}

/* ===== Busy Signaling (for wait paths) ===== */

/* Called when a worker enters a wait loop (msAwaitSlotWait, msWaitForReady).
 * Decrements the atomic busyCount so shouldSend sees available capacity,
 * allowing new spawns to be queued instead of inlined. Re-increment on exit. */
void msPoolBusyDec(void) {
	/* Saturating decrement — prevent underflow from nested help-first wait chains.
	 * CAS loop: only decrement if current value > 0. */
	int32_t prev = atomic_load_explicit(&msPoolBusyCount, memory_order_relaxed);
	while (prev > 0) {
		if (atomic_compare_exchange_weak_explicit(&msPoolBusyCount, &prev, prev - 1,
				memory_order_relaxed, memory_order_relaxed)) break;
	}
}

void msPoolBusyInc(void) {
	atomic_fetch_add_explicit(&msPoolBusyCount, 1, memory_order_relaxed);
}

/* ===== Shutdown ===== */

void msPoolShutdown(void) {
	if (gPool == NULL) return;
	MS_LOCK(gPool);
	gPool->shutdown = true;
	for (int i = 0; i < gPool->workerCount; i++) {
		MS_SIGNAL(gPool->workerConds[i]);
	}
	MS_BROADCAST(gPool->space);
	MS_UNLOCK(gPool);

#ifdef _WIN32
	for (int i = 0; i < gPool->workerCount; i++) {
		WaitForSingleObject(gPool->workers[i], INFINITE);
		CloseHandle(gPool->workers[i]);
	}
	free(gPool->workers);
	free(gPool->queue);
	DeleteCriticalSection(&gPool->cs);
#else
	for (int i = 0; i < gPool->workerCount; i++) {
		pthread_join(gPool->workers[i], NULL);
	}
	free(gPool->workers);
	free(gPool->queue);
	pthread_mutex_destroy(&gPool->mutex);
	for (int i = 0; i < gPool->workerCount && i < MS_POOL_MAX_WORKERS; i++) {
		pthread_cond_destroy(&gPool->workerConds[i]);
	}
	pthread_cond_destroy(&gPool->space);
#endif

	free(gPool);
	gPool = NULL;
}

#endif /* MS_BARE */
