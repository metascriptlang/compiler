/*
 * MetaScript DRC Runtime — Deterministic Reference Counting + ORC Cycle Collector
 *
 * Merged from arc.h (refcount primitives) + orc.h (cycle collection).
 * RefHeader prepended to all heap-allocated RC objects.
 * Layout: [rc:4][rootIdx:4][type:8] = 16 bytes on 64-bit
 *
 * ORC supplements ARC for cyclic data structures. Non-cyclic objects
 * use plain ARC (zero overhead). Cyclic objects get registered in the
 * root set; periodically the collector runs a 3-phase mark-scan-collect.
 *
 * When MS_ORC is not defined, all ORC functions are no-ops.
 */

#ifndef MS_DRC_H
#define MS_DRC_H

/* Also define legacy guards for backward compatibility */
#define MS_ARC_H
#define MS_ORC_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdatomic.h>

#include "runtime/types.h"

/* ===== Reference Header ===== */

typedef struct {
	int32_t rc;              /* Reference count (0 = unique, >0 = shared) */
	int32_t rootIdx;         /* ORC rootset index (-1 = not registered) */
	const msTypeInfo* type;  /* RTTI (NULL for untyped allocs) */
} msRefHeader;

/* Get header from user pointer: header lives right before the object */
static inline msRefHeader* msHeader(void* p) {
	return (msRefHeader*)((char*)p - sizeof(msRefHeader));
}

/* ===== Allocation ===== */

/* Allocate object with ref header. Returns pointer to user data (past header). */
static inline void* msAlloc(size_t size) {
	msRefHeader* h = (msRefHeader*)calloc(1, sizeof(msRefHeader) + size);
	h->rc = 0;
	h->rootIdx = -1;
	h->type = NULL;
	return (void*)(h + 1);
}

/* Allocate with RTTI — for typed class instances (ORC-aware). */
static inline void* msAllocTyped(size_t size, const msTypeInfo* type) {
	msRefHeader* h = (msRefHeader*)calloc(1, sizeof(msRefHeader) + size);
	h->rc = 0;
	h->rootIdx = -1;
	h->type = type;
	return (void*)(h + 1);
}

/* ===== ARC Operations ===== */

static inline void msIncRef(void* p) {
	if (p != NULL) {
		msHeader(p)->rc++;
	}
}

/* Atomic incref for cross-thread sharing (SHARE rule: const Ref crossing actor boundary).
 * Uses relaxed ordering — sufficient for refcount increment (no data dependency). */
static inline void msAtomicIncRef(void* p) {
	if (p != NULL) {
		atomic_fetch_add_explicit((_Atomic(int32_t)*)&msHeader(p)->rc, 1, memory_order_relaxed);
	}
}

static inline bool msDecRefIsLast(void* p) {
	if (p == NULL) return false;
	msRefHeader* h = msHeader(p);
	if (h->rc == 0) return true;
	h->rc--;
	return false;
}

static inline void msDestroyAndDispose(void* p) {
	if (p != NULL) {
		free(msHeader(p));
	}
}

#define msWasMoved(p) ((p) = NULL)

/* ===== ORC Cycle Collector ===== */

#ifdef MS_ORC

#define MS_COL_BLACK   0
#define MS_COL_GRAY    1
#define MS_COL_WHITE   2
#define MS_MAYBE_CYCLE 4
#define MS_COLOR_MASK  3
#define MS_RC_INCREMENT 16
#define MS_RC_SHIFT    4

typedef struct {
	void* ptr;
	const msTypeInfo* type;
} msCell;

typedef struct {
	msCell* data;
	int32_t len;
	int32_t cap;
} msCellSeq;

void msCellSeqInit(msCellSeq* s);
void msCellSeqPush(msCellSeq* s, msCell cell);
void msCellSeqClear(msCellSeq* s);
void msCellSeqFree(msCellSeq* s);

extern msCellSeq msRoots;
extern int32_t msRootsThreshold;

void msRegisterCycle(void* p, const msTypeInfo* type);
void msUnregisterCycle(void* p);

/* rememberCycle — register/unregister cycle candidate */
static inline void msRememberCycle(bool isDestroy, void* p, const msTypeInfo* desc) {
	msRefHeader* h = msHeader(p);
	if (isDestroy) {
		if (h->rootIdx >= 0) {
			msUnregisterCycle(p);
		}
	} else {
		if (h->rootIdx < 0 && desc != NULL && desc->traceFn != NULL) {
			h->rc = (h->rc & ~MS_COLOR_MASK) | MS_COL_BLACK;
			msRegisterCycle(p, desc);
		}
	}
}

static inline void msOrcIncRef(void* p) {
	if (p == NULL) return;
	msRefHeader* h = msHeader(p);
	h->rc += MS_RC_INCREMENT;
	h->rc |= MS_MAYBE_CYCLE;
}

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

static inline void msMarkMaybeCycle(void* p) {
	if (p != NULL) {
		msHeader(p)->rc |= MS_MAYBE_CYCLE;
	}
}

void msOrcCollect(void);

typedef struct {
	msCellSeq traceStack;
	msCellSeq toFree;
} msGcEnv;

void msOrcTraceRef(void* child, void* env);

#ifdef MS_ORC_STATS
extern int32_t msFreedCyclicObjects;
#endif

#else /* !MS_ORC — plain ARC mode */

static inline void msOrcCollect(void) {}
static inline void msOrcTraceRef(void* child, void* env) { (void)child; (void)env; }

#endif /* MS_ORC */

#endif /* MS_DRC_H */
