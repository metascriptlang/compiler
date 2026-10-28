/*
 * MetaScript exit drain — Node-semantics shutdown for the C backend.
 *
 * "The program ends when the event loop is empty": after the entry module's
 * top-level code returns, keep pumping the dispatcher until nothing is left
 * (no due timers, no queued callbacks, no pending pool tasks), then report
 * futures that completed FAILED with no observer — the unhandled-rejection
 * contract (exit code 1). process.exit() bypasses both, matching Node.
 */
#include "runtime/core/system.h"
#include "dispatch.h"
#include <stdio.h>
#include <stdlib.h>

#if !defined(MSOS_EMCC) && !defined(MSOS_WASM) && !defined(MSOS_BARE)
#include <pthread.h>
static pthread_mutex_t msOrphanMu = PTHREAD_MUTEX_INITIALIZER;
#define MS_ORPHAN_LOCK()   pthread_mutex_lock(&msOrphanMu)
#define MS_ORPHAN_UNLOCK() pthread_mutex_unlock(&msOrphanMu)
#else
#define MS_ORPHAN_LOCK()   ((void)0)
#define MS_ORPHAN_UNLOCK() ((void)0)
#endif

#define MS_ORPHAN_MAX 256
static msFutureBase* msOrphanFails[MS_ORPHAN_MAX];
static int msOrphanCount = 0;
static int msOrphanOverflow = 0;
static void* msOrphanErrors[MS_ORPHAN_MAX];
static int msOrphanErrorCount = 0;

/* Registers the failed future on the thread that owns its count: the entry's
 * incref is a plain rc op, so it runs where the owner's own rc ops run. */
void msAdoptOrphanFailure(void* fut) {
	MS_ORPHAN_LOCK();
	if (atomic_load_explicit(&((msFutureBase*)fut)->errorObserved, memory_order_relaxed)) {
		MS_ORPHAN_UNLOCK();
		return;
	}
	/* Reuse cleared slots first: poll-style readers (waitFor) note then clear
	 * transiently, so live entries are sparse once the count has grown. */
	int slot = -1;
	for (int i = 0; i < msOrphanCount; i++) {
		if (msOrphanFails[i] == NULL) { slot = i; break; }
	}
	if (slot < 0 && msOrphanCount < MS_ORPHAN_MAX) slot = msOrphanCount++;
	if (slot >= 0) {
		msIncRef(fut);
		msOrphanFails[slot] = (msFutureBase*)fut;
	} else {
		msOrphanOverflow++;
	}
	MS_ORPHAN_UNLOCK();
}

#if !defined(MSOS_EMCC) && !defined(MSOS_WASM) && !defined(MSOS_BARE)
/* A published future's count belongs to the thread whose channel it names
 * (NULL is the main loop). */
static bool msFailureNotedOffOwner(msFutureBase* f) {
	if (!f->crossThreadPublished) return false;
	void* q = f->completionQueue;
	return q != msLoopCompletionQueue() || (msIsPoolWorker && q == NULL);
}
#endif

/* Called from msFutureFireCallbacks when a future completes FAILED with no
 * callback attached. A non-owner thread (an actor reply failed on the thread
 * that reaps the actor) never touches the count: it posts the note to the
 * owner's completion queue, behind which the mailbox's in-flight release is
 * ordered, so the future is alive when the owner adopts it. The entry is
 * deliberately never released (the process is exiting). */
void msNoteOrphanFailure(void* fut) {
	if (fut == NULL) return;
#if !defined(MSOS_EMCC) && !defined(MSOS_WASM) && !defined(MSOS_BARE)
	if (msFailureNotedOffOwner((msFutureBase*)fut)) {
#if !MS_FUTURE_SUBMIT_REF
		fputs("internal: orphan failure noted off the owner thread without a submit ref\n", stderr);
		abort();
#endif
		if (atomic_load_explicit(&((msFutureBase*)fut)->errorObserved, memory_order_relaxed)) return;
		msCompletionQueuePushOrphanNote(fut);
		return;
	}
#endif
	msAdoptOrphanFailure(fut);
}

