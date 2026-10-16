#include "runtime/core/system.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct msModuleWaiter {
	msModuleRecord* record;
	void* fut;
	struct msModuleWaiter* next;
} msModuleWaiter;

static msModuleRecord* gRecords = NULL;
static int32_t gRecordCount = 0;
static int32_t* gRanOrder = NULL;
static int32_t gRanCount = 0;
static msModuleWaiter* gPendingHead = NULL;
static msModuleWaiter* gPendingTail = NULL;
static bool gTaskArmed = false;
static _Atomic(int) gPendingLock = 0;

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
	gRanOrder = (int32_t*)calloc((size_t)count, sizeof(int32_t));
}

static msModuleRecord* msModuleFind(msString name) {
	const char* text = name.p != NULL ? name.p->data : "";
	for (int32_t i = 0; i < gRecordCount; i++) {
		const char* candidate = gRecords[i].name;
		if ((int64_t)strlen(candidate) == name.len && memcmp(candidate, text, (size_t)name.len) == 0) return &gRecords[i];
	}
	fprintf(stderr, "internal: import() of module '%.*s', which has no module record\n", (int)name.len, text);
	abort();
}

static int32_t msModuleInnerEvaluate(int32_t at, int32_t* stack, int32_t* depth, int32_t index, void** error, bool* thrown) {
	msModuleRecord* m = &gRecords[at];
	if (m->status == MS_MODULE_EVALUATED) {
		if (m->error != NULL) { *error = m->error; return -1; }
		return index;
	}
	if (m->status == MS_MODULE_EVALUATING) return index;
	m->status = MS_MODULE_EVALUATING;
	m->dfsIndex = index;
	m->dfsAncestorIndex = index;
	index++;
	stack[(*depth)++] = at;
	for (int32_t k = 0; k < m->requestedCount; k++) {
		int32_t req = m->requested[k];
		index = msModuleInnerEvaluate(req, stack, depth, index, error, thrown);
		if (index < 0) return -1;
		msModuleRecord* r = &gRecords[req];
		if (r->status == MS_MODULE_EVALUATING && r->dfsAncestorIndex < m->dfsAncestorIndex) m->dfsAncestorIndex = r->dfsAncestorIndex;
	}
	gRanOrder[gRanCount++] = at;
	if (m->init != NULL) {
		msModuleEvalDepth++;
		m->init();
		msModuleEvalDepth--;
		if (msErr) {
			*error = msCurrException != NULL ? (void*)msCurrException : (void*)msMakeError(msStringFromCStr("noproc"));
			*thrown = true;
			msErr = false;
			msCurrException = NULL;
			return -1;
		}
	}
	if (m->dfsAncestorIndex == m->dfsIndex) {
		int32_t popped;
		do {
			popped = stack[--(*depth)];
			gRecords[popped].status = MS_MODULE_EVALUATED;
		} while (popped != at);
	}
	return index;
}

static void msModuleEvaluate(msModuleRecord* m) {
	int32_t* stack = (int32_t*)malloc((size_t)gRecordCount * sizeof(int32_t));
	int32_t depth = 0;
	void* error = NULL;
	bool thrown = false;
	if (msModuleInnerEvaluate((int32_t)(m - gRecords), stack, &depth, 0, &error, &thrown) < 0) {
		for (int32_t k = 0; k < depth; k++) {
			msModuleRecord* r = &gRecords[stack[k]];
			msIncRef(error);
			r->status = MS_MODULE_EVALUATED;
			r->error = error;
		}
		if (thrown) msDecref(error);
	}
	free(stack);
}

static void msModuleSettle(msModuleWaiter* w) {
	msModuleRecord* r = w->record;
	if (r->status != MS_MODULE_EVALUATED) {
		fprintf(stderr, "internal: import() of module '%s' settled while its evaluation is unfinished\n", r->name);
		abort();
	}
	void* error = r->error;
	if (error != NULL) msIncRef(error);
#if MS_FUTURE_SUBMIT_REF
	msFutureBase* f = (msFutureBase*)w->fut;
	if (error != NULL) {
		f->error = error;
		f->failed = true;
	} else {
		((msFuture_ptr*)w->fut)->value = (void*)(intptr_t)1;
	}
	atomic_store_explicit(&f->finished, true, memory_order_release);
	msNotifyFutureComplete();
	msCompletionQueuePushOwned(w->fut, error != NULL, error);
#else
	if (error != NULL) msFutureFail(w->fut, error);
	else msFutureComplete(w->fut, (void*)(intptr_t)1);
	msFutureDrcDestroy(w->fut);
#endif
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
		if (w->record->status == MS_MODULE_PENDING) msModuleEvaluate(w->record);
		msModuleSettle(w);
		msModuleWaiter* next = w->next;
		free(w);
		w = next;
	}
}

static void msModuleArmTask(void) {
	msSetTimeout((msClosure){ .fn = (msClosureFn)msModuleRunPending, .env = NULL }, 0);
}

void* msModuleImport(msString name) {
	msModuleRecord* r = msModuleFind(name);
	void* fut = msFutureCreate();
	msIncRef(fut);
#if MS_FUTURE_SUBMIT_REF
	((msFutureBase*)fut)->crossThreadPublished = true;
#endif
#ifdef _WIN32
	extern void msEnsureLoopChannel(void);
	msEnsureLoopChannel();
#endif
	msModuleWaiter* w = (msModuleWaiter*)malloc(sizeof(msModuleWaiter));
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
		if (r->deinit != NULL) r->deinit();
	}
	for (int32_t i = 0; i < gRecordCount; i++) {
		if (gRecords[i].error != NULL) msDecref(gRecords[i].error);
		gRecords[i].error = NULL;
	}
	free(gRanOrder);
	gRanOrder = NULL;
	gRanCount = 0;
}
