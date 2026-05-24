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

/* Per-thread current actor — set inside msActorProcess for sender muting. */
MS_THREAD_LOCAL msActor* msCurrentActor = NULL;

/* Per-thread scheduler ID — main thread = 0, pool worker N = N (1..workerCount).
 * Default -1 means "this thread is not a registered actor poller" so
 * msActorPollLocal early-returns instead of polling msSchedulers[-1]. */
MS_THREAD_LOCAL int msMySchedulerID = -1;

/* Fixed-size scheduler registry. msSchedulerCount is bumped to
 * `pool.workerCount + 1` on first actor registration, then immutable. */
msSchedActors msSchedulers[MS_MAX_SCHEDULERS];
int msSchedulerCount = 0;

/* Round-robin counter for actor → scheduler assignment. */
_Atomic(int) msNextActorRR = 0;

/* Idle-timeout fast path — when 0, msActorPollLocal skips the timeout scan. */
_Atomic(int) msActorsWithTimeout = 0;

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

/* Selector per-thread poll result buffer (selector.h). Single TU-shared
 * TLS slot so msSelectorWait/EventFd/EventFlags called across TUs on the
 * same thread share the same event data. */
MS_THREAD_LOCAL msReadyEvent _msEvtBuf[64];

#endif /* !MSOS_BARE && !MSOS_WASM && !MSOS_EMCC */
