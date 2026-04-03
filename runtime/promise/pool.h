/*
 * MetaScript Thread Pool — Malebolgia-style fixed worker pool
 *
 * N worker threads (N = CPU cores) wait on a shared task queue.
 * msSpawn submits tasks to the queue instead of creating threads.
 * Workers pick up tasks and execute them, then wait for the next.
 *
 * O(1) task dispatch vs O(n) thread creation.
 */
#ifndef MS_POOL_H
#define MS_POOL_H

#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

/* Forward declaration — msSpawnCtx defined in thread.h */
struct msSpawnCtx;

#define MS_POOL_MAX_WORKERS 64

typedef struct {
#ifdef _WIN32
	HANDLE* workers;            /* worker thread handles (CreateThread) */
#else
	pthread_t* workers;         /* worker thread handles (pthread_create) */
#endif
	int workerCount;            /* N = CPU cores (auto-detected) */
	struct msSpawnCtx* queue;   /* circular buffer — structs INLINE (Malebolgia: zero alloc) */
	int head;                   /* dequeue index */
	int tail;                   /* enqueue index */
	int cap;                    /* queue capacity */
#ifdef _WIN32
	CRITICAL_SECTION cs;        /* protects queue + shutdown flag */
	CONDITION_VARIABLE workerConds[MS_POOL_MAX_WORKERS]; /* per-worker: targeted wake */
	CONDITION_VARIABLE space;    /* signaled when task dequeued (backpressure) */
#else
	pthread_mutex_t mutex;      /* protects queue + shutdown flag */
	pthread_cond_t workerConds[MS_POOL_MAX_WORKERS]; /* per-worker: targeted wake (no broadcast) */
	pthread_cond_t space;       /* signaled when task dequeued (backpressure) */
#endif
	_Atomic(uint64_t) idleMask; /* bitmask: bit i set = worker i is sleeping (up to 64 workers) */
	int busyCount;              /* number of workers currently executing tasks */
	bool shutdown;              /* set true to stop workers */
} msThreadPool;

/* Lazy-init singleton pool (first msPoolSubmit call initializes) */
msThreadPool* msPoolGet(void);

/* Submit task to pool — called by msSpawn instead of pthread_create */
void msPoolSubmit(struct msSpawnCtx* ctx);

/* Shutdown pool — drain queue, join all workers. Called at process exit. */
void msPoolShutdown(void);

/* Wake a specific worker by scheduler ID (targeted: no spurious wakeups) */
void msPoolWakeWorker(int schedulerID);

/* Wake all pool workers (shutdown, fallback) */
void msPoolWakeWorkers(void);

/* Register actor polling hooks (called by actor.h during init) */
void msPoolSetActorHooks(bool (*pollFn)(void), void (*idSetterFn)(int));

#endif /* MS_POOL_H */
