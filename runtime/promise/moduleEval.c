#include "runtime/core/system.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct msModuleWaiter {
	msModuleRecord* record;
	void* fut;
	struct msModuleWaiter* next;
} msModuleWaiter;

typedef struct msModuleAsyncRun {
	int32_t at;
	void* fut;
} msModuleAsyncRun;

static msModuleRecord* gRecords = NULL;
static int32_t gRecordCount = 0;
static int32_t* gRanOrder = NULL;
static int32_t gRanCount = 0;
static int32_t gAsyncOrdinal = 0;
static void* gAsyncBody = NULL;
static msModuleWaiter* gPendingHead = NULL;
static msModuleWaiter* gPendingTail = NULL;
static bool gTaskArmed = false;
static _Atomic(int) gPendingLock = 0;
void (*msModuleGuard)(msModuleRecord* record, void (*fn)(void)) = NULL;

static void msModuleLock(void) {
	while (atomic_exchange_explicit(&gPendingLock, 1, memory_order_acquire))
		while (atomic_load_explicit(&gPendingLock, memory_order_relaxed)) {}
}

static void msModuleUnlock(void) {
	atomic_store_explicit(&gPendingLock, 0, memory_order_release);
}

void msModuleTableRegister(msModuleRecord* records, int32_t count) {
	gRecords = records;
	gRecordCount = count;
	gRanOrder = (int32_t*)msMemAllocN0((size_t)count, sizeof(int32_t));
	for (int32_t i = 0; i < count; i++) records[i].cycleRoot = i;
}

static msModuleRecord* msModuleFind(const char* text, int64_t len) {
	for (int32_t i = 0; i < gRecordCount; i++) {
		const char* candidate = gRecords[i].name;
		if ((int64_t)strlen(candidate) == len && memcmp(candidate, text, (size_t)len) == 0) return &gRecords[i];
	}
	fprintf(stderr, "internal: import() of module '%.*s', which has no module record\n", (int)len, text);
	abort();
}

msModuleRecord* msModuleBind(const char* name, void (*init)(void), void (*deinit)(void)) {
	msModuleRecord* r = msModuleFind(name, (int64_t)strlen(name));
	r->init = init;
	r->deinit = deinit;
	return r;
}

static void msModuleCall(msModuleRecord* m, void (*fn)(void)) {
	if (msModuleGuard != NULL) msModuleGuard(m, fn);
	else fn();
}

static void* msModuleTakeError(void) {
	void* error = msCurrException != NULL ? (void*)msCurrException : (void*)msMakeError(msStringFromCStr("noproc"));
	msErr = false;
	msCurrException = NULL;
	return error;
}

static bool msModuleRunBody(msModuleRecord* m, void** error) {
	gRanOrder[gRanCount++] = (int32_t)(m - gRecords);
	if (m->init == NULL) return true;
	msModuleEvalDepth++;
	msModuleCall(m, m->init);
	msModuleEvalDepth--;
	if (!msErr) return true;
	*error = msModuleTakeError();
	return false;
}

