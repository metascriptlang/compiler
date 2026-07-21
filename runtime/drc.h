/*
 * MetaScript DRC Runtime — ARC + ORC Cycle Collector
 *
 * ARC: refcount primitives (incref/decref). Active under --gc=drc and --gc=orc.
 * ORC: cycle collector (Bacon's trial deletion). Active under --gc=orc (MSGC_ORC defined).
 *
 * RefHeader prepended to all heap-allocated RC objects.
 * Layout: [rc:4][rootIdx:4][type:8] = 16 bytes on 64-bit
 *
 * ORC supplements ARC for cyclic data structures. Non-cyclic objects
 * use plain ARC (zero overhead). Cyclic objects get registered in the
 * root set; periodically the collector runs a 3-phase mark-scan-collect.
 *
 * When MSGC_ORC is not defined (--gc=drc), ORC functions are no-ops.
 */

#ifndef MSGC_DRC_H
#define MSGC_DRC_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdatomic.h>

#include "runtime/types.h"

/* ===== RC Encoding ===== */
/* Under --gc=orc (MSGC_ORC), rc field = [count:28][flags:4].
 * Lower 4 bits reserved for ORC cycle collector (color + maybeCycle).
 * ALL rc operations use MS_RC_INCREMENT to preserve the lower bits.
 * Under --gc=drc (plain ARC), rc is a simple counter. */
#ifdef MSGC_ORC
#define MS_RC_INCREMENT 16
#define MS_RC_MASK      15   /* lower 4 bits: color + flags */
#else
#define MS_RC_INCREMENT 1
#define MS_RC_MASK      0
#endif

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

/* ===== DRC Ledger (test-only lifecycle guard) ===== */
/* Built with -DMS_DRC_LEDGER (off by default → zero cost in normal builds).
 * Records alloc/destroy events to catch double-destroy (abort on the 2nd
 * finalize of a live pointer) and leaks (per-type alloc/destroy imbalance
 * dumped at exit). Present in BOTH --gc=drc and --gc=orc. Every last-ref
 * destroyFn dispatch routes through MS_DESTROY_DISPATCH so the ledger sees
 * exactly one finalize per object; a second is the drift signal.
 * See src/test/guard/ and the /nim-guard skill. */
#ifdef MS_DRC_LEDGER
void msLedgerAlloc(void* p, const msTypeInfo* type);
void msLedgerDestroy(void* p, const msTypeInfo* type);
#define MS_LEDGER_ALLOC(p, t)      msLedgerAlloc((p), (t))
#define MS_DESTROY_DISPATCH(t, p)  do { \
	msLedgerDestroy((p), (t)); \
	if ((t) != NULL && (t)->destroyFn != NULL) (t)->destroyFn(p); \
} while (0)
#else
#define MS_LEDGER_ALLOC(p, t)      ((void)0)
#define MS_DESTROY_DISPATCH(t, p)  do { \
	if ((t) != NULL && (t)->destroyFn != NULL) (t)->destroyFn(p); \
} while (0)
#endif

/* ===== Small-Object Free-List Cache ===== */

/* Thread-local free-list for DRC objects ≤ MS_SLAB_MAX bytes (header + payload).
 * Avoids calloc/free overhead for short-lived objects (e.g., spawn closure envs).
 * Objects are bucketed by rounded-up size. Each bucket is a singly-linked list
 * using the first 8 bytes of the freed block as the next pointer. */
/* Overridable so sanitizer builds can bypass the free-list entirely
 * (-DMS_SLAB_MAX=0): recycling inside the slab hides use-after-free from
 * ASAN/guard-malloc, which only see real malloc/free boundaries. */
#ifndef MS_SLAB_MAX
#define MS_SLAB_MAX 128        /* max total size (header + payload) for caching */
#endif
#define MS_SLAB_BUCKET_SIZE 32 /* bucket granularity: 32, 64, 96, 128 */
#define MS_SLAB_BUCKETS 4
#define MS_SLAB_LIMIT 256      /* max cached entries per bucket (prevents unbounded growth) */

