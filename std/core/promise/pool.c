/*
 * MetaScript Thread Pool — Malebolgia-style fixed worker pool
 *
 * Fixed N worker threads (auto-detected CPU count).
 * Circular buffer task queue with mutex + 2 condition variables.
 * Workers sleep when queue is empty, wake on signal.
 * Backpressure: submitter waits if queue is full (Malebolgia parity).
 * Local execution: if all workers busy, caller runs task inline.
 */
#include "std/core/system/native.h"  /* pulls in thread.h + msDecref + msCurrException */
#include "std/core/promise/pool.h"
#include <stdlib.h>
#include <unistd.h>

#define MS_POOL_MAX_QUEUE 256  /* max queue size before backpressure kicks in */

/* ===== CPU Detection ===== */

static int msDetectCPUs(void) {
#ifdef _SC_NPROCESSORS_ONLN
	int n = (int)sysconf(_SC_NPROCESSORS_ONLN);
	return n > 0 ? n : 4;
#else
	return 4; /* fallback */
#endif
}

/* ===== Queue Length (must hold mutex) ===== */

static inline int msPoolQueueLen(msThreadPool* pool) {
	return (pool->tail - pool->head + pool->cap) % pool->cap;
}

/* ===== Worker Loop ===== */

static void* msPoolWorkerLoop(void* arg) {
	msThreadPool* pool = (msThreadPool*)arg;
	while (1) {
		pthread_mutex_lock(&pool->mutex);
		/* Wait for task or shutdown */
		while (pool->head == pool->tail && !pool->shutdown) {
			pthread_cond_wait(&pool->available, &pool->mutex);
		}
		/* Check shutdown with empty queue — exit cleanly */
		if (pool->shutdown && pool->head == pool->tail) {
			pthread_mutex_unlock(&pool->mutex);
			break;
		}
		/* Dequeue task */
		msSpawnCtx* ctx = pool->queue[pool->head];
		pool->head = (pool->head + 1) % pool->cap;
		pool->busyCount++;
		/* Signal submitters waiting for space (backpressure release) */
		pthread_cond_signal(&pool->space);
		pthread_mutex_unlock(&pool->mutex);

		/* Execute task */
		msSpawnWorkerRun(ctx);

		/* Mark worker idle */
		pthread_mutex_lock(&pool->mutex);
		pool->busyCount--;
		pthread_mutex_unlock(&pool->mutex);
	}
	return NULL;
}

/* ===== Thread-Safe Singleton Init (pthread_once) ===== */

static msThreadPool* gPool = NULL;
static pthread_once_t gPoolOnce = PTHREAD_ONCE_INIT;

static void msPoolInit(void) {
	gPool = (msThreadPool*)calloc(1, sizeof(msThreadPool));
	/* I/O-bound tasks spend most time blocked in syscalls —
	 * overprovisioning threads avoids pool exhaustion under load.
	 * CPU-bound tasks self-limit via OS scheduler. */
	gPool->workerCount = msDetectCPUs();
	gPool->cap = MS_POOL_MAX_QUEUE;
	gPool->queue = (msSpawnCtx**)calloc(gPool->cap, sizeof(msSpawnCtx*));
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
	if (created < gPool->workerCount) {
		gPool->workerCount = created;
	}
	atexit(msPoolShutdown);
}

msThreadPool* msPoolGet(void) {
	pthread_once(&gPoolOnce, msPoolInit);
	return gPool;
}

/* ===== Submit Task ===== */

void msPoolSubmit(msSpawnCtx* ctx) {
	msThreadPool* pool = msPoolGet();
	pthread_mutex_lock(&pool->mutex);

	/* Backpressure: if queue full AND all workers busy, execute inline on caller thread.
	 * (Malebolgia parity: shouldSend returns false when busyThreads >= ThreadPoolSize-1)
	 * Only inline when there's truly no capacity — prevents recursive stack overflow. */
	if (msPoolQueueLen(pool) >= pool->cap - 1 && pool->busyCount >= pool->workerCount) {
		pthread_mutex_unlock(&pool->mutex);
		msSpawnWorkerRun(ctx);
		return;
	}

	/* Backpressure: wait if queue is full but workers available to drain it */
	while (msPoolQueueLen(pool) >= pool->cap - 1 && !pool->shutdown) {
		pthread_cond_wait(&pool->space, &pool->mutex);
	}
	if (pool->shutdown) {
		pthread_mutex_unlock(&pool->mutex);
		msSpawnWorkerRun(ctx); /* drain during shutdown */
		return;
	}

	/* Enqueue */
	pool->queue[pool->tail] = ctx;
	pool->tail = (pool->tail + 1) % pool->cap;
	pthread_cond_signal(&pool->available);
	pthread_mutex_unlock(&pool->mutex);
}

/* ===== Shutdown ===== */

void msPoolShutdown(void) {
	if (gPool == NULL) return;
	pthread_mutex_lock(&gPool->mutex);
	gPool->shutdown = true;
	pthread_cond_broadcast(&gPool->available);
	pthread_cond_broadcast(&gPool->space); /* unblock any submitters waiting for space */
	pthread_mutex_unlock(&gPool->mutex);
	for (int i = 0; i < gPool->workerCount; i++) {
		pthread_join(gPool->workers[i], NULL);
	}
	free(gPool->workers);
	free(gPool->queue);
	pthread_mutex_destroy(&gPool->mutex);
	pthread_cond_destroy(&gPool->available);
	pthread_cond_destroy(&gPool->space);
	free(gPool);
	gPool = NULL;
}
