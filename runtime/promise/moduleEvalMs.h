/*
 * C primitives under the module evaluator written in MetaScript (std/core/promise/moduleEval.cms):
 * the field reads, macros, thread-local flags and allocator calls a .cms body cannot name itself.
 */
#ifndef MS_MODULE_EVAL_MS_H
#define MS_MODULE_EVAL_MS_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "runtime/core/system.h"
#include "runtime/promise/locked.h"

#define MS_PTR sizeof(void*)
#define MS_UP(x) (((x) + MS_PTR - 1) / MS_PTR * MS_PTR)
#define MS_STATUS (4 * MS_PTR + 4)
#define MS_ERROR MS_UP(MS_STATUS + 16)
#define MS_PARENTS MS_UP(MS_ERROR + MS_PTR + 12)
#define MS_WAITERS MS_UP(MS_PARENTS + MS_PTR + 8)
_Static_assert(offsetof(msModuleRecord, name) == 0 && offsetof(msModuleRecord, init) == MS_PTR && offsetof(msModuleRecord, deinit) == 2 * MS_PTR
	&& offsetof(msModuleRecord, requested) == 3 * MS_PTR && offsetof(msModuleRecord, requestedCount) == 4 * MS_PTR
	&& offsetof(msModuleRecord, status) == MS_STATUS && offsetof(msModuleRecord, hasTLA) == MS_STATUS + 4
	&& offsetof(msModuleRecord, dfsIndex) == MS_STATUS + 8 && offsetof(msModuleRecord, dfsAncestorIndex) == MS_STATUS + 12
	&& offsetof(msModuleRecord, error) == MS_ERROR && offsetof(msModuleRecord, asyncEvaluation) == MS_ERROR + MS_PTR
	&& offsetof(msModuleRecord, asyncOrdinal) == MS_ERROR + MS_PTR + 4 && offsetof(msModuleRecord, pendingAsyncDeps) == MS_ERROR + MS_PTR + 8
	&& offsetof(msModuleRecord, asyncParents) == MS_PARENTS && offsetof(msModuleRecord, asyncParentCount) == MS_PARENTS + MS_PTR
	&& offsetof(msModuleRecord, cycleRoot) == MS_PARENTS + MS_PTR + 4 && offsetof(msModuleRecord, waiters) == MS_WAITERS
	&& sizeof(msModuleRecord) == MS_WAITERS + MS_PTR, "ModuleRecord in moduleEval.cms");
#undef MS_PTR
#undef MS_UP
#undef MS_STATUS
#undef MS_ERROR
#undef MS_PARENTS
#undef MS_WAITERS

void msModuleAsyncSettled(void* env);
void msModuleRunPending(void* env);

static msTicketLock gModuleQueueLock = { 0, 0 };
static inline void msModuleQueueLock(void) { msTicketLockAcquire(&gModuleQueueLock); }
static inline void msModuleQueueUnlock(void) { msTicketLockRelease(&gModuleQueueLock); }

static inline int32_t msModuleIndexOf(void* base, void* record) {
	return (int32_t)((msModuleRecord*)record - (msModuleRecord*)base);
}

static inline const void* msModuleStringText(msString name) { return msStrData(&name); }
static inline int64_t msModuleStringLen(msString name) { return msStrLen(name); }
static inline int64_t msModuleCStrLen(const void* text) { return (int64_t)strlen((const char*)text); }

static inline bool msModuleNameIs(const void* candidate, const void* text, int64_t len) {
	return (int64_t)strlen((const char*)candidate) == len && memcmp(candidate, text, (size_t)len) == 0;
}

static inline void msModuleAbort(const void* name, msString what) {
	fprintf(stderr, "internal: module '%s' %.*s\n", (const char*)name, (int)msStrLen(what), msStrData(&what));
	abort();
}

static inline void msModuleAbortNoRecord(const void* text, int64_t len) {
	fprintf(stderr, "internal: import() of module '%.*s', which has no module record\n", (int)len, (const char*)text);
	abort();
}

static inline void msModuleAbortPlain(msString what) {
	fprintf(stderr, "internal: %.*s\n", (int)msStrLen(what), msStrData(&what));
	abort();
}

static inline void msModuleEvalEnter(void) { msModuleEvalDepth++; }
static inline void msModuleEvalLeave(void) { msModuleEvalDepth--; }
static inline bool msModuleEvaluatingBody(void) { return msModuleEvalDepth > 0; }

static inline void msModuleCall(void* record, void* fn) {
	if (msModuleGuard != NULL) msModuleGuard((msModuleRecord*)record, (void (*)(void))fn);
	else ((void (*)(void))fn)();
}

static inline bool msModuleRaised(void) { return msErr; }

static inline void* msModuleTakeError(void) {
	void* error = msCurrException != NULL ? (void*)msCurrException : (void*)msMakeError(msStringFromCStr("noproc"));
	msErr = false;
	msCurrException = NULL;
	return error;
}

static inline void msModuleHold(void* p) { msIncRef(p); }
static inline void msModuleRelease(void* p) { msDecrefAny(p); }
static inline void msModuleDestroyFuture(void* fut) { msFutureDrcDestroy(fut); }

static inline bool msModuleFutureRejected(void* fut) { return ((msFutureBase*)fut)->failed || ((msFutureBase*)fut)->cancelled; }

static inline void* msModuleFutureTakeError(void* fut) {
	msFutureBase* f = (msFutureBase*)fut;
	void* error = f->error != NULL ? f->error : msMakeError(msStringFromCStr("noproc"));
	f->error = NULL;
	return error;
}

static inline void msModuleSettle(void* fut, void* error) {
	if (error != NULL) msIncRef(error);
#if MS_FUTURE_SUBMIT_REF
	msFutureBase* f = (msFutureBase*)fut;
	if (error != NULL) {
		f->error = error;
		f->failed = true;
	} else {
		((msFuture_ptr*)fut)->value = (void*)(intptr_t)1;
	}
	atomic_store_explicit(&f->finished, true, memory_order_release);
	msNotifyFutureComplete();
	msCompletionQueuePushOwned(fut, error != NULL, error);
#else
	if (error != NULL) msFutureFail(fut, error);
	else msFutureComplete(fut, (void*)(intptr_t)1);
	msFutureDrcDestroy(fut);
#endif
}

static inline void* msModuleImportFuture(void) {
	void* fut = msFutureCreate();
	msIncRef(fut);
#if MS_FUTURE_SUBMIT_REF
	msFuturePublishCrossThread(fut);
#endif
#ifdef _WIN32
	extern void msEnsureLoopChannel(void);
	msEnsureLoopChannel();
#endif
	return fut;
}

static inline void msModuleWatch(void* fut, void* env) {
	msFutureAddCallback(fut, (msClosure){ .fn = (msClosureFn)msModuleAsyncSettled, .env = env });
}

static inline void msModuleArmTask(void) {
	msSetTimeout((msClosure){ .fn = (msClosureFn)msModuleRunPending, .env = NULL }, 0);
}

#endif
