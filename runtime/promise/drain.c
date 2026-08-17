/*
 * MetaScript exit drain — Node-semantics shutdown for the C backend.
 *
 * "The program ends when the event loop is empty": after the entry module's
 * top-level code returns, keep pumping the dispatcher until nothing is left
 * (no due timers, no queued callbacks, no busy pool workers), then report
 * futures that completed FAILED with no observer — the unhandled-rejection
 * contract (exit code 1). process.exit() bypasses both, matching Node.
 */
#include "runtime/core/system.h"
#include "dispatch.h"
#include <stdio.h>

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

/* Called from msFutureFireCallbacks when a future completes FAILED with no
 * callback attached. Cross-thread safe: msPostCompletion's no-dispatcher
 * fallback runs msFutureFail on pool threads. The incref keeps the entry
 * valid until the exit report; it is deliberately never released (the
 * process is exiting). */
void msNoteOrphanFailure(void* fut) {
	if (fut == NULL) return;
	MS_ORPHAN_LOCK();
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

/* Called when the failure becomes observed: an await reads it
 * (msFutureRaiseFrom) or a callback is attached to the already-failed
 * future (msFutureAddCallback's finished branch). */
void msClearOrphanFailure(void* fut) {
	if (fut == NULL) return;
	MS_ORPHAN_LOCK();
	for (int i = 0; i < msOrphanCount; i++) {
		if (msOrphanFails[i] == fut) {
			msOrphanFails[i] = NULL;
			msDecref(fut);
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
			fputs("Error: unhandled rejection: ", stderr);
			if (f->error != NULL) {
				msString m = ((msError*)f->error)->message;
				if (m.p != NULL && m.len > 0) fwrite(m.p->data, 1, (size_t)m.len, stderr);
			}
			fputc('\n', stderr);
			reported++;
		}
		msDecref(f);
	}
	msOrphanCount = 0;
	if (msOrphanOverflow > 0) {
		fprintf(stderr, "Error: %d additional unhandled rejection(s)\n", msOrphanOverflow);
		reported++;
	}
	msOrphanOverflow = 0;
	MS_ORPHAN_UNLOCK();
	msFutureReleaseFlush();
	return reported;
}

void msDrainUntilIdle(void) {
	if (!msHasDispatcher()) return;
	msDispatcher* d = msGetDispatcher();
	int idleSweeps = 0;
	while (idleSweeps < 2) {
		bool didWork = false;
		int nextTimer = msProcessTimers(d, &didWork);
		msProcessCallbacks(d, &didWork);
		if (didWork) { idleSweeps = 0; continue; }
		bool workersBusy = msPoolBusyPeek() > 0;
		if (nextTimer >= 0 || workersBusy) {
			idleSweeps = 0;
			msRunOnce(workersBusy && nextTimer < 0 ? 10 : nextTimer);
			continue;
		}
		/* Fully idle per the cheap checks — one non-blocking sweep catches
		 * cross-thread completions posted between the checks and here. */
		if (msRunOnce(0)) { idleSweeps = 0; continue; }
		idleSweeps++;
	}
}
