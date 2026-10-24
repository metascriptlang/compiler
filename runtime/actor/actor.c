/*
 * MetaScript Actor — Shared global state definitions (anchor TU).
 *
 * actor.h / mailbox.h / selector.h are header-only with `static inline`
 * functions. Their globals MUST live in a single TU — `static` in a header
 * gives each .ms→.c TU its own private copy, breaking multi-module programs
 * (scheduler fragmentation, pool ID handoff, msg-pool / evt-buffer split).
 *
 * The `static inline` accessors compile per-TU but read/write the single
 * extern set defined below.
 */
#if !defined(MSOS_BARE) && !defined(MSOS_WASM) && !defined(MSOS_EMCC)

#include "runtime/core/system.h"  /* pulls in DRC + futures + msString (needed by actor.h) */
#include "runtime/actor/actor.h"
#include "runtime/actor/mailbox.h"   /* msMsgPools extern definition */
#include "runtime/actor/selector.h"  /* _msEvtBuf extern definition */

/* Per-thread current actor — set inside msActorProcess. */
MS_THREAD_LOCAL msActor* msCurrentActor = NULL;
MS_TLS_PUBLISH(msCurrentActor)

_Atomic(bool) msActorEntered = false;

msActor* msActorCurrentNoHoist(void) { return msCurrentActor; }

/* Per-thread scheduler ID — main thread = 0, pool worker N = N (1..workerCount).
 * Default -1 means "this thread is not a registered actor poller" so
 * msActorPollLocal early-returns instead of polling msSchedulers[-1]. */
MS_THREAD_LOCAL int msMySchedulerID = -1;
MS_TLS_PUBLISH(msMySchedulerID)

/* Fixed-size scheduler registry. msSchedulerCount is bumped to
 * `pool.workerCount + 1` on first actor registration, then immutable. */
msSchedActors msSchedulers[MS_MAX_SCHEDULERS];
int msSchedulerCount = 0;

/* Round-robin counter for actor → scheduler assignment. */
_Atomic(int) msNextActorRR = 0;

/* Idle-timeout fast path — when 0, msActorPollLocal skips the timeout scan. */
_Atomic(int) msActorsWithTimeout = 0;

/* Stop-pending fast path — when 0, msActorPollLocal skips the reap scan. */
_Atomic(int) msActorsStopPending = 0;

/* I19: pid table + hazard registry (see actor.h "Pid Table + Hazard Pins"). */
_Atomic(msPidSlot*) msPidSegs[MS_PID_SEG_COUNT] = {0};
_Atomic(uint64_t) msPidFreeHead = 0;
_Atomic(int32_t) msPidNextSlot = 0;
pthread_mutex_t msPidSegLock = PTHREAD_MUTEX_INITIALIZER;
_Atomic(msHazardRec*) msHazardHead = NULL;
MS_THREAD_LOCAL msHazardRec* msMyHazard = NULL;
MS_TLS_PUBLISH(msMyHazard)

/* Monitor ref counter (used by link/monitor primitives). */
_Atomic(int64_t) msNextMonitorRef = 1;

/* Name registry — open-addressed hash for registered actor names. */
msNameEntry* msNameRegistry = NULL;
int msNameRegistryCap = 0;
int msNameRegistryCount = 0;
pthread_mutex_t msNameRegistryLock = PTHREAD_MUTEX_INITIALIZER;

/* Cycle detector actor (pinned to scheduler 0, created by msCDInit). */
msActor* msCycleDetectorActor = NULL;

/* Mailbox per-thread message pool (mailbox.h). One pool per size class per
 * thread. Single TU-shared TLS slot — see mailbox.h comment for the
 * cross-TU duplication hazard. */
MS_THREAD_LOCAL msMsgPool msMsgPools[MS_MSG_POOL_CLASSES];
MS_TLS_PUBLISH(msMsgPools)

/* Selector per-thread poll result buffer (selector.h). Single TU-shared
 * TLS slot so msSelectorWait/EventFd/EventFlags called across TUs on the
 * same thread share the same event data. */
MS_THREAD_LOCAL msReadyEvent _msEvtBuf[64];
MS_TLS_PUBLISH(_msEvtBuf)


static msActorJob* msActorJobNew(msClosure cb, void (*drop)(void*), void* chain) {
    msActor* a = msCurrentActor;
    msActorJobs* j = msActorJobsEnsure(a);
    msActorJob* r = (msActorJob*)msMemAlloc0(sizeof(msActorJob));
    atomic_store_explicit(&r->refs, 2, memory_order_relaxed);
    r->pid = a->pid;
    r->cb = cb;
    r->drop = drop;
    r->chain = chain;
    r->liveNext = j->live;
    if (j->live != NULL) j->live->livePrev = r;
    j->live = r;
    return r;
}

msClosure msActorStamp(msClosure cb, void (*drop)(void*), void* chain) {
    return (msClosure){ .fn = (msClosureFn)msActorJobFire, .env = msActorJobNew(cb, drop, chain) };
}

static void msActorTimerEnvDrop(void* env) {
    const msTypeInfo* t = msHeader(env)->type;
    if (msDecRefIsLast(env)) {
        MS_DESTROY_DISPATCH(t, env);
        msDestroyAndDispose(env);
    }
}

void* msActorStampTimer(msClosure cb, int64_t id, bool periodic) {
    msActorJob* r = msActorJobNew(cb, msActorTimerEnvDrop, NULL);
    r->timerId = id;
    r->periodic = periodic;
    r->dropAfterRun = true;
    return r;
}

void msActorJobFire(void* r) {
    msActorJobPost((msActorJob*)r);
    msActorJobUnref((msActorJob*)r);
}

void msActorJobTick(void* r) {
    msActorJobPost((msActorJob*)r);
}

void msActorJobCancelMark(void* r) {
    atomic_store_explicit(&((msActorJob*)r)->cancelled, true, memory_order_release);
}

void msActorJobAbandon(void* raw) {
    msActorJob* r = (msActorJob*)raw;
    atomic_store_explicit(&r->cancelled, true, memory_order_release);
    msActorPostJob(r->pid, r);
    msActorJobUnref(r);
}

void msActorClearTimerJob(int64_t id) {
    msActor* a = msCurrentActor;
    if (a != NULL && a->jobs != NULL) msActorJobsCancelTimer(a->jobs, id);
}

extern void* msAsyncCurrentChain(void);  /* dispatchFull.c */

void msActorLendNote(void* fut) {
    msActorLendNoteIn(msCurrentActor, fut, msAsyncCurrentChain());
}

#endif /* !MSOS_BARE && !MSOS_WASM && !MSOS_EMCC */
