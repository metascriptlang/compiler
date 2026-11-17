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

#ifdef MSOS_HOST_PUMPED
#include <stdio.h>
__attribute__((import_module("env"), import_name("msb_wake"))) void msb_wake(int32_t delayMs);

static _Noreturn void msHostWaitRefused(const char* what) {
    fprintf(stderr, "%s in wasm-placed code cannot finish: the JS side runs the event loop only "
        "between boundary calls, so await the value instead\n", what);
    abort();
}

void msSleepMs(int ms) {
    (void)ms;
    msHostWaitRefused("a synchronous sleep");
}
#else
void msSleepMs(int ms) {
    emscripten_sleep(ms);
}
#endif

/* ===== Callback Deque ===== */

static void msDequeInit(msCallbackDeque* q) {
    q->cap = 64;
    q->items = (msClosure*)msMemAllocN0(q->cap, sizeof(msClosure));
    q->head = 0;
    q->tail = 0;
}

static void msDequeAppend(msCallbackDeque* q, msClosure cb) {
    int next = (q->tail + 1) % q->cap;
    if (next == q->head) {
        int newCap = q->cap * 2;
        msClosure* newItems = (msClosure*)msMemAllocN0(newCap, sizeof(msClosure));
        int count = 0;
        int i = q->head;
        while (i != q->tail) { newItems[count++] = q->items[i]; i = (i + 1) % q->cap; }
        msMemFree(q->items);
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
        int oldCap = h->cap;
        h->cap = oldCap ? oldCap * 2 : 16;
        h->data = (msTimer*)msRealloc(h->data, oldCap * sizeof(msTimer), h->cap * sizeof(msTimer));
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
        gDispatcher = (msDispatcher*)msMemAlloc0(sizeof(msDispatcher));
        msDequeInit(&gDispatcher->callbacks);
        msCallSoonProc = (msCallSoonFn)msDequeAppend_wrapper;
        msArmExitDrain();
    }
    return gDispatcher;
}

bool msHasDispatcher(void) { return gDispatcher != NULL; }

static void msDequeAppend_wrapper(msClosure cb) {
#ifdef MSOS_HOST_PUMPED
    if (msDequeLen(&gDispatcher->callbacks) == 0) msb_wake(0);
#endif
    msDequeAppend(&gDispatcher->callbacks, cb);
}

#ifdef MSOS_HOST_PUMPED
static int32_t msHostTimerWait(msTimerHeap* h) {
    int64_t wait = h->data[0].finishAtMs - msMonoTimeMs();
    return wait > 1 ? (int32_t)wait : 1;
}
#endif

static void msPushTimer(msTimer t) {
    msTimerHeap* h = &msGetDispatcher()->timers;
    msTimerHeapPush(h, t);
#ifdef MSOS_HOST_PUMPED
    if (h->data[0].finishAtMs == t.finishAtMs) msb_wake(msHostTimerWait(h));
#endif
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
            if (t.cb.env != NULL) msDecrefAny(t.cb.env);
            continue;
        }
        if (t.cb.env != NULL) ((void(*)(void*))t.cb.fn)(t.cb.env);
        else ((void(*)(void))t.cb.fn)();
        if (t.periodMs == 0 && t.cb.env != NULL) msDecrefAny(t.cb.env);
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
void msActorWakeEventLoop(void) {}
void msEnsureWakePipe(void) {}

bool msRunOnce(int timeoutMs) {
    msDispatcher* d = msGetDispatcher();
    bool didWork = false;
    msProcessTimers(d, &didWork);
    msProcessCallbacks(d, &didWork);
#ifndef MSOS_HOST_PUMPED
    if (!didWork && timeoutMs > 0) {
        emscripten_sleep(timeoutMs > 5 ? 5 : timeoutMs);
    }
#else
    (void)timeoutMs;
#endif
    return didWork;
}

#ifdef MSOS_HOST_PUMPED
EMSCRIPTEN_KEEPALIVE int32_t msb_pump(void) {
    msDispatcher* d = msGetDispatcher();
    bool didWork = false;
    msProcessCallbacks(d, &didWork);
    msProcessTimers(d, &didWork);
    msProcessCallbacks(d, &didWork);
    if (msDequeLen(&d->callbacks) > 0) return 0;
    return d->timers.len == 0 ? -1 : msHostTimerWait(&d->timers);
}
#endif

void msPoll(int timeoutMs) { (void)msRunOnce(timeoutMs); }

void msWaitForReady(void* fp) {
    msFutureBase* fut = (msFutureBase*)fp;
    msGetDispatcher();
    while (!atomic_load_explicit(&fut->finished, memory_order_acquire)) {
#ifdef MSOS_HOST_PUMPED
        if (!msRunOnce(0)) msHostWaitRefused("a synchronous wait for a pending promise");
#else
        msRunOnce(5);
#endif
    }
}

void* msWaitFor(void* fp) {
    msWaitForReady(fp);
    return ((msFuture_ptr*)fp)->value;
}

#ifdef MSOS_HOST_PUMPED
void msRunForever(void) { msHostWaitRefused("running the event loop forever"); }
#else
void msRunForever(void) { while (1) msRunOnce(100); }
#endif

msFuture_void* msSleepAsync(int ms) {
    msFuture_void* f = (msFuture_void*)msFutureCreate();
    msPushTimer((msTimer){ .finishAtMs = msMonoTimeMs() + ms, .fut = f });
    return f;
}

static int64_t gTimerSeq = 0;

static int64_t msArmTimer(msClosure cb, double ms, int64_t periodMs) {
    if (cb.env != NULL) msIncRef(cb.env);
    int64_t delay = (int64_t)ms;
    if (delay < 0) delay = 0;
    gTimerSeq += 1;
    msPushTimer((msTimer){
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
        msMemFree(gDispatcher->callbacks.items);
        msMemFree(gDispatcher->timers.data);
        msMemFree(gDispatcher);
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
    while (msCallSoonProc == NULL && next != NULL && atomic_load_explicit(&next->finished, memory_order_acquire)) {
        msFutureDrcDestroy(next);
        next = e->stepper.env != NULL
            ? ((msFutureBase*(*)(void*))e->stepper.fn)(e->stepper.env)
            : ((msFutureBase*(*)(void))e->stepper.fn)();
    }
    if (next == NULL) {
        if (e->stepper.env != NULL) msDecrefAny(e->stepper.env);
        msMemFree(e);
        return;
    }
    msFutureAddCallback(next, (msClosure){ .fn = (msClosureFn)msAsyncCb, .env = raw });
    msFutureDrcDestroy(next);
}

void msEnsureOwnerDispatcher(void) {
    (void)msGetDispatcher();
}

void msAsyncStart(void* retFut, msClosure stepper) {
    (void)retFut;
    msGetDispatcher();
    msAsyncCbEnv* env = (msAsyncCbEnv*)msMemAlloc(sizeof(msAsyncCbEnv));
    env->stepper = stepper;
    if (stepper.env) msIncRef(stepper.env);
    msAsyncCb(env);
}

#endif /* MSOS_EMCC */
