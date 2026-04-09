/*
 * MetaScript Async Dispatcher — WASI (standalone WASM runtimes)
 *
 * Single-threaded, no selectors, no pthreads.
 * msWaitFor uses nanosleep + busy loop.
 * Timer heap + callback deque: same logic as dispatchEmcc.c.
 */
#ifdef MSOS_WASM
#define _POSIX_C_SOURCE 199309L

#include "dispatch.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* ===== Monotonic Clock ===== */

int64_t msMonoTimeMs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + (int64_t)ts.tv_nsec / 1000000;
}

void msSleepMs(int ms) {
    struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

/* ===== Callback Deque ===== */

static void msDequeInit(msCallbackDeque* q) {
    q->cap = 64;
    q->items = (msClosure*)calloc(q->cap, sizeof(msClosure));
    q->head = 0;
    q->tail = 0;
}

static void msDequeAppend(msCallbackDeque* q, msClosure cb) {
    int next = (q->tail + 1) % q->cap;
    if (next == q->head) {
        int newCap = q->cap * 2;
        msClosure* newItems = (msClosure*)calloc(newCap, sizeof(msClosure));
        int count = 0;
        int i = q->head;
        while (i != q->tail) { newItems[count++] = q->items[i]; i = (i + 1) % q->cap; }
        free(q->items);
        q->items = newItems;
        q->head = 0;
        q->tail = count;
        q->cap = newCap;
        next = (q->tail + 1) % q->cap;
    }
    q->items[q->tail] = cb;
    q->tail = next;
}

static int msDequeLen(msCallbackDeque* q) {
    return (q->tail - q->head + q->cap) % q->cap;
}

/* ===== Timer Heap ===== */

static void msTimerHeapPush(msTimerHeap* h, msTimer t) {
    if (h->len >= h->cap) {
        h->cap = h->cap ? h->cap * 2 : 16;
        h->data = (msTimer*)realloc(h->data, h->cap * sizeof(msTimer));
    }
    h->data[h->len] = t;
    int i = h->len++;
    while (i > 0) {
        int parent = (i - 1) / 2;
        if (h->data[parent].finishAtMs <= h->data[i].finishAtMs) break;
        msTimer tmp = h->data[i]; h->data[i] = h->data[parent]; h->data[parent] = tmp;
        i = parent;
    }
}

static msTimer msTimerHeapPop(msTimerHeap* h) {
    msTimer top = h->data[0];
    h->data[0] = h->data[--h->len];
    int i = 0;
    while (1) {
        int left = 2*i+1, right = 2*i+2, smallest = i;
        if (left < h->len && h->data[left].finishAtMs < h->data[smallest].finishAtMs) smallest = left;
        if (right < h->len && h->data[right].finishAtMs < h->data[smallest].finishAtMs) smallest = right;
        if (smallest == i) break;
        msTimer tmp = h->data[i]; h->data[i] = h->data[smallest]; h->data[smallest] = tmp;
        i = smallest;
    }
    return top;
}

/* ===== Dispatcher Singleton ===== */

static msDispatcher* gDispatcher = NULL;
static void msDequeAppend_wrapper(msClosure cb);

msDispatcher* msGetDispatcher(void) {
    if (gDispatcher == NULL) {
        gDispatcher = (msDispatcher*)calloc(1, sizeof(msDispatcher));
        msDequeInit(&gDispatcher->callbacks);
        msCallSoonProc = (msCallSoonFn)msDequeAppend_wrapper;
    }
    return gDispatcher;
}

bool msHasDispatcher(void) { return gDispatcher != NULL; }

static void msDequeAppend_wrapper(msClosure cb) {
    msDequeAppend(&gDispatcher->callbacks, cb);
}

/* ===== Timer + Callback Processing ===== */

int msProcessTimers(msDispatcher* d, bool* didWork) {
    int64_t now = msMonoTimeMs();
    while (d->timers.len > 0 && d->timers.data[0].finishAtMs <= now) {
        msTimer t = msTimerHeapPop(&d->timers);
        if (t.fut != NULL) {
            msFutureBase* f = (msFutureBase*)t.fut;
            if (!atomic_load_explicit(&f->finished, memory_order_acquire)) {
                atomic_store_explicit(&f->finished, true, memory_order_release);
                msFutureFireCallbacks(f);
            }
        }
        *didWork = true;
    }
    return d->timers.len > 0 ? (int)(d->timers.data[0].finishAtMs - now) : -1;
}

void msProcessCallbacks(msDispatcher* d, bool* didWork) {
    int count = msDequeLen(&d->callbacks);
    for (int i = 0; i < count; i++) {
        msClosure cb = d->callbacks.items[d->callbacks.head];
        d->callbacks.head = (d->callbacks.head + 1) % d->callbacks.cap;
        ((void(*)(void*))cb.fn)(cb.env);
        *didWork = true;
    }
}

int msAdjustTimeout(msDispatcher* d, int pollTimeout, int nextTimerMs) {
    (void)d;
    return nextTimerMs < pollTimeout ? nextTimerMs : pollTimeout;
}

/* ===== Core API ===== */

void msNotifyFutureComplete(void) { /* single-threaded: no condvar */ }
void msWorkerWaitOnFuture(void* fut) { (void)fut; }

bool msRunOnce(int timeoutMs) {
    msDispatcher* d = msGetDispatcher();
    bool didWork = false;
    msProcessTimers(d, &didWork);
    msProcessCallbacks(d, &didWork);
    if (!didWork && timeoutMs > 0) {
        msSleepMs(timeoutMs > 5 ? 5 : timeoutMs);
    }
    return didWork;
}

void msPoll(int timeoutMs) { (void)msRunOnce(timeoutMs); }

void* msWaitFor(void* fp) {
    msFutureBase* fut = (msFutureBase*)fp;
    msGetDispatcher();
    while (!atomic_load_explicit(&fut->finished, memory_order_acquire)) {
        msRunOnce(5);
    }
    return ((msFuture_ptr*)fp)->value;
}

void msWaitForReady(void* fp) {
    msFutureBase* fut = (msFutureBase*)fp;
    while (!atomic_load_explicit(&fut->finished, memory_order_acquire)) {
        msRunOnce(5);
    }
}

void msRunForever(void) { while (1) msRunOnce(100); }

msFuture_void* msSleepAsync(int ms) {
    msFuture_void* f = (msFuture_void*)msFutureCreate();
    msTimerHeapPush(&msGetDispatcher()->timers, (msTimer){ .finishAtMs = msMonoTimeMs() + ms, .fut = f });
    return f;
}

void msPostCompletion(void* fut, void* value, bool isFail, void* error) {
    if (isFail) msFutureFail(fut, error);
    else {
        msFutureBase* f = (msFutureBase*)fut;
        ((msFuture_ptr*)f)->value = value;
        atomic_store_explicit(&f->finished, true, memory_order_release);
        msFutureFireCallbacks(f);
    }
}

int32_t msGetWakePipeFd(void) { return -1; }
void msDestroyDispatcher(void) {
    if (gDispatcher) {
        free(gDispatcher->callbacks.items);
        free(gDispatcher->timers.data);
        free(gDispatcher);
        gDispatcher = NULL;
    }
}

bool (*msActorPollHook)(void) = NULL;
bool msCompletionQueueDrain(void) { return false; }
void msCompletionQueuePush(void* fut, bool isFail, void* error) {
    msPostCompletion(fut, NULL, isFail, error);
}

/* ===== Async Stepper (same as dispatchFull.c — no threading needed) ===== */

void msAsyncCb(void* raw) {
    msAsyncCbEnv* e = (msAsyncCbEnv*)raw;
    msFutureBase* next = e->stepper.env != NULL
        ? ((msFutureBase*(*)(void*))e->stepper.fn)(e->stepper.env)
        : ((msFutureBase*(*)(void))e->stepper.fn)();
    while (next != NULL && atomic_load_explicit(&next->finished, memory_order_acquire)) {
        next = e->stepper.env != NULL
            ? ((msFutureBase*(*)(void*))e->stepper.fn)(e->stepper.env)
            : ((msFutureBase*(*)(void))e->stepper.fn)();
    }
    if (next == NULL) { free(e); return; }
    msFutureAddCallback(next, (msClosure){ .fn = (msClosureFn)msAsyncCb, .env = raw });
}

void msAsyncStart(void* retFut, msClosure stepper) {
    (void)retFut;
    msGetDispatcher();
    msAsyncCbEnv* env = (msAsyncCbEnv*)malloc(sizeof(msAsyncCbEnv));
    env->stepper = stepper;
    if (stepper.env) msIncRef(stepper.env);
    msAsyncCb(env);
}

#endif /* MSOS_WASM */
