/*
 * MetaScript ORC — Cycle Collector Implementation
 *
 * Bacon's synchronous trial deletion algorithm:
 *   Phase 1 (markGray):     Tentatively decrement suspects, color gray
 *   Phase 2 (scan):         If rc > 0 → restore to black; else → mark white
 *   Phase 3 (collectWhite): Free white objects
 *
 * Root registry uses O(1) swap-last for removal via rootIdx.
 * Adaptive threshold: 128 default, increase if <50% freed, decrease otherwise.
 */

/* ===== DRC Ledger (test-only, -DMS_DRC_LEDGER) — gc-mode independent ===== */
#ifdef MS_DRC_LEDGER
#include "runtime/drc.h"
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>

/* Open-addressing pointer set: holds objects finalized (destroyFn dispatched)
 * whose slab slot has not yet been re-handed-out. A 2nd finalize of a pointer
 * still in the set = double-destroy → abort. Alloc clears it (slot reuse). */
#ifndef MS_LEDGER_SET_SIZE
#define MS_LEDGER_SET_SIZE (1u << 20)
#endif
#define MS_LEDGER_SET_MASK (MS_LEDGER_SET_SIZE - 1)
enum { MS_LSLOT_EMPTY = 0, MS_LSLOT_USED = 1, MS_LSLOT_TOMB = 2 };
static void*   gLedgerKey[MS_LEDGER_SET_SIZE];
static uint8_t gLedgerState[MS_LEDGER_SET_SIZE];

#define MS_LEDGER_ROWS 4096
static const msTypeInfo* gLedgerType[MS_LEDGER_ROWS];
static long        gLedgerAllocN[MS_LEDGER_ROWS];
static long        gLedgerDestroyN[MS_LEDGER_ROWS];
static int         gLedgerRowCount = 0;

static pthread_mutex_t gLedgerMutex = PTHREAD_MUTEX_INITIALIZER;
static int gLedgerAtexit = 0;

static inline size_t msLedgerHash(void* p) {
	uintptr_t x = (uintptr_t)p;
	x ^= x >> 33; x *= 0xff51afd7ed558ccdULL; x ^= x >> 33;
	return (size_t)(x & MS_LEDGER_SET_MASK);
}
static int msLedgerSetContains(void* p) {
	size_t i = msLedgerHash(p);
	for (size_t n = 0; n < MS_LEDGER_SET_SIZE; n++) {
		if (gLedgerState[i] == MS_LSLOT_EMPTY) return 0;
		if (gLedgerState[i] == MS_LSLOT_USED && gLedgerKey[i] == p) return 1;
		i = (i + 1) & MS_LEDGER_SET_MASK;
	}
	return 0;
}
static void msLedgerSetInsert(void* p) {
	size_t i = msLedgerHash(p);
	for (size_t n = 0; n < MS_LEDGER_SET_SIZE; n++) {
		if (gLedgerState[i] != MS_LSLOT_USED) { gLedgerKey[i] = p; gLedgerState[i] = MS_LSLOT_USED; return; }
		if (gLedgerKey[i] == p) return;
		i = (i + 1) & MS_LEDGER_SET_MASK;
	}
	fprintf(stderr, "\nNIM-GUARD LEDGER: pointer set full — raise MS_LEDGER_SET_SIZE\n");
	fflush(stderr);
	abort();
}
static void msLedgerSetRemove(void* p) {
	size_t i = msLedgerHash(p);
	for (size_t n = 0; n < MS_LEDGER_SET_SIZE; n++) {
		if (gLedgerState[i] == MS_LSLOT_EMPTY) return;
		if (gLedgerState[i] == MS_LSLOT_USED && gLedgerKey[i] == p) { gLedgerState[i] = MS_LSLOT_TOMB; return; }
		i = (i + 1) & MS_LEDGER_SET_MASK;
	}
}
static int msLedgerRowIdx(const msTypeInfo* type) {
	for (int i = 0; i < gLedgerRowCount; i++) {
		if (gLedgerType[i] == type) return i;
	}
	if (gLedgerRowCount < MS_LEDGER_ROWS) {
		int i = gLedgerRowCount++;
		gLedgerType[i] = type; gLedgerAllocN[i] = 0; gLedgerDestroyN[i] = 0;
		return i;
	}
	return -1;
}
static const char* msLedgerRowName(const msTypeInfo* type) {
	if (type == NULL) return "<untyped>";
	return type->name != NULL ? type->name : "<unnamed>";
}
/* TOTAL prints even at zero counts: the SAN corpus runner treats "no LEDGER
 * line at all" as instrumentation loss, and a program whose only allocations
 * were baked into static const cells makes no ledger entries. */
