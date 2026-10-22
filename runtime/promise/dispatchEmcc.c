/*
 * MetaScript Async Dispatcher — Emscripten (browser WASM)
 *
 * Single-threaded. No pthreads, no selector, no wake pipe.
 * msWaitFor yields to the JS event loop via emscripten_sleep, which JSPI suspends.
 * Timer heap + callback deque: same logic as desktop, no threading.
 */
#ifdef MSOS_EMCC

#include "runtime/core/system.h"
#include "dispatch.h"
#include <emscripten.h>
#include <stdlib.h>
#include <string.h>

/* ===== Monotonic Clock ===== */

int64_t msMonoTimeMs(void) {
    return (int64_t)(emscripten_get_now());
}

void msSleepMs(int ms) {
    emscripten_sleep(ms);
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
        *didWork = true;
        if (t.fut != NULL) {
            msFutureBase* f = (msFutureBase*)t.fut;
            if (!atomic_load_explicit(&f->finished, memory_order_acquire)) {
                atomic_store_explicit(&f->finished, true, memory_order_release);
                msFutureFireCallbacks(f);
            }
            continue;
        }
        if (t.periodMs > 0 && !t.cancelled && t.cb.fn != NULL) {
            msTimer next = t;
            next.finishAtMs = now + t.periodMs;
            msTimerHeapPush(&d->timers, next);
        }
        if (t.cancelled || t.cb.fn == NULL) {
            if (t.cb.env != NULL) msDecref(t.cb.env);
            continue;
        }
        if (t.cb.env != NULL) ((void(*)(void*))t.cb.fn)(t.cb.env);
        else ((void(*)(void))t.cb.fn)();
        if (t.periodMs == 0 && t.cb.env != NULL) msDecref(t.cb.env);
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
        emscripten_sleep(timeoutMs > 5 ? 5 : timeoutMs);
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

static int64_t gTimerSeq = 0;

static int64_t msArmTimer(msClosure cb, double ms, int64_t periodMs) {
    if (cb.env != NULL) msIncRef(cb.env);
    int64_t delay = (int64_t)ms;
    if (delay < 0) delay = 0;
    gTimerSeq += 1;
    msTimerHeapPush(&msGetDispatcher()->timers, (msTimer){
        .finishAtMs = msMonoTimeMs() + delay,
        .cb = cb,
        .id = gTimerSeq,
        .periodMs = periodMs,
    });
    return gTimerSeq;
}

static void msCancelTimer(int64_t id) {
    msTimerHeap* h = &msGetDispatcher()->timers;
    for (int i = 0; i < h->len; i += 1) {
        if (h->data[i].id == id) {
            h->data[i].cancelled = true;
            h->data[i].periodMs = 0;
            break;
        }
    }
}

double msSetTimeout(msClosure cb, double ms) { return (double)msArmTimer(cb, ms, 0); }

double msSetInterval(msClosure cb, double ms) {
    int64_t period = (int64_t)ms;
    if (period < 1) period = 1;
    return (double)msArmTimer(cb, ms, period);
}

void msClearTimeout(double id) { msCancelTimer((int64_t)id); }

void msClearInterval(double id) { msCancelTimer((int64_t)id); }

int32_t msGetWakePipeFd(void) { return -1; }
void msDestroyDispatcher(void) {
    if (gDispatcher) {
        free(gDispatcher->callbacks.items);
        free(gDispatcher->timers.data);
        free(gDispatcher);
        gDispatcher = NULL;
    }
}

/* No-ops for emcc (no threads, no actors) */
bool (*msActorPollHook)(void) = NULL;
bool msCompletionQueueDrain(void) { return false; }
void* msLoopCompletionQueue(void) { return NULL; }
/* The producer has already stored the value or error and set finished, as on the
 * threaded drain: fire the callbacks, never overwrite the stored result. */
void msCompletionQueuePush(void* fut, bool isFail, void* error) {
    (void)isFail; (void)error;
    if (fut != NULL) msFutureFireCallbacks((msFutureBase*)fut);
}
void msCompletionQueuePushOwned(void* fut, bool isFail, void* error) {
    msCompletionQueuePush(fut, isFail, error);
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

void msEnsureOwnerDispatcher(void) {
    (void)msGetDispatcher();
}

void msAsyncStart(void* retFut, msClosure stepper) {
    (void)retFut;
    msGetDispatcher();
    msAsyncCbEnv* env = (msAsyncCbEnv*)malloc(sizeof(msAsyncCbEnv));
    env->stepper = stepper;
    if (stepper.env) msIncRef(stepper.env);
    msAsyncCb(env);
}

#endif /* MSOS_EMCC */
