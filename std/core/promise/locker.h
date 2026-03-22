/*
 * MetaScript Locker<T> — Thread-safe shared mutable state
 *
 * Malebolgia-aligned: ticket lock (fair spinlock, no destructor needed).
 * Locker wraps a value + lock. Access only via msLockerLock/msLockerUnlock.
 *
 * Usage pattern:
 *   msLocker* loc = msLockerCreate(sizeof(MyData));
 *   msLockerLock(loc);
 *   MyData* data = (MyData*)msLockerData(loc);
 *   data->count += 1;
 *   msLockerUnlock(loc);
 */
#ifndef MS_LOCKER_H
#define MS_LOCKER_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* ===== Ticket Lock (Malebolgia parity) =====
 * Fair spinlock — threads served in FIFO order.
 * No init/deinit needed (zero-initialized is valid). */

#if defined(__GNUC__) || defined(__clang__)
  #define msAtomicFetchAdd(p, v) __atomic_fetch_add(p, v, __ATOMIC_RELAXED)
  #define msAtomicLoad(p) __atomic_load_n(p, __ATOMIC_ACQUIRE)
  #define msAtomicStore(p, v) __atomic_store_n(p, v, __ATOMIC_RELEASE)
  #if defined(__x86_64__) || defined(__i386__)
    #define msCpuRelax() __builtin_ia32_pause()
  #elif defined(__aarch64__)
    #define msCpuRelax() __asm__ volatile("yield")
  #else
    #define msCpuRelax() ((void)0)
  #endif
#elif defined(_MSC_VER)
  #include <intrin.h>
  #define msAtomicFetchAdd(p, v) _InterlockedExchangeAdd((volatile long*)(p), (long)(v))
  #define msAtomicLoad(p) (*(volatile int*)(p))
  #define msAtomicStore(p, v) (*(volatile int*)(p) = (v))
  #define msCpuRelax() _mm_pause()
#else
  /* Fallback: non-atomic (single-threaded only) */
  #define msAtomicFetchAdd(p, v) (*(p) += (v), *(p) - (v))
  #define msAtomicLoad(p) (*(p))
  #define msAtomicStore(p, v) (*(p) = (v))
  #define msCpuRelax() ((void)0)
#endif

typedef struct {
	int nextTicket;
	int nowServing;
} msTicketLock;

static inline void msTicketLockAcquire(msTicketLock* L) {
	int myTicket = msAtomicFetchAdd(&L->nextTicket, 1);
	while (1) {
		int current = msAtomicLoad(&L->nowServing);
		if (current == myTicket) break;
		/* Proportional backoff (Malebolgia pattern) */
		int delay = 30 * (myTicket - current);
		while (delay > 0) { msCpuRelax(); delay--; }
	}
}

static inline void msTicketLockRelease(msTicketLock* L) {
	int current = msAtomicLoad(&L->nowServing);
	msAtomicStore(&L->nowServing, current + 1);
}

/* ===== Locker<T> — value + lock ===== */

typedef struct {
	msTicketLock lock;
	/* Value data follows inline (flexible member) */
	char data[];
} msLocker;

/* Create a Locker with space for `dataSize` bytes of value data.
 * Value is zero-initialized. */
static inline msLocker* msLockerCreate(int dataSize) {
	msLocker* loc = (msLocker*)calloc(1, sizeof(msLocker) + dataSize);
	return loc;
}

/* Create a Locker initialized with a copy of `src` data. */
static inline msLocker* msLockerCreateFrom(const void* src, int dataSize) {
	msLocker* loc = (msLocker*)calloc(1, sizeof(msLocker) + dataSize);
	memcpy(loc->data, src, dataSize);
	return loc;
}

/* Get pointer to the value data (caller must lock first). */
static inline void* msLockerData(msLocker* loc) {
	return (void*)loc->data;
}

/* Acquire the lock. Takes void* for MetaScript interface compatibility. */
static inline void msLockerLock(void* p) {
	msTicketLockAcquire(&((msLocker*)p)->lock);
}

/* Release the lock. */
static inline void msLockerUnlock(void* p) {
	msTicketLockRelease(&((msLocker*)p)->lock);
}

/* Read a double from the locker's data (caller must hold lock). */
static inline double msLockerGetDouble(void* p) {
	return *(double*)((msLocker*)p)->data;
}

/* Write a double to the locker's data (caller must hold lock). */
static inline void msLockerSetDouble(void* p, double v) {
	*(double*)((msLocker*)p)->data = v;
}

/* Read an int32 from the locker's data (caller must hold lock). */
static inline int32_t msLockerGetInt32(void* p) {
	return *(int32_t*)((msLocker*)p)->data;
}

/* Write an int32 to the locker's data (caller must hold lock). */
static inline void msLockerSetInt32(void* p, int32_t v) {
	*(int32_t*)((msLocker*)p)->data = v;
}

/* Destroy the locker. */
static inline void msLockerDestroy(void* p) {
	free(p);
}

#endif /* MS_LOCKER_H */
