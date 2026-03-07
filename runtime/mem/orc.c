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

#ifdef MS_ORC

#include "orc.h"
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

msCellSeq msRoots;
int32_t msRootsThreshold = 128;

/* ===== ORC Diagnostics ===== */
#ifdef MS_ORC_STATS
int32_t msFreedCyclicObjects = 0;
#endif

void msRegisterCycle(void* p, const msTypeInfo* type) {
	if (p == NULL) return;
	msRefHeader* h = msHeader(p);
	/* Already registered? */
	if (h->rootIdx >= 0) return;
	h->rootIdx = msRoots.len;
	msCell cell = { p, type };
	msCellSeqPush(&msRoots, cell);

	/* Auto-trigger collection when threshold exceeded (Standard reference implementation parity) */
	if (msRoots.len - 128 >= msRootsThreshold) {
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

/* ===== Trace Ref (Nim parity: nimTraceRefDyn) ===== */
/* Called by generated trace hooks. Pushes child to traceStack. No recursion. */

void msOrcTraceRef(void* child, void* env) {
	if (child == NULL || env == NULL) return;
	msGcEnv* j = (msGcEnv*)env;
	msCell cell = { child, msHeader(child)->type };
	msCellSeqPush(&j->traceStack, cell);
}

/* ===== Helper: call type's trace hook ===== */

static inline void msTrace(void* p, const msTypeInfo* type, msGcEnv* j) {
	if (type != NULL && type->traceFn != NULL) {
		type->traceFn(p, j);
	}
}

/* ===== Phase 1: Mark Gray (Nim parity: orc.nim:183-216) ===== */
/* Tentatively decrement all children of gray suspects. Iterative via traceStack. */

static void markGray(msGcEnv* j, void* p, const msTypeInfo* type) {
	if (p == NULL) return;
	msRefHeader* h = msHeader(p);
	if (getColor(h) == MS_COL_GRAY) return;
	setColor(h, MS_COL_GRAY);
	msTrace(p, type, j);
	while (j->traceStack.len > 0) {
		msCell entry = j->traceStack.data[--j->traceStack.len];
		msRefHeader* ch = msHeader(entry.ptr);
		decCount(ch);
		if (getColor(ch) != MS_COL_GRAY) {
			setColor(ch, MS_COL_GRAY);
			msTrace(entry.ptr, entry.type, j);
		}
	}
}

/* ===== Phase 2: Scan (Nim parity: orc.nim:161-181, 218-278) ===== */

static void scanBlack(msGcEnv* j, void* p, const msTypeInfo* type) {
	setColor(msHeader(p), MS_COL_BLACK);
	int32_t until = j->traceStack.len;
	msTrace(p, type, j);
	while (j->traceStack.len > until) {
		msCell entry = j->traceStack.data[--j->traceStack.len];
		msRefHeader* ch = msHeader(entry.ptr);
		incCount(ch);
		if (getColor(ch) != MS_COL_BLACK) {
			setColor(ch, MS_COL_BLACK);
			msTrace(entry.ptr, entry.type, j);
		}
	}
}

static void scan(msGcEnv* j, void* p, const msTypeInfo* type) {
	if (p == NULL) return;
	msRefHeader* h = msHeader(p);
	if (getColor(h) != MS_COL_GRAY) return;

	if (getCount(h) > 0) {
		scanBlack(j, p, type);
	} else {
		setColor(h, MS_COL_WHITE);
		msTrace(p, type, j);
		while (j->traceStack.len > 0) {
			msCell entry = j->traceStack.data[--j->traceStack.len];
			scan(j, entry.ptr, entry.type);
		}
	}
}

/* ===== Phase 3: Collect White (Nim parity: orc.nim:285-309) ===== */

static void collectWhite(msGcEnv* j, void* p, const msTypeInfo* type) {
	if (p == NULL) return;
	msRefHeader* h = msHeader(p);
	if (getColor(h) != MS_COL_WHITE || h->rootIdx != 0) return;

	setColor(h, MS_COL_BLACK);
	msCell cell = { p, type };
	msCellSeqPush(&j->toFree, cell);
	msTrace(p, type, j);
	while (j->traceStack.len > 0) {
		msCell entry = j->traceStack.data[--j->traceStack.len];
		msRefHeader* ch = msHeader(entry.ptr);
		if (getColor(ch) == MS_COL_WHITE && ch->rootIdx == 0) {
			setColor(ch, MS_COL_BLACK);
			msCell child = { entry.ptr, entry.type };
			msCellSeqPush(&j->toFree, child);
			msTrace(entry.ptr, entry.type, j);
		}
	}
}

/* ===== Main Collection Entry Point ===== */

void msOrcCollect(void) {
	if (msRoots.len == 0) return;

	msGcEnv j;
	msCellSeqInit(&j.traceStack);
	msCellSeqInit(&j.toFree);

	/* Phase 1: Mark all roots gray, tentatively decrement children */
	for (int32_t i = 0; i < msRoots.len; i++) {
		markGray(&j, msRoots.data[i].ptr, msRoots.data[i].type);
	}

	/* Phase 2: Scan — restore live objects to black, mark garbage white */
	for (int32_t i = 0; i < msRoots.len; i++) {
		scan(&j, msRoots.data[i].ptr, msRoots.data[i].type);
	}

	/* Phase 3: Collect white objects */
	for (int32_t i = 0; i < msRoots.len; i++) {
		collectWhite(&j, msRoots.data[i].ptr, msRoots.data[i].type);
	}

	/* Clear rootIdx on all root objects before freeing */
	int32_t rootCount = msRoots.len;
	for (int32_t i = 0; i < msRoots.len; i++) {
		msRefHeader* h = msHeader(msRoots.data[i].ptr);
		h->rootIdx = -1;
	}

	/* Protect against re-entrancy: destructors may trigger registerCycle */
	int32_t oldThreshold = msRootsThreshold;
	msRootsThreshold = INT32_MAX;
	msRoots.len = 0;

	/* Destroy and free collected objects */
	int32_t freed = j.toFree.len;
	for (int32_t i = 0; i < j.toFree.len; i++) {
		void* p = j.toFree.data[i].ptr;
		const msTypeInfo* type = j.toFree.data[i].type;
		msRefHeader* h = msHeader(p);
		h->rootIdx = -1;
		if (type != NULL && type->destroyFn != NULL) {
			type->destroyFn(p);
		}
		msDestroyAndDispose(p);
	}

	/* Restore threshold */
	msRootsThreshold = oldThreshold;
	msCellSeqFree(&j.traceStack);
	msCellSeqFree(&j.toFree);

#ifdef MS_ORC_STATS
	msFreedCyclicObjects += freed;
#endif

	/* Adaptive threshold */
	if (rootCount > 0) {
		if (freed * 2 < rootCount) {
			if (msRootsThreshold < 16384) {
				msRootsThreshold = msRootsThreshold * 3 / 2;
			}
		} else {
			if (msRootsThreshold > 128) {
				msRootsThreshold = msRootsThreshold * 2 / 3;
				if (msRootsThreshold < 128) msRootsThreshold = 128;
			}
		}
	}
}

#endif /* MS_ORC */
