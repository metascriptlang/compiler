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
#include "std/core/system/native.h"  /* pulls in thread.h + msDecref + msCurrException */
#include "std/core/promise/pool.h"
#include <stdlib.h>

/* ===== Platform Abstraction Macros ===== */

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

/* ===== Worker Loop ===== */

#ifdef _WIN32
static DWORD WINAPI msPoolWorkerLoop(LPVOID arg) {
#else
static void* msPoolWorkerLoop(void* arg) {
#endif
	msThreadPool* pool = (msThreadPool*)arg;
	while (1) {
		MS_LOCK(pool);
		/* Wait for task or shutdown */
		while (pool->head == pool->tail && !pool->shutdown) {
			MS_WAIT(pool->available, pool);
		}
		/* Check shutdown with empty queue — exit cleanly */
		if (pool->shutdown && pool->head == pool->tail) {
			MS_UNLOCK(pool);
			break;
		}
		/* Dequeue task */
		msSpawnCtx* ctx = pool->queue[pool->head];
		pool->head = (pool->head + 1) % pool->cap;
		pool->busyCount++;
		/* Signal submitters waiting for space (backpressure release) */
		MS_SIGNAL(pool->space);
		MS_UNLOCK(pool);

		/* Execute task */
		msSpawnWorkerRun(ctx);

		/* Mark worker idle */
		MS_LOCK(pool);
		pool->busyCount--;
		MS_UNLOCK(pool);
	}
#ifdef _WIN32
	return 0;
#else
	return NULL;
#endif
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
	gPool->cap = MS_POOL_MAX_QUEUE;
	gPool->queue = (msSpawnCtx**)calloc(gPool->cap, sizeof(msSpawnCtx*));

#ifdef _WIN32
	InitializeCriticalSection(&gPool->cs);
	InitializeConditionVariable(&gPool->available);
	InitializeConditionVariable(&gPool->space);
	gPool->workers = (HANDLE*)calloc(gPool->workerCount, sizeof(HANDLE));
	int created = 0;
	for (int i = 0; i < gPool->workerCount; i++) {
		gPool->workers[i] = CreateThread(NULL, 0, msPoolWorkerLoop, gPool, 0, NULL);
		if (gPool->workers[i] != NULL) created++;
	}
#else
	pthread_mutex_init(&gPool->mutex, NULL);
	pthread_cond_init(&gPool->available, NULL);
	pthread_cond_init(&gPool->space, NULL);
	gPool->workers = (pthread_t*)calloc(gPool->workerCount, sizeof(pthread_t));
	int created = 0;
	for (int i = 0; i < gPool->workerCount; i++) {
		if (pthread_create(&gPool->workers[i], NULL, msPoolWorkerLoop, gPool) == 0) {
			created++;
		}
	}
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

void msPoolSubmit(msSpawnCtx* ctx) {
	msThreadPool* pool = msPoolGet();
	MS_LOCK(pool);

	/* Backpressure: if queue full AND all workers busy, execute inline on caller thread.
	 * (Malebolgia parity: shouldSend returns false when busyThreads >= ThreadPoolSize-1)
	 * Only inline when there's truly no capacity — prevents recursive stack overflow. */
	if (msPoolQueueLen(pool) >= pool->cap - 1 && pool->busyCount >= pool->workerCount) {
		MS_UNLOCK(pool);
		msSpawnWorkerRun(ctx);
		return;
	}

	/* Backpressure: wait if queue is full but workers available to drain it */
	while (msPoolQueueLen(pool) >= pool->cap - 1 && !pool->shutdown) {
		MS_WAIT(pool->space, pool);
	}
	if (pool->shutdown) {
		MS_UNLOCK(pool);
		msSpawnWorkerRun(ctx); /* drain during shutdown */
		return;
	}

	/* Enqueue */
	pool->queue[pool->tail] = ctx;
	pool->tail = (pool->tail + 1) % pool->cap;
	MS_SIGNAL(pool->available);
	MS_UNLOCK(pool);
}

/* ===== Shutdown ===== */

void msPoolShutdown(void) {
	if (gPool == NULL) return;
	MS_LOCK(gPool);
	gPool->shutdown = true;
	MS_BROADCAST(gPool->available);
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
	pthread_cond_destroy(&gPool->available);
	pthread_cond_destroy(&gPool->space);
#endif

	free(gPool);
	gPool = NULL;
}