typedef struct msSlab {
	void* free[MS_SLAB_BUCKETS];       /* free-list heads per bucket */
	int32_t count[MS_SLAB_BUCKETS];    /* entries per bucket */
} msSlab;

static _Thread_local msSlab msSlabTLS;

static inline int msSlabBucket(size_t totalSize) {
	if (totalSize > MS_SLAB_MAX) return -1;
	if (totalSize <= 32) return 0;
	if (totalSize <= 64) return 1;
	if (totalSize <= 96) return 2;
	if (totalSize <= 128) return 3;
	return -1;
}

/* Round up to bucket max so any request in the bucket range fits a reused entry. */
static const size_t msSlabBucketSize[] = {32, 64, 96, 128};

/* Slab primitive WITHOUT any zeroing — caller owns the memory state.
 * Returns dirty memory on cache hit; malloc'd (dirty) memory on cache miss.
 * Used by the Uninit alloc variants whose callers guarantee full field coverage. */
static inline void* msSlabAllocRaw(size_t totalSize) {
	int b = msSlabBucket(totalSize);
	if (b >= 0 && msSlabTLS.free[b] != NULL) {
		void* p = msSlabTLS.free[b];
		msSlabTLS.free[b] = *(void**)p;
		msSlabTLS.count[b]--;
		return p;
	}
	/* Allocate bucket max, not exact size — slab reuses by bucket, not by exact size */
	return malloc(b >= 0 ? msSlabBucketSize[b] : totalSize);
}

/* Safe slab primitive: zero-initialises the caller's requested range on both
 * cache hit and fresh alloc. This is the Nim nimNewObj contract — callers see
 * zero-initialised memory (header + payload) regardless of whether the block
 * was recycled. Only `totalSize` bytes are zeroed (not the whole bucket): the
 * extra slack inside a bucket is never read by the caller. Fresh allocations
 * use calloc so the OS can return zero-pages without an explicit memset. */
