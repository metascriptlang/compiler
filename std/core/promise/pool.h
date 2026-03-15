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

#include <pthread.h>
#include <stdbool.h>

/* Forward declaration — msSpawnCtx defined in thread.h */
struct msSpawnCtx;

typedef struct {
	pthread_t* workers;         /* worker thread handles */
	int workerCount;            /* N = CPU cores (auto-detected) */
	struct msSpawnCtx** queue;  /* circular buffer of pending tasks */
	int head;                   /* dequeue index */
	int tail;                   /* enqueue index */
	int cap;                    /* queue capacity */
	pthread_mutex_t mutex;      /* protects queue + shutdown flag */
	pthread_cond_t available;   /* signaled when task enqueued */
	pthread_cond_t space;       /* signaled when task dequeued (backpressure) */
	int busyCount;              /* number of workers currently executing tasks */
	bool shutdown;              /* set true to stop workers */
} msThreadPool;

/* Lazy-init singleton pool (first msPoolSubmit call initializes) */
msThreadPool* msPoolGet(void);

/* Submit task to pool — called by msSpawn instead of pthread_create */
void msPoolSubmit(struct msSpawnCtx* ctx);

/* Shutdown pool — drain queue, join all workers. Called at process exit. */
void msPoolShutdown(void);

#endif /* MS_POOL_H */
