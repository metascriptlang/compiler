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
	_Atomic(int32_t) rc;     /* Reference count (0 = unique, >0 = shared). Atomic for thread safety. */
	int32_t rootIdx;         /* ORC rootset index (-1 = not registered) */
	const msTypeInfo* type;  /* RTTI (NULL for untyped allocs) */
	uint32_t allocSize;      /* Total allocation size (header + payload) — for slab recycling */
} msRefHeader;

/* Get header from user pointer: header lives right before the object */
static inline msRefHeader* msHeader(void* p) {
	return (msRefHeader*)((char*)p - sizeof(msRefHeader));
}

/* ===== Small-Object Free-List Cache ===== */

/* Thread-local free-list for DRC objects ≤ MS_SLAB_MAX bytes (header + payload).
 * Avoids calloc/free overhead for short-lived objects (e.g., spawn closure envs).
 * Objects are bucketed by rounded-up size. Each bucket is a singly-linked list
 * using the first 8 bytes of the freed block as the next pointer. */
#define MS_SLAB_MAX 128        /* max total size (header + payload) for caching */
#define MS_SLAB_BUCKET_SIZE 32 /* bucket granularity: 32, 64, 96, 128 */
#define MS_SLAB_BUCKETS 4
#define MS_SLAB_LIMIT 256      /* max cached entries per bucket (prevents unbounded growth) */

typedef struct msSlab {
	void* free[MS_SLAB_BUCKETS];       /* free-list heads per bucket */
	int32_t count[MS_SLAB_BUCKETS];    /* entries per bucket */
} msSlab;

static _Thread_local msSlab msSlabTLS;

static inline int msSlabBucket(size_t totalSize) {
	if (totalSize <= 32) return 0;
	if (totalSize <= 64) return 1;
	if (totalSize <= 96) return 2;
	if (totalSize <= 128) return 3;
	return -1;
}

static inline void* msSlabAlloc(size_t totalSize) {
	int b = msSlabBucket(totalSize);
	if (b >= 0 && msSlabTLS.free[b] != NULL) {
		void* p = msSlabTLS.free[b];
		msSlabTLS.free[b] = *(void**)p;
		msSlabTLS.count[b]--;
		/* Zero only the header area — payload zeroed separately by codegen (memset).
		 * Saves zeroing unused bytes in the bucket. */
		memset(p, 0, sizeof(msRefHeader));
		return p;
	}
	return calloc(1, totalSize);
}

static inline void msSlabFree(void* p, size_t totalSize) {
	int b = msSlabBucket(totalSize);
	if (b >= 0 && msSlabTLS.count[b] < MS_SLAB_LIMIT) {
		*(void**)p = msSlabTLS.free[b];
		msSlabTLS.free[b] = p;
		msSlabTLS.count[b]++;
		return;
	}
	free(p);
}

/* ===== Allocation ===== */

/* Allocate object with ref header. Returns pointer to user data (past header). */
static inline void* msAlloc(size_t size) {
	size_t total = sizeof(msRefHeader) + size;
	msRefHeader* h = (msRefHeader*)msSlabAlloc(total);
	h->rc = 0;
	h->rootIdx = -1;
	h->type = NULL;
	h->allocSize = (uint32_t)total;
	return (void*)(h + 1);
}

/* Allocate with RTTI — for typed class instances (ORC-aware). */
static inline void* msAllocTyped(size_t size, const msTypeInfo* type) {
	size_t total = sizeof(msRefHeader) + size;
	msRefHeader* h = (msRefHeader*)msSlabAlloc(total);
	h->rc = 0;
	h->rootIdx = -1;
	h->type = type;
	h->allocSize = (uint32_t)total;
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
		atomic_fetch_add_explicit(&msHeader(p)->rc, 1, memory_order_relaxed);
	}
}

static inline bool msDecRefIsLast(void* p) {
	if (p == NULL) return false;
	msRefHeader* h = msHeader(p);
	/* Reference parity: check count BEFORE decrementing.
	 * rc starts at 0 from msAlloc. rc=0 means "sole owner".
	 * If rc == 0: last reference — return true for destruction (do NOT decrement).
	 * If rc > 0: other references exist — decrement and return false. */
	if (h->rc == 0) {
		return true;
	}
	h->rc--;
	return false;
}

static inline void msDestroyAndDispose(void* p) {
	if (p != NULL) {
		msRefHeader* h = msHeader(p);
		msSlabFree(h, h->allocSize);
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
