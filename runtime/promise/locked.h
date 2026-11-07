/*
 * MetaScript Locked<T> — the one sanctioned shared-mutable cell.
 *
 * ONE allocation: atomic-rc header (msAllocArc) + inline ticket lock + typed
 * payload, laid out by the compiler as
 *
 *     struct LockedCell_T { msTicketLock lock; T value; };
 *
 * The lock sits at offset 0, so acquire/release need no knowledge of T — they
 * cast the handle straight to msTicketLock*. The payload is reached only
 * through the compiler's load/store intercepts, which know the real field
 * offset from the generated struct (never a hand-computed one).
 *
 * The handle's liveness is its own atomic refcount, which is why a second
 * refcount wrapper around it is not a type: two cells / two refcounts is the
 * mixed-rc shape this replaces.
 *
 * The ticket lock below is the whole locking runtime — one fair FIFO spinlock
 * with an adaptive spin→park tail. It has exactly one consumer (this cell), so
 * it lives here rather than in a header of its own; the --mm=manual stubs in
 * runtime/manual.h are single-threaded no-ops and do not need the layout.
 */
#ifndef MS_LOCKED_H
#define MS_LOCKED_H

#include <stdint.h>
#include <stdbool.h>

/* ===== Atomic primitives ===== */

#if defined(__GNUC__) || defined(__clang__)
  #define msAtomicFetchAdd(p, v) __atomic_fetch_add(p, v, __ATOMIC_SEQ_CST)
  #define msAtomicLoad(p) __atomic_load_n(p, __ATOMIC_SEQ_CST)
  #define msAtomicStore(p, v) __atomic_store_n(p, v, __ATOMIC_SEQ_CST)
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
#if defined(__APPLE__) && !defined(MSOS_BARE)
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
  static inline void msFutexWaitUs(int* addr, int expected, uint32_t us) {
    __ulock_wait(MS_ULOCK_CMP_WAIT, (void*)addr, (uint32_t)expected, us);
  }
#elif defined(__linux__) && !defined(MSOS_BARE)
  #include <limits.h>
  #include <unistd.h>
  #include <sys/syscall.h>
  #include <linux/futex.h>
  #include <time.h>
  static inline void msFutexWait(int* addr, int expected) {
    syscall(SYS_futex, addr, FUTEX_WAIT_PRIVATE, expected, (void*)0, (void*)0, 0);
  }
  static inline void msFutexWakeAll(int* addr) {
    syscall(SYS_futex, addr, FUTEX_WAKE_PRIVATE, INT_MAX, (void*)0, (void*)0, 0);
  }
  static inline void msFutexWaitUs(int* addr, int expected, uint32_t us) {
    struct timespec ts = { (time_t)(us / 1000000u), (long)(us % 1000000u) * 1000L };
    syscall(SYS_futex, addr, FUTEX_WAIT_PRIVATE, expected, &ts, (void*)0, 0);
  }
#elif defined(_WIN32) && !defined(MSOS_BARE)
  /* Defined once in runtime/core/system.c, so this header needs no <windows.h>
   * and every file shares one WaitOnAddress/WakeByAddressAll resolution. */
  void msFutexWait(int* addr, int expected);
  void msFutexWakeAll(int* addr);
  void msFutexWaitUs(int* addr, int expected, uint32_t us);
#else
  static inline void msFutexWait(int* addr, int expected) { (void)addr; (void)expected; msCpuRelax(); }
  static inline void msFutexWakeAll(int* addr) { (void)addr; }
  static inline void msFutexWaitUs(int* addr, int expected, uint32_t us) { (void)addr; (void)expected; (void)us; msCpuRelax(); }
#endif

/* ===== Ticket lock =====
 * Fair spinlock — threads served in FIFO order, then parked on nowServing.
 * No init/deinit needed: zero-initialized is a valid unlocked lock, which is
 * what the cell's zero-filled allocation gives us for free. The two ints ARE
 * the first two fields the compiler lays out in the cell struct. */

typedef struct {
	int nextTicket;
	int nowServing;
	int64_t holder;
} msTicketLock;

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

/* ===== Locked<T> cell surface =====
 * `holder` names the thread inside the critical section, so a callback that
 * enters its own cell again is refused instead of waiting on itself. Only the
 * holder writes it, between acquire and release, so a relaxed store and load
 * suffice: another thread can only ever read 0 or a foreign id. */

#if defined(MSOS_BARE)
  static inline int64_t msLockedSelf(void) { return 1; }
#elif defined(_WIN32)
  int64_t msLockedSelf(void);
#else
  #include <pthread.h>
  static inline int64_t msLockedSelf(void) { return (int64_t)(uintptr_t)pthread_self(); }
#endif

static inline bool msLockedHeldHere(void* cell) {
	return __atomic_load_n(&((msTicketLock*)cell)->holder, __ATOMIC_RELAXED) == msLockedSelf();
}

static inline void msLockedAcquire(void* cell) {
	msTicketLock* L = (msTicketLock*)cell;
	msTicketLockAcquire(L);
	__atomic_store_n(&L->holder, msLockedSelf(), __ATOMIC_RELAXED);
}

static inline void msLockedRelease(void* cell) {
	msTicketLock* L = (msTicketLock*)cell;
	__atomic_store_n(&L->holder, 0, __ATOMIC_RELAXED);
	msTicketLockRelease(L);
}

#endif /* MS_LOCKED_H */