static void msLedgerDump(void) {
	pthread_mutex_lock(&gLedgerMutex);
	long totalA = 0, totalD = 0;
	for (int i = 0; i < gLedgerRowCount; i++) {
		fprintf(stderr, "LEDGER %s alloc=%ld destroy=%ld\n",
			msLedgerRowName(gLedgerType[i]), gLedgerAllocN[i], gLedgerDestroyN[i]);
		totalA += gLedgerAllocN[i];
		totalD += gLedgerDestroyN[i];
	}
	fprintf(stderr, "LEDGER TOTAL alloc=%ld destroy=%ld\n", totalA, totalD);
	fflush(stderr);
	pthread_mutex_unlock(&gLedgerMutex);
}
__attribute__((constructor)) static void msLedgerRegisterDump(void) {
	if (!gLedgerAtexit) { gLedgerAtexit = 1; atexit(msLedgerDump); }
}
void msLedgerAlloc(void* p, const msTypeInfo* type) {
	if (p == NULL) return;
	pthread_mutex_lock(&gLedgerMutex);
	if (!gLedgerAtexit) { gLedgerAtexit = 1; atexit(msLedgerDump); }
	msLedgerSetRemove(p);   /* slab slot reused → fresh object */
	int idx = msLedgerRowIdx(type);
	if (idx >= 0) gLedgerAllocN[idx]++;
	pthread_mutex_unlock(&gLedgerMutex);
}
void msLedgerDestroy(void* p, const msTypeInfo* type) {
	if (p == NULL) return;
	pthread_mutex_lock(&gLedgerMutex);
	if (msLedgerSetContains(p)) {
		fprintf(stderr, "\nNIM-GUARD LEDGER: DOUBLE-DESTROY of %s at %p\n", msLedgerRowName(type), p);
		fflush(stderr);
		abort();
	}
	msLedgerSetInsert(p);
	int idx = msLedgerRowIdx(type);
	if (idx >= 0) gLedgerDestroyN[idx]++;
	pthread_mutex_unlock(&gLedgerMutex);
}
#endif  /* MS_DRC_LEDGER */

/* ===== DRC flow counters (perf-only, -DMS_DRC_STAT) ===== */
#ifdef MS_DRC_STAT
#include "runtime/drc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#define MS_DS_TYPE_SLOTS 1024
#define MS_DS_TOP_TYPES 32

typedef struct msDsBlock {
	uint64_t c[MS_DS_COUNT];
	uint64_t cycOther;
	const msTypeInfo* cycType[MS_DS_TYPE_SLOTS];
	uint64_t cycCount[MS_DS_TYPE_SLOTS];
	struct msDsBlock* next;
} msDsBlock;

static msDsBlock* gDsBlocks = NULL;
static pthread_mutex_t gDsMutex = PTHREAD_MUTEX_INITIALIZER;
static _Thread_local msDsBlock* tDsBlock = NULL;

static msDsBlock* msDsLocal(void) {
	if (tDsBlock != NULL) return tDsBlock;
	msDsBlock* b = (msDsBlock*)calloc(1, sizeof(msDsBlock));
	if (b == NULL) abort();
	pthread_mutex_lock(&gDsMutex);
	b->next = gDsBlocks;
	gDsBlocks = b;
	pthread_mutex_unlock(&gDsMutex);
	tDsBlock = b;
	return b;
}

