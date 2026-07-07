/*
 * MetaScript Actor Mailbox — Lock-Free MPSC Queue
 *
 * Based on Pony's messageq (Clebsch et al.):
 * - Multiple producers push via atomic exchange (wait-free)
 * - Single consumer pops from tail (no atomics needed)
 * - Stub/sentinel node avoids empty-queue special cases
 * - LSB of head pointer tagged for empty detection
 *
 * ~5-20ns per push (single atomic exchange), zero syscalls.
 */

#ifndef MS_MAILBOX_H
#define MS_MAILBOX_H

#include <stdint.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>

/* ===== Message (Pony parity: size-class allocation, exact-fit per method) ===== */

typedef struct msMessage {
    _Atomic(struct msMessage*) next;  /* intrusive linked list */
    int32_t kind;                     /* dispatch index (method vtable ID) */
    uint8_t sizeClass;                /* pool bucket index (Pony's pony_msg_t.index) */
    void* replyFuture;                /* msFuture* for call() semantics, NULL for send() */
    char data[];                      /* flexible array member — exact-fit per method */
} msMessage;

/* ===== Size-Class Pool (Pony-style: exact-fit allocation, thread-local) =====
 *
 * 3 size classes (Pony uses 16; we need 3 for actor messages):
 *   Class 0: 32B — header only or 1 arg  (0-1 args)
 *   Class 1: 64B — small methods          (2-4 args)
 *   Class 2: 128B — large methods         (5-13 args)
 *
 * Header = next(8) + kind(4) + sizeClass(1) + padding(3) + replyFuture(8) = 24B
 * Data capacity per class: 32-24=8B (1 slot), 64-24=40B (5 slots), 128-24=104B (13 slots)
 */

/* Verify header layout assumption — data capacities depend on this */
_Static_assert(offsetof(msMessage, data) == 24, "msMessage header must be 24 bytes");

#define MS_MSG_POOL_CLASSES 3
#define MS_MSG_POOL_SLAB 64

static const int MS_MSG_CLASS_SIZE[MS_MSG_POOL_CLASSES] = { 32, 64, 128 };

/* Compute size class from arg count (each arg = 8 bytes = 1 slot) */
static inline uint8_t msMsgSizeClass(int argCount) {
    int dataBytes = argCount * 8;
    if (dataBytes <= 8)  return 0;  /* 32B: 0-1 args */
    if (dataBytes <= 40) return 1;  /* 64B: 2-5 args */
    return 2;                        /* 128B: 6-13 args */
}

typedef struct msMsgPool {
    msMessage* free_list;
    int count;
} msMsgPool;

#ifndef MS_THREAD_LOCAL
#ifdef _WIN32
#define MS_THREAD_LOCAL __declspec(thread)
#else
#define MS_THREAD_LOCAL _Thread_local
#endif
#endif

/* Per-thread pool, one per size class. Extern (definition in actor.c) so all
 * TUs share the same TLS slot — `static` here would give each TU its own
 * pool, and cross-TU msMsgAlloc/msMsgFree on the same thread would touch
 * different freelists. */
extern MS_THREAD_LOCAL msMsgPool msMsgPools[MS_MSG_POOL_CLASSES];

static inline void msMsgPoolGrow(msMsgPool* pool, int msgSize) {
    /* Allocate slab as raw bytes — messages are msgSize apart */
    char* slab = (char*)calloc(MS_MSG_POOL_SLAB, msgSize);
    for (int i = 0; i < MS_MSG_POOL_SLAB - 1; i++) {
        msMessage* cur = (msMessage*)(slab + i * msgSize);
        msMessage* nxt = (msMessage*)(slab + (i + 1) * msgSize);
        atomic_store_explicit(&cur->next, nxt, memory_order_relaxed);
    }
    msMessage* last = (msMessage*)(slab + (MS_MSG_POOL_SLAB - 1) * msgSize);
    atomic_store_explicit(&last->next, pool->free_list, memory_order_relaxed);
    pool->free_list = (msMessage*)slab;
    pool->count += MS_MSG_POOL_SLAB;
}

static inline msMessage* msMsgAllocSized(int32_t kind, void* replyFut, int argCount) {
    uint8_t cls = msMsgSizeClass(argCount);
    msMsgPool* pool = &msMsgPools[cls];
    if (pool->free_list == NULL) {
        msMsgPoolGrow(pool, MS_MSG_CLASS_SIZE[cls]);
    }
    msMessage* m = pool->free_list;
    pool->free_list = (msMessage*)atomic_load_explicit(&m->next, memory_order_relaxed);
    pool->count--;
    m->kind = kind;
    m->sizeClass = cls;
    m->replyFuture = replyFut;
    atomic_store_explicit(&m->next, NULL, memory_order_relaxed);
    /* Zero data region only (header already set) */
    int dataSize = MS_MSG_CLASS_SIZE[cls] - (int)offsetof(msMessage, data);
    if (dataSize > 0) memset(m->data, 0, dataSize);
    return m;
}

