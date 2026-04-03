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

/* ===== Message ===== */

typedef struct msMessage {
    _Atomic(struct msMessage*) next;  /* intrusive linked list */
    int32_t kind;                     /* dispatch index (method vtable ID) */
    void* replyFuture;                /* msFuture* for call() semantics, NULL for send() */
    char data[56];                    /* inline argument buffer (avoids malloc for small args) */
} msMessage;

/* Allocate a message. Uses malloc for now; Phase 5 can add a pool allocator. */
static inline msMessage* msMsgAlloc(int32_t kind, void* replyFut) {
    msMessage* m = (msMessage*)calloc(1, sizeof(msMessage));
    m->kind = kind;
    m->replyFuture = replyFut;
    atomic_store_explicit(&m->next, NULL, memory_order_relaxed);
    return m;
}

static inline void msMsgFree(msMessage* m) {
    free(m);
}

/* ===== MPSC Queue ===== */

typedef struct msMpscQueue {
    _Atomic(msMessage*) head;   /* producers swap this (tagged: LSB=1 when empty) */
    msMessage* tail;            /* consumer reads from here (no atomics) */
} msMpscQueue;

/* Initialize with stub node. Head tagged with LSB=1 (empty). */
static inline void msMpscInit(msMpscQueue* q) {
    msMessage* stub = (msMessage*)calloc(1, sizeof(msMessage));
    atomic_store_explicit(&stub->next, NULL, memory_order_relaxed);
    /* Tag head with LSB=1 to indicate empty */
    atomic_store_explicit(&q->head,
        (msMessage*)((uintptr_t)stub | 1), memory_order_relaxed);
    q->tail = stub;
}

/* Destroy queue. Frees stub node. Queue must be empty. */
static inline void msMpscDestroy(msMpscQueue* q) {
    if (q->tail != NULL) {
        free(q->tail);
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

    /* Swap head atomically */
    msMessage* prev = atomic_exchange_explicit(&q->head, msg, memory_order_relaxed);

    /* Check if queue was empty (LSB tag) */
    bool wasEmpty = ((uintptr_t)prev & 1) != 0;
    prev = (msMessage*)((uintptr_t)prev & ~(uintptr_t)1);

    /* Link previous head to new message */
    atomic_store_explicit(&prev->next, msg, memory_order_relaxed);

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
        /* Free old stub (tail was the sentinel) */
        free(tail);
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