static inline void* msSlabAlloc(size_t totalSize) {
	int b = msSlabBucket(totalSize);
	if (b >= 0 && msSlabTLS.free[b] != NULL) {
		void* p = msSlabTLS.free[b];
		msSlabTLS.free[b] = *(void**)p;
		msSlabTLS.count[b]--;
		memset(p, 0, totalSize);
		return p;
	}
	return calloc(1, b >= 0 ? msSlabBucketSize[b] : totalSize);
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

/* Allocate object with ref header. Returns pointer to user data (past header).
 * Safe default: header + payload are zero-initialised. Matches Nim nimNewObj. */
static inline void* msAlloc(size_t size) {
	size_t total = sizeof(msRefHeader) + size;
	msRefHeader* h = (msRefHeader*)msSlabAlloc(total);   /* full zero */
	/* rc, type already zero from msSlabAlloc; only rootIdx + allocSize need set */
	h->rootIdx = -1;
	h->allocSize = (uint32_t)total;
	MS_LEDGER_ALLOC((void*)(h + 1), NULL);
	return (void*)(h + 1);
}

/* Allocate with RTTI — for typed class instances (ORC-aware).
 * Safe default: header + payload are zero-initialised. Matches Nim nimNewObj. */
static inline void* msAllocTyped(size_t size, const msTypeInfo* type) {
	size_t total = sizeof(msRefHeader) + size;
	msRefHeader* h = (msRefHeader*)msSlabAlloc(total);   /* full zero */
	h->rootIdx = -1;
	h->type = type;
	h->allocSize = (uint32_t)total;
	MS_LEDGER_ALLOC((void*)(h + 1), type);
	return (void*)(h + 1);
}

/* Arc<T> box: msAllocTyped, but starts at rc = MS_RC_INCREMENT (sole owner).
 * msAtomicDecRefIsLast frees when fetch_sub sees the old rc == MS_RC_INCREMENT
 * (Rust Arc convention) — an Arc must NOT start at the rc=0 "sole owner" of the
 * non-atomic path, or its first decref would underflow and never free. */
static inline void* msAllocArc(size_t size, const msTypeInfo* type) {
	void* p = msAllocTyped(size, type);
	msHeader(p)->rc = MS_RC_INCREMENT;
	return p;
}

/* Uninit opt-in: payload stays dirty from the slab free-list (or malloc).
 * ONLY use when the caller guarantees every payload byte is written before
 * the next read. Mirrors Nim nimNewObjUninit. Codegen emits this only for
 * call sites it can prove fully initialise the payload (e.g. new T(args)
 * with args.length === fieldNames.length). */
static inline void* msAllocUninit(size_t size) {
	size_t total = sizeof(msRefHeader) + size;
	msRefHeader* h = (msRefHeader*)msSlabAllocRaw(total);  /* dirty */
	h->rc = 0;
	h->rootIdx = -1;
	h->type = NULL;
	h->allocSize = (uint32_t)total;
	MS_LEDGER_ALLOC((void*)(h + 1), NULL);
	return (void*)(h + 1);
}

static inline void* msAllocTypedUninit(size_t size, const msTypeInfo* type) {
	size_t total = sizeof(msRefHeader) + size;
	msRefHeader* h = (msRefHeader*)msSlabAllocRaw(total);  /* dirty */
	h->rc = 0;
	h->rootIdx = -1;
	h->type = type;
	h->allocSize = (uint32_t)total;
	MS_LEDGER_ALLOC((void*)(h + 1), type);
	return (void*)(h + 1);
}

/* ===== ARC Operations ===== */
/* All rc arithmetic uses MS_RC_INCREMENT to preserve ORC's lower bits.
 * Under --gc=drc, MS_RC_INCREMENT=1 and MS_RC_MASK=0 — same as plain rc++/rc--. */

static inline void msIncRef(void* p) {
	if (p != NULL) {
		msHeader(p)->rc += MS_RC_INCREMENT;
	}
}

/* Atomic incref for cross-thread sharing (SHARE rule: const Ref crossing actor boundary).
 * Uses relaxed ordering — sufficient for refcount increment (no data dependency). */
static inline void msAtomicIncRef(void* p) {
	if (p != NULL) {
		atomic_fetch_add_explicit(&msHeader(p)->rc, MS_RC_INCREMENT, memory_order_relaxed);
	}
}

static inline bool msDecRefIsLast(void* p) {
	if (p == NULL) return false;
	msRefHeader* h = msHeader(p);
	/* Check count portion (upper bits) is zero — ignores ORC color/flag bits.
	 * rc starts at 0 from msAlloc. (rc & ~MS_RC_MASK)==0 means sole owner.
	 * Under --gc=drc, MS_RC_MASK=0 so this reduces to h->rc==0. */
	if ((h->rc & ~MS_RC_MASK) == 0) {
		return true;
	}
	h->rc -= MS_RC_INCREMENT;
	return false;
}

/* Atomic decref-to-free for Arc<T> (cross-thread shared). The Release on the
 * fetch_sub plus the Acquire fence before the caller destroys is the load-bearing
 * ordering (Rust Arc protocol) — it must not be weakened. fetch_sub by
 * MS_RC_INCREMENT preserves the ORC flag bits; Arc is acyclic so this never routes
 * through the cycle collector even under --gc=orc. */
static inline bool msAtomicDecRefIsLast(void* p) {
	if (p == NULL) return false;
	int32_t old = atomic_fetch_sub_explicit(&msHeader(p)->rc, MS_RC_INCREMENT, memory_order_release);
	if ((old & ~MS_RC_MASK) == MS_RC_INCREMENT) {
		atomic_thread_fence(memory_order_acquire);
		return true;
	}
	return false;
}

#ifdef MSGC_ORC
void msUnregisterCycle(void* p);
#endif

static inline void msDestroyAndDispose(void* p) {
	if (p != NULL) {
		msRefHeader* h = msHeader(p);
#ifdef MSGC_ORC
		/* Freeing a node that is still a registered cycle-root (rootIdx >= 0) must
		 * scrub it from msRoots — every free path, including codegen's sole-owner
		 * direct dispose that bypasses msOrcDecRefIsLast. Else msOrcCollect later
		 * walks a dangling root (UAF in markGray/getColor). */
		if (h->rootIdx >= 0) msUnregisterCycle(p);
#endif
		msSlabFree(h, h->allocSize);
	}
}

#define msWasMoved(p) ((p) = NULL)

/* ===== ORC Cycle Collector ===== */
/* Enabled by --gc=orc (defines MSGC_ORC). --gc=drc uses plain ARC below. */

#ifdef MSGC_ORC

#define MS_COL_BLACK   0
#define MS_COL_GRAY    1
#define MS_COL_WHITE   2
#define MS_MAYBE_CYCLE 4
#define MS_COLOR_MASK  3
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
		if (h->rootIdx < 0 && desc != NULL && desc->isCyclic) {
			h->rc = (h->rc & ~MS_COLOR_MASK) | MS_COL_BLACK;
			msRegisterCycle(p, desc);
		}
	}
}