/* Backward-compat wrapper: allocates class 0 (32B) for 0-arg methods */
static inline msMessage* msMsgAlloc(int32_t kind, void* replyFut) {
    return msMsgAllocSized(kind, replyFut, 0);
}

static inline void msMsgFree(msMessage* m) {
    uint8_t cls = m->sizeClass;
    if (cls >= MS_MSG_POOL_CLASSES) cls = 0;
    msMsgPool* pool = &msMsgPools[cls];
    atomic_store_explicit(&m->next, pool->free_list, memory_order_relaxed);
    pool->free_list = m;
    if (pool->count < INT32_MAX) pool->count++;
}

/* ===== Arg packing/unpacking (type-erased via void* slots in data[]) ===== */

static inline void msMsgSetPtr(msMessage* m, int idx, void* val) {
    ((void**)m->data)[idx] = val;
}

static inline void* msMsgGetPtr(msMessage* m, int idx) {
    return ((void**)m->data)[idx];
}

static inline void msMsgSetDouble(msMessage* m, int idx, double val) {
    ((double*)m->data)[idx] = val;
}

static inline double msMsgGetDouble(msMessage* m, int idx) {
    return ((double*)m->data)[idx];
}

/* Typed int/bool slot helpers. Each slot is 8 bytes; int32/bool occupy the
 * lower 4/1 bytes (msAlloc zeros the slot first). Avoiding the double-encoding
 * path preserves int64 precision above 2^53 and lets read side use the same
 * typed view that msFutureReadInt32/Int64/Bool already use. */
static inline void msMsgSetInt32(msMessage* m, int idx, int32_t val) {
    ((int32_t*)m->data)[idx * 2] = val;
}

static inline int32_t msMsgGetInt32(msMessage* m, int idx) {
    return ((int32_t*)m->data)[idx * 2];
}

static inline void msMsgSetInt64(msMessage* m, int idx, int64_t val) {
    ((int64_t*)m->data)[idx] = val;
}

static inline int64_t msMsgGetInt64(msMessage* m, int idx) {
    return ((int64_t*)m->data)[idx];
}

static inline void msMsgSetBool(msMessage* m, int idx, bool val) {
    ((int32_t*)m->data)[idx * 2] = val ? 1 : 0;
}

static inline bool msMsgGetBool(msMessage* m, int idx) {
    return ((int32_t*)m->data)[idx * 2] != 0;
}

/* msString packing: msString = {int64_t len, msStrPayload* p} = 16 bytes = 2 slots.
 *
 * Heap strings: deep-copy on send so the msg owns its payload independently
 * of the caller's local (which DRC frees at scope exit — bitwise alias would
 * dangle). Literals (MS_STRLIT_FLAG) share pointer with static program data.
 *
 * Known gap: msMsgFree without dispatch (dead-letter, mailbox drain on actor
 * destroy) leaks ref-typed slots — same for arrays/ptrs. Needs per-actor-
 * method trace fn (Pony parity, not yet implemented). */
#define msMsgSetString(m, idx, s) do { \
    msString __mscp; \
    if ((s).p == NULL || msIsLiteral(s)) { \
        __mscp = (s); \
    } else { \
        __mscp = msStringNew((s).p->data, (s).len); \
    } \
    ((void**)((msMessage*)(m))->data)[(idx)]     = (void*)(intptr_t)(__mscp).len; \
    ((void**)((msMessage*)(m))->data)[(idx) + 1] = (void*)(__mscp).p; \
} while(0)

#define msMsgGetString(m, idx) \
    ((msString){ .len = (int64_t)(intptr_t)((void**)((msMessage*)(m))->data)[(idx)], \
                 .p = (msStrPayload*)((void**)((msMessage*)(m))->data)[(idx) + 1] })

/* ===== MPSC Queue ===== */

typedef struct msMpscQueue {
    _Atomic(msMessage*) head;   /* producers swap this (tagged: LSB=1 when empty) */
    msMessage* tail;            /* consumer reads from here (no atomics) */
} msMpscQueue;

/* Initialize with stub node from pool. Head tagged with LSB=1 (empty). */
static inline void msMpscInit(msMpscQueue* q) {
    msMessage* stub = msMsgAlloc(0, NULL);
    atomic_store_explicit(&stub->next, NULL, memory_order_relaxed);
    /* Tag head with LSB=1 to indicate empty */
    atomic_store_explicit(&q->head,
        (msMessage*)((uintptr_t)stub | 1), memory_order_relaxed);
    q->tail = stub;
}

