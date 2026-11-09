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
#include "runtime/drc.h"
#include "runtime/core/stringRep.h"
#include <string.h>

/* ===== Message ===== */

typedef struct msMessage {
    _Atomic(struct msMessage*) next;  /* intrusive linked list */
    int32_t kind;                     /* dispatch index (method vtable ID) */
    void* replyFuture;                /* msFuture* for call() semantics, NULL for send() */
    char data[];                      /* argCount 8-byte slots */
} msMessage;

/* An envelope is allocated on the sender's thread and freed by the receiver's
 * pop, usually on another thread; the region heap returns a block freed on a
 * foreign thread to its owner, so envelopes cost no memory per message sent.
 * One slot at least: completion messages are sent with no argument and still
 * carry an error pointer in slot 0. */
static inline msMessage* msMsgAllocSized(int32_t kind, void* replyFut, int argCount) {
    size_t slots = argCount > 1 ? (size_t)argCount : 1;
    msMessage* m = (msMessage*)msMemAlloc0(offsetof(msMessage, data) + slots * sizeof(uint64_t));
    m->kind = kind;
    m->replyFuture = replyFut;
    return m;
}

static inline msMessage* msMsgAlloc(int32_t kind, void* replyFut) {
    return msMsgAllocSized(kind, replyFut, 0);
}

static inline void msMsgFree(msMessage* m) {
    msMemFree(m);
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

/* An msString takes two 8-byte slots.
 *
 * Heap strings: deep-copy on send so the msg owns its payload independently
 * of the caller's local (which DRC frees at scope exit — bitwise alias would
 * dangle). Literals share pointer with static program data. */
_Static_assert(sizeof(msString) == 2 * sizeof(uint64_t), "an msString fills two message slots");

#define msMsgSetString(m, idx, s) do { \
    msString __mscp = msStringDup(s); \
    memcpy(&((uint64_t*)((msMessage*)(m))->data)[(idx)], &__mscp, sizeof(msString)); \
} while(0)

static inline msString msMsgGetString(msMessage* m, int idx) {
    msString s;
    memcpy(&s, &((uint64_t*)m->data)[idx], sizeof(msString));
    return s;
}

/* ===== MPSC Queue ===== */

typedef struct msMpscQueue {
    _Atomic(msMessage*) head;   /* producers swap this (tagged: LSB=1 when empty) */
    msMessage* tail;            /* consumer reads from here (no atomics) */
} msMpscQueue;

/* Initialize with a stub node. Head tagged with LSB=1 (empty). */
static inline void msMpscInit(msMpscQueue* q) {
    msMessage* stub = msMsgAlloc(0, NULL);
    atomic_store_explicit(&stub->next, NULL, memory_order_relaxed);
    /* Tag head with LSB=1 to indicate empty */
    atomic_store_explicit(&q->head,
        (msMessage*)((uintptr_t)stub | 1), memory_order_relaxed);
    q->tail = stub;
}

/* Destroy queue. Frees the stub. Queue must be empty. */
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

	/* seq_cst, not acq_rel: the actor's visit end drops its run token and then
	 * marks this queue empty, and the pusher takes the token after this exchange;
	 * both sides must be in one total order (same instruction on aarch64 and x86). */
	msMessage* prev = atomic_exchange_explicit(&q->head, msg, memory_order_seq_cst);

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
        /* Free the old stub (tail was the sentinel) */
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
    msMessage* head = atomic_load_explicit(&q->head, memory_order_seq_cst);

    /* Already marked empty */
    if (((uintptr_t)head & 1) != 0) return true;

    /* Messages pending (head != tail) */
    if (head != tail) return false;

    /* CAS: tag head with LSB=1 */
    msMessage* tagged = (msMessage*)((uintptr_t)head | 1);
    return atomic_compare_exchange_strong_explicit(
        &q->head, &tail, tagged,
        memory_order_seq_cst, memory_order_seq_cst);
}

#endif /* MS_MAILBOX_H */