void msDrcStatAdd(int id, uint64_t n) { msDsLocal()->c[id] += n; }

void msDrcStatCycle(const msTypeInfo* type) {
	msDsBlock* b = msDsLocal();
	b->c[MS_DS_CYC_REG]++;
	size_t i = ((uintptr_t)type >> 4) & (MS_DS_TYPE_SLOTS - 1);
	for (size_t n = 0; n < MS_DS_TYPE_SLOTS; n++) {
		if (b->cycType[i] == type || b->cycType[i] == NULL) {
			b->cycType[i] = type;
			b->cycCount[i]++;
			return;
		}
		i = (i + 1) & (MS_DS_TYPE_SLOTS - 1);
	}
	b->cycOther++;
}

typedef struct { const char* name; uint64_t count; } msDsTypeRow;

static int msDsRowCmp(const void* a, const void* b) {
	const msDsTypeRow* x = (const msDsTypeRow*)a;
	const msDsTypeRow* y = (const msDsTypeRow*)b;
	if (x->count != y->count) return x->count < y->count ? 1 : -1;
	return strcmp(x->name, y->name);
}

static const char* msDsFlowNames[MS_DS_COUNT] = {
	"alloc", "alloc", "free", "rc.inc", "rc.dec", "rc.incAtomic", "rc.decAtomic", "rc.incCyclic",
	"orc.decLast", "orc.decLast.true", "cycle.register", "collect", "collect.traced", "collect.freed"
};

/* Runs from atexit, registered before the pool's, so it runs after the pool joined its workers. */
static void msDsDump(void) {
	const char* path = getenv("MS_DRC_STAT");
	if (path == NULL || path[0] == '\0') return;
	FILE* f = fopen(path, "a");
	if (f == NULL) return;
	pthread_mutex_lock(&gDsMutex);
	uint64_t total[MS_DS_COUNT] = {0};
	uint64_t other = 0;
	size_t cap = 0;
	for (msDsBlock* b = gDsBlocks; b != NULL; b = b->next) {
		for (int i = 0; i < MS_DS_COUNT; i++) total[i] += b->c[i];
		other += b->cycOther;
		for (int i = 0; i < MS_DS_TYPE_SLOTS; i++) if (b->cycType[i] != NULL) cap++;
	}
	msDsTypeRow* rows = (msDsTypeRow*)calloc(cap + 1, sizeof(msDsTypeRow));
	size_t nrows = 0;
	for (msDsBlock* b = gDsBlocks; b != NULL; b = b->next) {
		for (int i = 0; i < MS_DS_TYPE_SLOTS; i++) {
			if (b->cycType[i] == NULL) continue;
			const char* name = b->cycType[i]->name != NULL ? b->cycType[i]->name : "<unnamed>";
			size_t k = 0;
			while (k < nrows && strcmp(rows[k].name, name) != 0) k++;
			if (k == nrows) { rows[k].name = name; nrows++; }
			rows[k].count += b->cycCount[i];
		}
	}
	qsort(rows, nrows, sizeof(msDsTypeRow), msDsRowCmp);
	static const char* metric[MS_DS_COUNT] = {"count", "bytes"};
	for (int i = 0; i < MS_DS_COUNT; i++) {
		fprintf(f, "drc\t%s\t%s\t%llu\n", msDsFlowNames[i],
			i == MS_DS_ALLOC_BYTES ? metric[1] : metric[0], (unsigned long long)total[i]);
	}
	fprintf(f, "drc\trc.decCyclic\tcount\t%llu\n", (unsigned long long)total[MS_DS_ORC_DEC_LAST]);
	for (size_t k = 0; k < nrows; k++) {
		if (k < MS_DS_TOP_TYPES) fprintf(f, "drc\tcycle.register.%s\tcount\t%llu\n", rows[k].name, (unsigned long long)rows[k].count);
		else other += rows[k].count;
	}
	fprintf(f, "drc\tcycle.register.other\tcount\t%llu\n", (unsigned long long)other);
	free(rows);
	pthread_mutex_unlock(&gDsMutex);
	fclose(f);
}
__attribute__((constructor)) static void msDsRegisterDump(void) { atexit(msDsDump); }
#endif  /* MS_DRC_STAT */