static inline void msOrcIncRef(void* p) {
	if (p == NULL) return;
	msHeader(p)->rc += MS_RC_INCREMENT;
}

static inline bool msOrcDecRefIsLast(void* p) {
	if (p == NULL) return false;
	msRefHeader* h = msHeader(p);
	bool isLast = (h->rc & ~MS_COLOR_MASK) == 0;
	if (!isLast) {
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

/* GC_runOrc / GC_enableOrc / GC_disableOrc parity */
void msOrcCollect(void);
void msOrcPartialCollect(int32_t lowMark);

static inline void msOrcEnable(void) { msRootsThreshold = 0; }
static inline void msOrcDisable(void) { msRootsThreshold = INT32_MAX; }
static inline int32_t msOrcPrepare(void) { return msRoots.len; }

/* Teardown critical section (=destroy hooks). While a destructor is unwinding, an
 * object's fields are half-freed and its slots not yet nulled; a threshold-triggered
 * msOrcCollect() here would markGray-trace a dangling slot → UAF. Suppress collection
 * for the whole (possibly nested) teardown, then run one deferred collect on unwind.
 * Mirrors the reference collector's own free-loop guard, extended to ARC scope-exit
 * destroys (which the free-loop threshold hack does not cover). */
extern int32_t msOrcTeardownDepth;
static inline void msOrcBeginTeardown(void) { msOrcTeardownDepth += 1; }
static inline void msOrcEndTeardown(void) {
	msOrcTeardownDepth -= 1;
	if (msOrcTeardownDepth == 0 && msRoots.len - 128 >= msRootsThreshold) {
		msOrcCollect();
	}
}

typedef struct {
	msCellSeq traceStack;
	msCellSeq toFree;
	int32_t freed;
	int32_t touched;
	int32_t edges;
	int32_t rcSum;
	bool keepThreshold;
} msGcEnv;

void msOrcTraceRef(void* child, void* env);

#ifdef MSGC_ORC_STATS
extern int32_t msFreedCyclicObjects;
#endif

#else /* !MSGC_ORC — plain ARC (--gc=drc) */

static inline void msOrcCollect(void) {}
static inline void msOrcTraceRef(void* child, void* env) { (void)child; (void)env; }
static inline void msOrcBeginTeardown(void) {}
static inline void msOrcEndTeardown(void) {}

#endif /* MSGC_ORC */

#endif /* MSGC_DRC_H */