/* Destroy queue. Returns stub to pool. Queue must be empty. */
static inline void msMpscDestroy(msMpscQueue* q) {
    if (q->tail != NULL) {
        msMsgFree(q->tail);
        q->tail = NULL;
    }
    atomic_store_explicit(&q->head, NULL, memory_order_relaxed);
}

/*
 * Push message (producer side, any thread).
 * Wait-free: single atomic exchange.
 * Returns true if queue was empty (caller should wake scheduler).
 */
static inline bool msMpscPush(msMpscQueue* q, msMessage* msg) {
	atomic_store_explicit(&msg->next, NULL, memory_order_relaxed);

	/* Release fence: ensure msg fields are visible before linking */
	atomic_thread_fence(memory_order_release);

	/* Swap head atomically. acq_rel pairs producer-producer: prev owner's
	 * writes (msg init, pool slab calloc, etc.) are visible to the next producer
	 * that pops this msg off head via exchange. Relaxed here (Pony's choice)
	 * would require ANNOTATE_HAPPENS_BEFORE for TSan visibility; acq_rel is
	 * free on aarch64 (swpal vs swpl, same cycles) and x86 (xchg is seq_cst
	 * regardless), and gives correct happens-before without annotations. */
	msMessage* prev = atomic_exchange_explicit(&q->head, msg, memory_order_acq_rel);

	/* Check if queue was empty (LSB tag) */
	bool wasEmpty = ((uintptr_t)prev & 1) != 0;
	prev = (msMessage*)((uintptr_t)prev & ~(uintptr_t)1);

	/* Link previous head to new message.
	 * Must be release (not relaxed) so the consumer's acquire load on
	 * tail->next sees this store when processing on a different thread.
	 * Relaxed would cause the consumer to see stale NULL — thinking the
	 * mailbox is empty when messages exist (observed at >1000 messages
	 * when pool workers steal the actor from a different core). */
	atomic_store_explicit(&prev->next, msg, memory_order_release);

	return wasEmpty;
}

/* Push a pre-linked chain of messages [first..last] with one atomic exchange.
 * Amendment H: used by deferred-decref batch flush — amortizes the MPSC push
 * cost (~15 cycles) over N release messages. The intermediate links (first->next
 * ... last-1->next) must already be set by the caller; this function sets
 * last->next = NULL, fence, exchange, then links prev->next = first. */
static inline bool msMpscPushChain(msMpscQueue* q, msMessage* first, msMessage* last) {
	atomic_store_explicit(&last->next, NULL, memory_order_relaxed);
	atomic_thread_fence(memory_order_release);
	msMessage* prev = atomic_exchange_explicit(&q->head, last, memory_order_acq_rel);
	bool wasEmpty = ((uintptr_t)prev & 1) != 0;
	prev = (msMessage*)((uintptr_t)prev & ~(uintptr_t)1);
	atomic_store_explicit(&prev->next, first, memory_order_release);
	return wasEmpty;
}

/*
 * Pop message (consumer side, single thread only).
 * Returns NULL if queue is empty.
 * Frees the previous stub/sentinel node.
 */
static inline msMessage* msMpscPop(msMpscQueue* q) {
    msMessage* tail = q->tail;
    msMessage* next = atomic_load_explicit(&tail->next, memory_order_acquire);

    if (next != NULL) {
        q->tail = next;
        atomic_thread_fence(memory_order_acquire);
        /* Return old stub to pool (tail was the sentinel) */
        msMsgFree(tail);
        return next;
    }

    return NULL;
}

/* Check if queue is empty (non-authoritative — producer may be mid-push). */
static inline bool msMpscIsEmpty(msMpscQueue* q) {
    msMessage* head = atomic_load_explicit(&q->head, memory_order_acquire);
    /* Empty if LSB tagged */
    if (((uintptr_t)head & 1) != 0) return true;
    /* Empty if head == tail (no pending messages) */
    return (msMessage*)((uintptr_t)head & ~(uintptr_t)1) == q->tail;
}

/*
 * Mark queue as empty (consumer side).
 * Sets LSB on head if head == tail (no pending messages).
 * Returns true if successfully marked empty.
 */
static inline bool msMpscMarkEmpty(msMpscQueue* q) {
    msMessage* tail = q->tail;
    msMessage* head = atomic_load_explicit(&q->head, memory_order_acquire);

    /* Already marked empty */
    if (((uintptr_t)head & 1) != 0) return true;

    /* Messages pending (head != tail) */
    if (head != tail) return false;

    /* CAS: tag head with LSB=1 */
    msMessage* tagged = (msMessage*)((uintptr_t)head | 1);
    return atomic_compare_exchange_strong_explicit(
        &q->head, &tail, tagged,
        memory_order_acq_rel, memory_order_acquire);
}

#endif /* MS_MAILBOX_H */