#ifndef MSGC_MANUAL
#include "runtime/drc.h"

_Thread_local msSlab msSlabTLS;
MS_TLS_PUBLISH(msSlabTLS)

#include <stdio.h>
#if defined(_WIN32)
#include <windows.h>
#else
#include <pthread.h>
#endif
#if defined(__linux__)
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>
#endif

enum { MS_DROP_FRAME = 1, MS_DROP_CONT = 2, MS_DROP_TAG = 3 };

static void msDropBounds(msDropState* d) {
	uintptr_t lo = 0;
	uintptr_t hi = 0;
#if defined(__APPLE__)
	pthread_t self = pthread_self();
	hi = (uintptr_t)pthread_get_stackaddr_np(self);
	lo = hi - (uintptr_t)pthread_get_stacksize_np(self);
#elif defined(_WIN32)
	ULONG_PTR low = 0;
	ULONG_PTR high = 0;
	GetCurrentThreadStackLimits(&low, &high);
	lo = (uintptr_t)low;
	hi = (uintptr_t)high;
#elif defined(__linux__)
	pthread_attr_t attr;
	if (pthread_getattr_np(pthread_self(), &attr) == 0) {
		void* addr = NULL;
		size_t size = 0;
		if (pthread_attr_getstack(&attr, &addr, &size) == 0) {
			lo = (uintptr_t)addr;
			hi = lo + size;
		}
		pthread_attr_destroy(&attr);
	}
	struct rlimit limit;
	if (hi != 0 && getpid() == (pid_t)syscall(SYS_gettid) && getrlimit(RLIMIT_STACK, &limit) == 0
		&& limit.rlim_cur != RLIM_INFINITY && hi - lo > (uintptr_t)limit.rlim_cur) {
		lo = hi - (uintptr_t)limit.rlim_cur;
	}
#endif
	uintptr_t size = hi > lo ? hi - lo : 0;
	uintptr_t headroom = size / 8;
	if (headroom < 64 * 1024) headroom = 64 * 1024;
	if (headroom > 1024 * 1024) headroom = 1024 * 1024;
	if (size <= 2 * headroom) {
		d->floor = UINTPTR_MAX;
		d->span = 1;
		return;
	}
	d->floor = lo + headroom;
	d->span = hi - d->floor;
}

static void msDropReserve(msDropState* d, int32_t extra) {
	if (d->len + extra <= d->cap) return;
	int32_t cap = d->cap < 64 ? 64 : d->cap;
	while (cap < d->len + extra) cap *= 2;
	msDropSlot* data = (msDropSlot*)realloc(d->data, (size_t)cap * sizeof(msDropSlot));
	if (data == NULL) {
		fprintf(stderr, "fatal: out of memory growing the drop stack to %d entries\n", cap);
		abort();
	}
	d->data = data;
	d->cap = cap;
}

static void msDropReverse(msDropSlot* a, msDropSlot* b) {
	while (a < b) {
		msDropSlot swap = *a;
		*a++ = *b;
		*b-- = swap;
	}
}

