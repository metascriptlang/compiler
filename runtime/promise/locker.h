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
#include "runtime/drc.h"

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

/* ===== Address-keyed park (Tier 1: adaptive spin→park) ===== */
#if defined(__APPLE__)
  #define MS_ULOCK_CMP_WAIT 1u
  #define MS_ULOCK_WAKE_ALL 0x00000100u
  extern int __ulock_wait(uint32_t op, void* addr, uint64_t val, uint32_t timeout_us);
  extern int __ulock_wake(uint32_t op, void* addr, uint64_t wake);
  static inline void msFutexWait(int* addr, int expected) {
    __ulock_wait(MS_ULOCK_CMP_WAIT, (void*)addr, (uint32_t)expected, 0);
  }
  static inline void msFutexWakeAll(int* addr) {
    __ulock_wake(MS_ULOCK_CMP_WAIT | MS_ULOCK_WAKE_ALL, (void*)addr, 0);
  }
#elif defined(__linux__)
  #include <limits.h>
  #include <unistd.h>
  #include <sys/syscall.h>
  #include <linux/futex.h>
  static inline void msFutexWait(int* addr, int expected) {
    syscall(SYS_futex, addr, FUTEX_WAIT_PRIVATE, expected, (void*)0, (void*)0, 0);
  }
  static inline void msFutexWakeAll(int* addr) {
    syscall(SYS_futex, addr, FUTEX_WAKE_PRIVATE, INT_MAX, (void*)0, (void*)0, 0);
  }
#elif defined(_WIN32)
  #define MS_INFINITE 0xFFFFFFFFul
  __declspec(dllimport) int  __stdcall WaitOnAddress(volatile void* addr, void* cmp, size_t size, unsigned long ms);
  __declspec(dllimport) void __stdcall WakeByAddressAll(void* addr);
  static inline void msFutexWait(int* addr, int expected) {
    int cmp = expected;
    WaitOnAddress((volatile void*)addr, &cmp, sizeof(int), MS_INFINITE);
  }
  static inline void msFutexWakeAll(int* addr) {
    WakeByAddressAll((void*)addr);
  }
#else
  static inline void msFutexWait(int* addr, int expected) { (void)addr; (void)expected; msCpuRelax(); }
  static inline void msFutexWakeAll(int* addr) { (void)addr; }
#endif

#include "runtime/promise/lockerLayout.h"

#ifndef MS_LOCK_SPIN_BUDGET
#define MS_LOCK_SPIN_BUDGET 40
#endif

static inline void msTicketLockAcquire(msTicketLock* L) {
	int myTicket = msAtomicFetchAdd(&L->nextTicket, 1);
	int spins = 0;
	while (1) {
		int current = msAtomicLoad(&L->nowServing);
		if (current == myTicket) return;
		if (spins < MS_LOCK_SPIN_BUDGET) {
			int delay = 30;
			while (delay > 0) { msCpuRelax(); delay--; }
			spins++;
		} else {
			msFutexWait(&L->nowServing, current);
		}
	}
}

static inline void msTicketLockRelease(msTicketLock* L) {
	int current = msAtomicLoad(&L->nowServing);
	msAtomicStore(&L->nowServing, current + 1);
	if (msAtomicLoad(&L->nextTicket) != msAtomicLoad(&L->nowServing))
		msFutexWakeAll(&L->nowServing);
}

/* ===== Locker<T> — value + lock (msLocker layout in lockerLayout.h) ===== */

/* Create a Locker with space for `dataSize` bytes of value data.
 * Allocated via msAlloc so DRC refcount header is present —
 * MetaScript interface variables call msDecref on scope exit.
 * Zero-initialized (ticket lock valid at zero, same as Malebolgia initTicketLock). */
static inline void* msLockerCreate(int dataSize) {
	return msAlloc(sizeof(msLocker) + dataSize);
}

/* Create a Locker initialized with a copy of `src` data. */
static inline void* msLockerCreateFrom(const void* src, int dataSize) {
	msLocker* loc = (msLocker*)msAlloc(sizeof(msLocker) + dataSize);
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

/* Destroy the locker — free via ARC header (allocated with msAlloc). */
static inline void msLockerDestroy(void* p) {
	msDestroyAndDispose(p);
}

#endif /* MS_LOCKER_H */