void msNoteOrphanError(void* err) {
	MS_ORPHAN_LOCK();
	if (msOrphanErrorCount < MS_ORPHAN_MAX) {
		msOrphanErrors[msOrphanErrorCount++] = err;
	} else {
		msOrphanOverflow++;
		msDecrefAny(err);
	}
	MS_ORPHAN_UNLOCK();
}

static void msReportRejection(void* error) {
	fputs("Error: unhandled rejection: ", stderr);
	if (error != NULL) {
		msString m = ((msError*)error)->message;
		if (m.p != NULL && m.len > 0) fwrite(m.p->data, 1, (size_t)m.len, stderr);
	}
	fputc('\n', stderr);
}

/* Called when the failure becomes observed: an await reads it
 * (msFutureRaiseFrom) or a callback is attached to the already-failed
 * future (msFutureAddCallback's finished branch). */
void msClearOrphanFailure(void* fut) {
	if (fut == NULL) return;
	MS_ORPHAN_LOCK();
	for (int i = 0; i < msOrphanCount; i++) {
		if (msOrphanFails[i] == fut) {
			msOrphanFails[i] = NULL;
			msDecrefAny(fut);
		}
	}
	MS_ORPHAN_UNLOCK();
}

int msReportOrphanFailures(void) {
	int reported = 0;
	MS_ORPHAN_LOCK();
	for (int i = 0; i < msOrphanCount; i++) {
		msFutureBase* f = msOrphanFails[i];
		msOrphanFails[i] = NULL;
		if (f == NULL) continue;
		if (f->failed && !f->cancelled) {
			msReportRejection(f->error);
			reported++;
		}
		msDecrefAny(f);
	}
	msOrphanCount = 0;
	for (int i = 0; i < msOrphanErrorCount; i++) {
		msReportRejection(msOrphanErrors[i]);
		msDecrefAny(msOrphanErrors[i]);
		msOrphanErrors[i] = NULL;
		reported++;
	}
	msOrphanErrorCount = 0;
	if (msOrphanOverflow > 0) {
		fprintf(stderr, "Error: %d additional unhandled rejection(s)\n", msOrphanOverflow);
		reported++;
	}
	msOrphanOverflow = 0;
	MS_ORPHAN_UNLOCK();
	msFutureReleaseFlush();
	return reported;
}

/* The pending count rises when a task is submitted and falls after its worker
 * has published it and posted its completion, so with none pending every posted
 * completion is already in the queue and one drain takes it, noting a failure
 * even when nothing created a dispatcher. */
extern bool msCompletionQueueDrain(void);

void msDrainUntilIdle(void) {
	if (!msHasDispatcher() && msPoolPendingPeek() == 0 && !msCompletionQueueDrain()) return;
	msDispatcher* d = msGetDispatcher();
	int idleSweeps = 0;
	while (idleSweeps < 2) {
		bool didWork = false;
		msProcessCallbacks(d, &didWork);
		int nextTimer = msProcessTimers(d, &didWork);
		msProcessCallbacks(d, &didWork);
		if (didWork) { idleSweeps = 0; continue; }
		bool tasksPending = msPoolPendingPeek() > 0;
		if (nextTimer >= 0 || tasksPending) {
			idleSweeps = 0;
			msRunOnce(tasksPending && nextTimer < 0 ? 10 : nextTimer);
			continue;
		}
		/* Fully idle per the cheap checks — one non-blocking sweep catches
		 * cross-thread completions posted between the checks and here. */
		if (msRunOnce(0)) { idleSweeps = 0; continue; }
		idleSweeps++;
	}
}

static _Atomic(msExitHookFn) msActorExitHook = NULL;
void msSetActorExitHook(msExitHookFn hook) { atomic_store_explicit(&msActorExitHook, hook, memory_order_release); }

void msDrainAtExit(void) {
	msDrainUntilIdle();
	msExitHookFn hook = atomic_load_explicit(&msActorExitHook, memory_order_acquire);
	if (hook != NULL) hook();
}