static void msDropRun(msSlab* s, void* root) {
	msDropState* d = &s->drop;
	void* const outerCur = d->cur;
	const int32_t outerBase = d->base;
	const int32_t floor = d->len;
	void* p = root;
	for (;;) {
		d->cur = p;
		d->base = d->len;
		MS_DESTROY_DISPATCH(msHeader(p)->type, p);
		if (d->len == d->base) {
			msDropDispose(s, p);
		} else {
			msDropReserve(d, 1);
			d->data[d->len++].p = (void*)((uintptr_t)p | MS_DROP_FRAME);
			msDropReverse(d->data + d->base, d->data + d->len - 1);
		}
		p = NULL;
		while (p == NULL && d->len > floor) {
			void* item = d->data[--d->len].p;
			uintptr_t tag = (uintptr_t)item & MS_DROP_TAG;
			void* obj = (void*)((uintptr_t)item & ~(uintptr_t)MS_DROP_TAG);
			if (tag == 0) {
				p = obj;
			} else if (tag == MS_DROP_FRAME) {
				msDropDispose(s, obj);
			} else {
				msDropCont fn = d->data[--d->len].fn;
				int32_t resume = (int32_t)d->data[--d->len].n;
				d->cur = obj;
				d->base = d->len;
				fn(obj, resume);
				if (d->len - d->base > 1) msDropReverse(d->data + d->base, d->data + d->len - 1);
			}
		}
		if (p == NULL) break;
	}
	d->cur = outerCur;
	d->base = outerBase;
	if (outerCur == NULL && floor == 0) {
		free(d->data);
		d->data = NULL;
		d->cap = 0;
	}
}

bool msDropEdgeSlow(void* owner, void* p) {
	msSlab* s = &msSlabTLS;
	msDropState* d = &s->drop;
	if (d->span == 0) {
		msDropBounds(d);
		if (msStackPointer() - d->floor < d->span) {
			MS_DESTROY_DISPATCH(msHeader(p)->type, p);
			msDropDispose(s, p);
			return false;
		}
	}
	if (owner != NULL && owner == d->cur) {
		msDropReserve(d, 1);
		d->data[d->len++].p = p;
		return true;
	}
	msDropRun(s, p);
	return false;
}

void msDropDefer(void* owner, msDropCont fn, int32_t resume) {
	msDropState* d = &msSlabTLS.drop;
	msDropReserve(d, 3);
	d->data[d->len++].p = (void*)((uintptr_t)owner | MS_DROP_CONT);
	d->data[d->len++].fn = fn;
	d->data[d->len++].n = resume;
}

void msDropRestore(const msDropState* saved) {
	msDropState* d = &msSlabTLS.drop;
	d->cur = saved->cur;
	d->len = saved->len;
	d->base = saved->base;
}
#endif

#ifdef MSGC_ORC

#include "runtime/drc.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* ===== CellSeq Operations ===== */

void msCellSeqInit(msCellSeq* s) {
	s->data = NULL;
	s->len = 0;
	s->cap = 0;
}

static void msCellSeqGrow(msCellSeq* s) {
	int32_t newCap = s->cap <= 0 ? 16 : s->cap * 2;
	s->data = (msCell*)msRealloc(s->data, (size_t)s->cap * sizeof(msCell), (size_t)newCap * sizeof(msCell));
	s->cap = newCap;
}

void msCellSeqPush(msCellSeq* s, msCell cell) {
	if (s->len >= s->cap) msCellSeqGrow(s);
	s->data[s->len] = cell;
	s->len++;
}

void msCellSeqClear(msCellSeq* s) {
	s->len = 0;
}

void msCellSeqFree(msCellSeq* s) {
	free(s->data);
	s->data = NULL;
	s->len = 0;
	s->cap = 0;
}

/* O(1) removal by swapping with last element */
static void msCellSeqRemoveAt(msCellSeq* s, int32_t idx) {
	if (idx < 0 || idx >= s->len) return;
	s->len--;
	if (idx < s->len) {
		/* Swap with last — update the swapped element's rootIdx */
		s->data[idx] = s->data[s->len];
		msRefHeader* swappedH = msHeader(s->data[idx].ptr);
		swappedH->rootIdx = idx;
	}
}

/* ===== Root Registry ===== */

_Thread_local msCellSeq msRoots;
MS_TLS_PUBLISH(msRoots)
_Thread_local int32_t msRootsThreshold = 128;
MS_TLS_PUBLISH(msRootsThreshold)
_Thread_local int32_t msOrcTeardownDepth = 0;
MS_TLS_PUBLISH(msOrcTeardownDepth)

