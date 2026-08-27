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
#include <string.h>
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

#define MS_LEDGER_NAMES 4096
static const char* gLedgerName[MS_LEDGER_NAMES];
static long        gLedgerAllocN[MS_LEDGER_NAMES];
static long        gLedgerDestroyN[MS_LEDGER_NAMES];
static int         gLedgerNameCount = 0;

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
static int msLedgerNameIdx(const char* n) {
	if (n == NULL) n = "<untyped>";
	for (int i = 0; i < gLedgerNameCount; i++) {
		if (gLedgerName[i] == n || strcmp(gLedgerName[i], n) == 0) return i;
	}
	if (gLedgerNameCount < MS_LEDGER_NAMES) {
		int i = gLedgerNameCount++;
		gLedgerName[i] = n; gLedgerAllocN[i] = 0; gLedgerDestroyN[i] = 0;
		return i;
	}
	return -1;
}
/* TOTAL prints even at zero counts: the SAN corpus runner treats "no LEDGER
 * line at all" as instrumentation loss, and a program whose only allocations
 * were baked into static const cells makes no ledger entries. */
static void msLedgerDump(void) {
	pthread_mutex_lock(&gLedgerMutex);
	long totalA = 0, totalD = 0;
	for (int i = 0; i < gLedgerNameCount; i++) {
		fprintf(stderr, "LEDGER %s alloc=%ld destroy=%ld\n",
			gLedgerName[i], gLedgerAllocN[i], gLedgerDestroyN[i]);
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
	int idx = msLedgerNameIdx(type ? type->name : NULL);
	if (idx >= 0) gLedgerAllocN[idx]++;
	pthread_mutex_unlock(&gLedgerMutex);
}
void msLedgerDestroy(void* p, const msTypeInfo* type) {
	if (p == NULL) return;
	pthread_mutex_lock(&gLedgerMutex);
	if (msLedgerSetContains(p)) {
		const char* n = (type && type->name) ? type->name : "<untyped>";
		fprintf(stderr, "\nNIM-GUARD LEDGER: DOUBLE-DESTROY of %s at %p\n", n, p);
		fflush(stderr);
		abort();
	}
	msLedgerSetInsert(p);
	int idx = msLedgerNameIdx(type ? type->name : NULL);
	if (idx >= 0) gLedgerDestroyN[idx]++;
	pthread_mutex_unlock(&gLedgerMutex);
}
#endif  /* MS_DRC_LEDGER */

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
	s->data = (msCell*)realloc(s->data, (size_t)newCap * sizeof(msCell));
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
_Thread_local int32_t msRootsThreshold = 128;
_Thread_local int32_t msOrcTeardownDepth = 0;

/* ===== ORC Diagnostics ===== */
#ifdef MSGC_ORC_STATS
_Thread_local int32_t msFreedCyclicObjects = 0;
#endif

void msRegisterCycle(void* p, const msTypeInfo* type) {
	if (p == NULL) return;
	msRefHeader* h = msHeader(p);
	/* Already registered? */
	if (h->rootIdx >= 0) return;
	h->rootIdx = msRoots.len;
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

static inline int32_t getCount(msRefHeader* h) {
	return h->rc >> MS_RC_SHIFT;
}

static inline void decCount(msRefHeader* h) {
	h->rc -= MS_RC_INCREMENT;
}

static inline void incCount(msRefHeader* h) {
	h->rc += MS_RC_INCREMENT;
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

	/* Protect against re-entrancy: destructors may trigger registerCycle */
	int32_t oldThreshold = msRootsThreshold;
	msRootsThreshold = INT32_MAX;
	msRoots.len = 0;

	/* Destroy and free collected objects */
	for (int32_t i = 0; i < j->toFree.len; i++) {
		void* p = j->toFree.data[i].ptr;
		const msTypeInfo* type = j->toFree.data[i].type;
		MS_DESTROY_DISPATCH(type, p);
		msDestroyAndDispose(p);
	}

	msRootsThreshold = oldThreshold;
	j->freed += j->toFree.len;
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
