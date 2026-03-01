/*
 * MetaScript ORC — Cycle Collector (Bacon's Trial Deletion)
 *
 * Supplements ARC for cyclic data structures. Non-cyclic objects
 * use plain ARC (zero overhead). Objects that *might* be cyclic
 * get registered in the root set; periodically the collector runs
 * a 3-phase mark-scan-collect to reclaim cycles.
 *
 * Color encoding: stored in lower 4 bits of msRefHeader.rc.
 *   Actual reference count = rc >> MS_RC_SHIFT.
 *
 * When MS_ORC is not defined, all ORC functions are no-ops
 * and the rc field is used directly (plain ARC mode).
 */

#ifndef MS_ORC_H
#define MS_ORC_H

#include "arc.h"
#include "typeinfo.h"

#ifdef MS_ORC

/* ===== Color Constants (lower 4 bits of rc) ===== */
#define MS_COL_BLACK   0   /* alive / default */
#define MS_COL_GRAY    1   /* suspect (tentatively decremented) */
#define MS_COL_WHITE   2   /* garbage (unreachable) */
#define MS_MAYBE_CYCLE 4   /* sticky: potentially cyclic */
#define MS_COLOR_MASK  3   /* mask for color bits (0-1) */
#define MS_RC_INCREMENT 16 /* count stored in bits 4+ */
#define MS_RC_SHIFT    4   /* shift to extract count */

/* ===== Cell — (ptr, type) pair for root registry ===== */
typedef struct {
	void* ptr;
	const msTypeInfo* type;
} msCell;

/* ===== CellSeq — growable array of cells ===== */
typedef struct {
	msCell* data;
	int32_t len;
	int32_t cap;
} msCellSeq;

/* CellSeq operations */
void msCellSeqInit(msCellSeq* s);
void msCellSeqPush(msCellSeq* s, msCell cell);
void msCellSeqClear(msCellSeq* s);
void msCellSeqFree(msCellSeq* s);

/* ===== Root Registry ===== */
extern msCellSeq msRoots;
extern int32_t msRootsThreshold;

/* Register/unregister a potentially cyclic object */
void msRegisterCycle(void* p, const msTypeInfo* type);
void msUnregisterCycle(void* p);

/* ===== ORC-aware RC Operations ===== */

/* rememberCycle — Nim parity (orc.nim:506)
 * isDestroy=true:  unregister from roots (about to be freed)
 * isDestroy=false: register as cycle candidate if cyclic + not registered */
static inline void msRememberCycle(bool isDestroy, void* p, const msTypeInfo* desc) {
	msRefHeader* h = msHeader(p);
	if (isDestroy) {
		if (h->rootIdx >= 0) {
			msUnregisterCycle(p);
		}
	} else {
		/* Register if: not yet registered AND type is cyclic (has trace) */
		if (h->rootIdx < 0 && desc != NULL && desc->trace != NULL) {
			h->rc = (h->rc & ~MS_COLOR_MASK) | MS_COL_BLACK;
			msRegisterCycle(p, desc);
		}
	}
}

/* Increment for cyclic types — sets maybeCycle bit (Nim's nimIncRefCyclic) */
static inline void msOrcIncRef(void* p) {
	if (p == NULL) return;
	msRefHeader* h = msHeader(p);
	h->rc += MS_RC_INCREMENT;
	h->rc |= MS_MAYBE_CYCLE;
}

/* Decrement for cyclic types — Nim's nimDecRefIsLastCyclicStatic.
 * Returns true if last reference (caller handles destroy+free).
 * Calls rememberCycle to register/unregister from rootset. */
static inline bool msOrcDecRefIsLast(void* p) {
	if (p == NULL) return false;
	msRefHeader* h = msHeader(p);
	bool isLast = false;
	int32_t count = h->rc >> MS_RC_SHIFT;
	if (count == 0) {
		isLast = true;
	} else {
		h->rc -= MS_RC_INCREMENT;
	}
	msRememberCycle(isLast, p, h->type);
	return isLast;
}

/* Mark an object as potentially cyclic */
static inline void msMarkMaybeCycle(void* p) {
	if (p != NULL) {
		msHeader(p)->rc |= MS_MAYBE_CYCLE;
	}
}

/* ===== Collection ===== */

/* Run full cycle collection (Bacon's 3-phase algorithm) */
void msOrcCollect(void);

/* Trace callback: called by type-specific trace functions.
 * Registers a child reference for cycle detection. */
void msOrcTraceRef(void* child, void* env);

/* ===== ORC Diagnostics (behind MS_ORC_STATS) ===== */
#ifdef MS_ORC_STATS
extern int32_t msFreedCyclicObjects;
#endif

#else /* !MS_ORC — plain ARC mode, no cycle collection */

static inline void msOrcCollect(void) {}

#endif /* MS_ORC */

#endif /* MS_ORC_H */