/* ===== ORC Diagnostics ===== */
#ifdef MSGC_ORC_STATS
_Thread_local int32_t msFreedCyclicObjects = 0;
MS_TLS_PUBLISH(msFreedCyclicObjects)
#endif

void msRegisterCycle(void* p, const msTypeInfo* type) {
	if (p == NULL) return;
	msRefHeader* h = msHeader(p);
	/* Already registered? */
	if (h->rootIdx >= 0) return;
	h->rootIdx = msRoots.len;
	MS_DRC_STAT_CYCLE(type);
	msCell cell = { p, type };
	msCellSeqPush(&msRoots, cell);

	/* Auto-trigger collection when threshold exceeded (Standard reference implementation parity).
	 * Skip while a =destroy is unwinding — a re-entrant collect there traces half-torn-down,
	 * not-yet-nulled slots (UAF). msOrcEndTeardown runs the deferred collect once it is safe. */
	if (msOrcTeardownDepth == 0 && msRoots.len - 128 >= msRootsThreshold) {
		msOrcCollect();
	}
}

void msUnregisterCycle(void* p) {
	if (p == NULL) return;
	msRefHeader* h = msHeader(p);
	if (h->rootIdx < 0) return;
	msCellSeqRemoveAt(&msRoots, h->rootIdx);
	h->rootIdx = -1;
}

/* ===== Color Helpers ===== */

static inline int32_t getColor(msRefHeader* h) {
	return h->rc & MS_COLOR_MASK;
}

static inline void setColor(msRefHeader* h, int32_t color) {
	h->rc = (h->rc & ~MS_COLOR_MASK) | color;
}

static inline intptr_t getCount(msRefHeader* h) {
	return h->rc >> MS_RC_SHIFT;
}

static inline void decCount(msRefHeader* h) {
	h->rc -= MS_RC_INCREMENT;
}

static inline void incCount(msRefHeader* h) {
	h->rc += MS_RC_INCREMENT;
}

static inline void setLastRefCount(msRefHeader* h) {
	h->rc &= MS_RC_MASK;
}

/* ===== Trace Ref (reference ORC parity) ===== */
/* Called by generated trace hooks. Receives ADDRESS of pointer slot, not the value.
 * This enables collectColor to null out slots (entry[] = nil) so destructors
 * don't follow dangling pointers to moribund objects. */

void msOrcTraceRef(void* slotAddr, void* env) {
	if (slotAddr == NULL || env == NULL) return;
	void* child = *(void**)slotAddr;
	if (child == NULL) return;
	msGcEnv* j = (msGcEnv*)env;
	msCell cell = { slotAddr, msHeader(child)->type };
	msCellSeqPush(&j->traceStack, cell);
}

/* ===== Helper: call type's trace hook ===== */

static inline void msTrace(void* p, const msTypeInfo* type, msGcEnv* j) {
	if (type != NULL && type->traceFn != NULL) {
		type->traceFn(p, j);
	}
}

/* ===== Phase 1: Mark Gray ===== */
/* Tentatively decrement all children of gray suspects. Iterative via traceStack.
 * Tracks rcSum (total refcounts) and edges (internal edges) for the
 * rcSum==edges shortcut that skips scan when all roots are pure garbage. */

static void markGray(msGcEnv* j, void* p, const msTypeInfo* type) {
	if (p == NULL) return;
	msRefHeader* h = msHeader(p);
	if (getColor(h) == MS_COL_GRAY) return;
	setColor(h, MS_COL_GRAY);
	j->touched++;
	/* +1 because rc is 0-based (0 = sole owner = 1 reference) */
	j->rcSum += getCount(h) + 1;
	msTrace(p, type, j);
	while (j->traceStack.len > 0) {
		msCell entry = j->traceStack.data[--j->traceStack.len];
		void* child = *(void**)entry.ptr;  /* dereference slot address */
		if (child == NULL) continue;
		msRefHeader* ch = msHeader(child);
		decCount(ch);
		j->edges++;
		if (getColor(ch) != MS_COL_GRAY) {
			setColor(ch, MS_COL_GRAY);
			j->touched++;
			/* +2: +1 for 0-based, +1 because we already decremented */
			j->rcSum += getCount(ch) + 2;
			msTrace(child, entry.type, j);
		}
	}
}