static void msModuleSettle(void* fut, void* error) {
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

static void msModuleWait(msModuleRecord* r, msModuleWaiter* w) {
	w->next = (msModuleWaiter*)r->waiters;
	r->waiters = w;
}

static void msModuleSettleWaiters(msModuleRecord* r) {
	msModuleWaiter* reversed = (msModuleWaiter*)r->waiters;
	r->waiters = NULL;
	msModuleWaiter* w = NULL;
	while (reversed != NULL) {
		msModuleWaiter* next = reversed->next;
		reversed->next = w;
		w = reversed;
		reversed = next;
	}
	while (w != NULL) {
		msModuleWaiter* next = w->next;
		msModuleSettle(w->fut, r->error);
		free(w);
		w = next;
	}
}

static void msModuleRecordError(msModuleRecord* m, void* error) {
	msIncRef(error);
	m->error = error;
	m->status = MS_MODULE_EVALUATED;
	m->asyncEvaluation = false;
}

static void msModuleAddAsyncParent(msModuleRecord* r, int32_t parent) {
	r->asyncParents = (int32_t*)msRealloc(r->asyncParents, (size_t)r->asyncParentCount * sizeof(int32_t), (size_t)(r->asyncParentCount + 1) * sizeof(int32_t));
	r->asyncParents[r->asyncParentCount++] = parent;
}

static void msModuleExecuteAsync(msModuleRecord* m);

static void msModuleAsyncRejected(msModuleRecord* m, void* error) {
	if (m->status == MS_MODULE_EVALUATED && m->error != NULL) return;
	if (m->status != MS_MODULE_EVALUATING_ASYNC || !m->asyncEvaluation) {
		fprintf(stderr, "internal: module '%s' rejected while it is not evaluating asynchronously\n", m->name);
		abort();
	}
	msModuleRecordError(m, error);
	for (int32_t k = 0; k < m->asyncParentCount; k++) msModuleAsyncRejected(&gRecords[m->asyncParents[k]], error);
	msModuleSettleWaiters(m);
}

static bool msModuleListed(const int32_t* list, int32_t count, int32_t at) {
	for (int32_t k = 0; k < count; k++) if (list[k] == at) return true;
	return false;
}

static void msModuleGatherAvailableAncestors(msModuleRecord* m, int32_t* list, int32_t* count) {
	for (int32_t k = 0; k < m->asyncParentCount; k++) {
		int32_t at = m->asyncParents[k];
		msModuleRecord* p = &gRecords[at];
		if (gRecords[p->cycleRoot].error != NULL || msModuleListed(list, *count, at)) continue;
		if (p->status != MS_MODULE_EVALUATING_ASYNC || !p->asyncEvaluation || p->pendingAsyncDeps <= 0) {
			fprintf(stderr, "internal: module '%s' waits on a dependency in an inconsistent async state\n", p->name);
			abort();
		}
		p->pendingAsyncDeps--;
		if (p->pendingAsyncDeps == 0) {
			list[(*count)++] = at;
			if (!p->hasTLA) msModuleGatherAvailableAncestors(p, list, count);
		}
	}
}

static int msModuleOrdinalOrder(const void* a, const void* b) {
	int32_t x = gRecords[*(const int32_t*)a].asyncOrdinal;
	int32_t y = gRecords[*(const int32_t*)b].asyncOrdinal;
	return (x > y) - (x < y);
}

static void msModuleAsyncFulfilled(msModuleRecord* m) {
	if (m->status == MS_MODULE_EVALUATED && m->error != NULL) return;
	if (m->status != MS_MODULE_EVALUATING_ASYNC || !m->asyncEvaluation) {
		fprintf(stderr, "internal: module '%s' finished while it is not evaluating asynchronously\n", m->name);
		abort();
	}
	m->asyncEvaluation = false;
	m->status = MS_MODULE_EVALUATED;
	msModuleSettleWaiters(m);
	int32_t* list = (int32_t*)msMemAlloc((size_t)gRecordCount * sizeof(int32_t));
	int32_t count = 0;
	msModuleGatherAvailableAncestors(m, list, &count);
	qsort(list, (size_t)count, sizeof(int32_t), msModuleOrdinalOrder);
	for (int32_t k = 0; k < count; k++) {
		msModuleRecord* p = &gRecords[list[k]];
		if (p->status == MS_MODULE_EVALUATED && p->error != NULL) continue;
		if (p->hasTLA) {
			msModuleExecuteAsync(p);
			continue;
		}
		void* error = NULL;
		if (!msModuleRunBody(p, &error)) {
			msModuleAsyncRejected(p, error);
			msDecref(error);
			continue;
		}
		p->asyncEvaluation = false;
		p->status = MS_MODULE_EVALUATED;
		msModuleSettleWaiters(p);
	}
	free(list);
}

static void msModuleAsyncSettled(void* env) {
	msModuleAsyncRun* run = (msModuleAsyncRun*)env;
	msModuleRecord* m = &gRecords[run->at];
	msFutureBase* f = (msFutureBase*)run->fut;
	if (f->failed || f->cancelled) {
		void* error = f->error != NULL ? f->error : msMakeError(msStringFromCStr("noproc"));
		f->error = NULL;
		msModuleAsyncRejected(m, error);
		msDecref(error);
	} else {
		msModuleAsyncFulfilled(m);
	}
	msFutureDrcDestroy(run->fut);
	free(run);
}

static void msModuleExecuteAsync(msModuleRecord* m) {
	void* error = NULL;
	gAsyncBody = NULL;
	bool ran = msModuleRunBody(m, &error);
	void* fut = gAsyncBody;
	gAsyncBody = NULL;
	if (!ran) {
		if (fut != NULL) msFutureDrcDestroy(fut);
		msModuleAsyncRejected(m, error);
		msDecref(error);
		return;
	}
	if (fut == NULL) {
		fprintf(stderr, "internal: module '%s' has a top-level await but its body started no async routine\n", m->name);
		abort();
	}
	msModuleAsyncRun* run = (msModuleAsyncRun*)msMemAlloc(sizeof(msModuleAsyncRun));
	run->at = (int32_t)(m - gRecords);
	run->fut = fut;
	msFutureAddCallback(fut, (msClosure){ .fn = (msClosureFn)msModuleAsyncSettled, .env = run });
}

void msModuleAsyncBody(void* fut) {
	if (gAsyncBody != NULL) {
		fprintf(stderr, "internal: a module body started a second async routine\n");
		abort();
	}
	msIncRef(fut);
	gAsyncBody = fut;
}

static int32_t msModuleInnerEvaluate(int32_t at, int32_t* stack, int32_t* depth, int32_t index, void** error, bool* thrown) {
	msModuleRecord* m = &gRecords[at];
	if (m->status == MS_MODULE_EVALUATING_ASYNC || m->status == MS_MODULE_EVALUATED) {
		if (m->error != NULL) { *error = m->error; return -1; }
		return index;
	}
	if (m->status == MS_MODULE_EVALUATING) return index;
	m->status = MS_MODULE_EVALUATING;
	m->dfsIndex = index;
	m->dfsAncestorIndex = index;
	m->pendingAsyncDeps = 0;
	index++;
	stack[(*depth)++] = at;
	for (int32_t k = 0; k < m->requestedCount; k++) {
		int32_t req = m->requested[k];
		index = msModuleInnerEvaluate(req, stack, depth, index, error, thrown);
		if (index < 0) return -1;
		msModuleRecord* r = &gRecords[req];
		if (r->status == MS_MODULE_EVALUATING) {
			if (r->dfsAncestorIndex < m->dfsAncestorIndex) m->dfsAncestorIndex = r->dfsAncestorIndex;
		} else {
			r = &gRecords[r->cycleRoot];
			if (r->error != NULL) { *error = r->error; return -1; }
		}
		if (r->asyncEvaluation) {
			m->pendingAsyncDeps++;
			msModuleAddAsyncParent(r, at);
		}
	}
	if (m->pendingAsyncDeps > 0 || m->hasTLA) {
		m->asyncEvaluation = true;
		m->asyncOrdinal = gAsyncOrdinal++;
		if (m->pendingAsyncDeps == 0) msModuleExecuteAsync(m);
	} else if (!msModuleRunBody(m, error)) {
		*thrown = true;
		return -1;
	}
	if (m->dfsAncestorIndex == m->dfsIndex) {
		int32_t popped;
		do {
			popped = stack[--(*depth)];
			msModuleRecord* p = &gRecords[popped];
			p->cycleRoot = at;
			p->status = p->asyncEvaluation ? MS_MODULE_EVALUATING_ASYNC : MS_MODULE_EVALUATED;
		} while (popped != at);
	}
	return index;
}

static void msModuleEvaluate(msModuleWaiter* w) {
	msModuleRecord* r = w->record;
	if (r->status == MS_MODULE_EVALUATING_ASYNC || r->status == MS_MODULE_EVALUATED) r = &gRecords[r->cycleRoot];
	if (r->status == MS_MODULE_PENDING) {
		int32_t* stack = (int32_t*)msMemAlloc((size_t)gRecordCount * sizeof(int32_t));
		int32_t depth = 0;
		void* error = NULL;
		bool thrown = false;
		bool failed = msModuleInnerEvaluate((int32_t)(r - gRecords), stack, &depth, 0, &error, &thrown) < 0;
		if (failed) {
			for (int32_t k = 0; k < depth; k++) msModuleRecordError(&gRecords[stack[k]], error);
		}
		free(stack);
		if (failed) {
			msModuleSettle(w->fut, error);
			if (thrown) msDecref(error);
			free(w);
			return;
		}
	}
	if (r->status == MS_MODULE_EVALUATING_ASYNC && r->error == NULL) {
		msModuleWait(r, w);
		return;
	}
	if (r->status != MS_MODULE_EVALUATED) {
		fprintf(stderr, "internal: import() of module '%s' settled while its evaluation is unfinished\n", r->name);
		abort();
	}
	msModuleSettle(w->fut, r->error);
	free(w);
}

static void msModuleArmTask(void);

static void msModuleRunPending(void* env) {
	(void)env;
	if (msModuleEvalDepth > 0) {
		msModuleArmTask();
		return;
	}
	msModuleLock();
	msModuleWaiter* w = gPendingHead;
	gPendingHead = NULL;
	gPendingTail = NULL;
	gTaskArmed = false;
	msModuleUnlock();
	while (w != NULL) {
		msModuleWaiter* next = w->next;
		w->next = NULL;
		msModuleEvaluate(w);
		w = next;
	}
}

static void msModuleArmTask(void) {
	msSetTimeout((msClosure){ .fn = (msClosureFn)msModuleRunPending, .env = NULL }, 0);
}

void* msModuleImport(msString name) {
	msModuleRecord* r = msModuleFind(name.p != NULL ? name.p->data : "", name.len);
	void* fut = msFutureCreate();
	msIncRef(fut);
#if MS_FUTURE_SUBMIT_REF
	msFuturePublishCrossThread(fut);
#endif
#ifdef _WIN32
	extern void msEnsureLoopChannel(void);
	msEnsureLoopChannel();
#endif
	msModuleWaiter* w = (msModuleWaiter*)msMemAlloc(sizeof(msModuleWaiter));
	w->record = r;
	w->fut = fut;
	w->next = NULL;
	msModuleLock();
	if (gPendingTail == NULL) gPendingHead = w;
	else gPendingTail->next = w;
	gPendingTail = w;
	bool arm = !gTaskArmed;
	gTaskArmed = true;
	msModuleUnlock();
	if (arm) msModuleArmTask();
	return fut;
}

void msModuleDeinitLazy(void) {
	for (int32_t k = gRanCount - 1; k >= 0; k--) {
		msModuleRecord* r = &gRecords[gRanOrder[k]];
		if (r->deinit != NULL) msModuleCall(r, r->deinit);
	}
	for (int32_t i = 0; i < gRecordCount; i++) {
		msModuleRecord* r = &gRecords[i];
		if (r->error != NULL) msDecref(r->error);
		r->error = NULL;
		free(r->asyncParents);
		r->asyncParents = NULL;
		r->asyncParentCount = 0;
		msModuleWaiter* w = (msModuleWaiter*)r->waiters;
		r->waiters = NULL;
		while (w != NULL) {
			msModuleWaiter* next = w->next;
			msFutureDrcDestroy(w->fut);
			free(w);
			w = next;
		}
	}
	free(gRanOrder);
	gRanOrder = NULL;
	gRanCount = 0;
}