/* ===== Phase 2: Scan (Standard reference parity) ===== */

static void scanBlack(msGcEnv* j, void* p, const msTypeInfo* type) {
	setColor(msHeader(p), MS_COL_BLACK);
	int32_t until = j->traceStack.len;
	msTrace(p, type, j);
	while (j->traceStack.len > until) {
		msCell entry = j->traceStack.data[--j->traceStack.len];
		void* child = *(void**)entry.ptr;  /* dereference slot address */
		if (child == NULL) continue;
		msRefHeader* ch = msHeader(child);
		incCount(ch);
		if (getColor(ch) != MS_COL_BLACK) {
			setColor(ch, MS_COL_BLACK);
			msTrace(child, entry.type, j);
		}
	}
}

/* Phase 2: Scan — fully iterative, no recursion.
 * >= 0 means "has external references" (alive), < 0 means "only internal refs" (garbage). */
static void scan(msGcEnv* j, void* p, const msTypeInfo* type) {
	if (p == NULL) return;
	msRefHeader* h = msHeader(p);
	if (getColor(h) != MS_COL_GRAY) return;

	if (getCount(h) >= 0) {
		scanBlack(j, p, type);
	} else {
		setColor(h, MS_COL_WHITE);
		msTrace(p, type, j);
		while (j->traceStack.len > 0) {
			msCell entry = j->traceStack.data[--j->traceStack.len];
			void* child = *(void**)entry.ptr;  /* dereference slot address */
			if (child == NULL) continue;
			msRefHeader* ch = msHeader(child);
			if (getColor(ch) == MS_COL_GRAY) {
				if (getCount(ch) >= 0) {
					scanBlack(j, child, entry.type);
				} else {
					setColor(ch, MS_COL_WHITE);
					msTrace(child, entry.type, j);
				}
			}
		}
	}
}

/* ===== Phase 3: Collect by Color (collectColor) ===== */
/* Collect objects of the given color whose rootIdx has been cleared (-1).
 * Caller must clear rootIdx on all roots BEFORE calling this. */

static void collectColor(msGcEnv* j, void* p, const msTypeInfo* type, int32_t col) {
	if (p == NULL) return;
	msRefHeader* h = msHeader(p);
	if (getColor(h) != col || h->rootIdx >= 0) return;

	setColor(h, MS_COL_BLACK);
	msCell cell = { p, type };
	msCellSeqPush(&j->toFree, cell);
	msTrace(p, type, j);
	while (j->traceStack.len > 0) {
		msCell entry = j->traceStack.data[--j->traceStack.len];
		void* child = *(void**)entry.ptr;  /* dereference slot address */
		*(void**)entry.ptr = NULL;          /* null out slot so destructors see nil */
		if (child == NULL) continue;
		msRefHeader* ch = msHeader(child);
		if (getColor(ch) == col && ch->rootIdx < 0) {
			setColor(ch, MS_COL_BLACK);
			msCell childCell = { child, entry.type };
			msCellSeqPush(&j->toFree, childCell);
			msTrace(child, entry.type, j);
		}
	}
}

/* ===== Core Collection (collectCyclesBacon parity) ===== */

static void collectCyclesBacon(msGcEnv* j, int32_t lowMark) {
	int32_t last = msRoots.len - 1;

	/* Phase 1: Mark all roots gray, tentatively decrement children */
	for (int32_t i = last; i >= lowMark; i--) {
		markGray(j, msRoots.data[i].ptr, msRoots.data[i].type);
	}

	/* Shortcut: if rcSum == edges, every reference is internal —
	 * all roots form pure cycles with no external refs. Skip scan, collect all gray. */
	int32_t colToCollect = MS_COL_WHITE;
	if (j->rcSum == j->edges) {
		colToCollect = MS_COL_GRAY;
		j->keepThreshold = true;
	} else {
		/* Phase 2: Scan — restore live objects to black, mark garbage white */
		for (int32_t i = last; i >= lowMark; i--) {
			scan(j, msRoots.data[i].ptr, msRoots.data[i].type);
		}
	}

	/* Clear rootIdx on all roots BEFORE Phase 3.
	 * collectColor checks rootIdx < 0 to confirm the object is eligible. */
	for (int32_t i = 0; i < msRoots.len; i++) {
		msRefHeader* h = msHeader(msRoots.data[i].ptr);
		h->rootIdx = -1;
		collectColor(j, msRoots.data[i].ptr, msRoots.data[i].type, colToCollect);
	}

	MS_DRC_STAT(MS_DS_COLLECT, 1); MS_DRC_STAT(MS_DS_COLLECT_TRACED, j->touched);

	/* Protect against re-entrancy: destructors may trigger registerCycle */
	int32_t oldThreshold = msRootsThreshold;
	msRootsThreshold = INT32_MAX;
	msRoots.len = 0;

	/* Destroy and free collected objects */
	for (int32_t i = 0; i < j->toFree.len; i++) {
		void* p = j->toFree.data[i].ptr;
		const msTypeInfo* type = j->toFree.data[i].type;
		setLastRefCount(msHeader(p));
		MS_DESTROY_DISPATCH(type, p);
		msDestroyAndDispose(p);
	}

	msRootsThreshold = oldThreshold;
	j->freed += j->toFree.len;
	MS_DRC_STAT(MS_DS_COLLECT_FREED, j->toFree.len);
	msCellSeqFree(&j->toFree);
}

/* ===== Public API (GC_runOrc / GC_partialCollect parity) ===== */

void msOrcCollect(void) {
	if (msRoots.len == 0) return;

	msGcEnv j;
	msCellSeqInit(&j.traceStack);
	msCellSeqInit(&j.toFree);
	j.freed = 0;
	j.touched = 0;
	j.edges = 0;
	j.rcSum = 0;
	j.keepThreshold = false;

	collectCyclesBacon(&j, 0);

	msCellSeqFree(&j.traceStack);
	if (msRoots.len == 0) {
		msCellSeqFree(&msRoots);
	}

#ifdef MSGC_ORC_STATS
	msFreedCyclicObjects += j.freed;
#endif

	/* Adaptive threshold:
	 * keepThreshold: rcSum==edges shortcut fired — don't change
	 * effective (freed >= 50% of touched) → shrink threshold
	 * ineffective → grow threshold */
	if (!j.keepThreshold) {
		if (j.freed * 2 >= j.touched) {
			msRootsThreshold = msRootsThreshold * 2 / 3;
			if (msRootsThreshold < 16) msRootsThreshold = 16;
		} else if (msRootsThreshold < 16384) {
			if (msRootsThreshold <= 0) msRootsThreshold = 128;
			msRootsThreshold = msRootsThreshold / 2 + msRootsThreshold;  /* * 3/2 growth */
		}
	}
}

void msOrcPartialCollect(int32_t lowMark) {
	if (msRoots.len <= lowMark) return;

	msGcEnv j;
	msCellSeqInit(&j.traceStack);
	msCellSeqInit(&j.toFree);
	j.freed = 0;
	j.touched = 0;
	j.edges = 0;
	j.rcSum = 0;
	j.keepThreshold = false;

	collectCyclesBacon(&j, lowMark);
	msRoots.len = lowMark;

	msCellSeqFree(&j.traceStack);

#ifdef MSGC_ORC_STATS
	msFreedCyclicObjects += j.freed;
#endif
}

#endif /* MSGC_ORC */
