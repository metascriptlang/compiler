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
 * it lives here rather than in a header of its own; the --gc=manual stubs in
 * runtime/manual.h are single-threaded no-ops and do not need the layout.
 */
#ifndef MS_LOCKED_H
#define MS_LOCKED_H

#include <stdint.h>

/* ===== Atomic primitives ===== */

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
  /* WaitOnAddress/WakeByAddressAll (Amendment E Tier 1's Windows arm) live in
   * api-ms-win-core-synch-l1-2-0 (Win8+; forwarded from kernel32 on newer
   * builds) — but the mingw import libs zig cc links do not carry them, so a
   * static __declspec(dllimport) reference is an undefined symbol at link
   * time (probed: linker error on every -l candidate). Resolve dynamically:
   * one GetProcAddress pair at first use, spin fallback when absent. The
   * fallback is the pre-Tier-1 pure-spin behaviour — degraded (contended
   * waiters burn their spin budget instead of parking) but sound, same shape
   * as the #else branch below. */
  #include <windows.h>
  typedef BOOL  (WINAPI *msWaitOnAddressFn)(volatile void*, void*, size_t, DWORD);
  typedef void  (WINAPI *msWakeByAddressFn)(void*);
  static msWaitOnAddressFn msWaitOnAddressP = NULL;
  static msWakeByAddressFn msWakeByAddressAllP = NULL;
  static LONG msFutexFnState = 0;  /* 0 = unresolved, 1 = resolving, 2 = done */
  static inline void msFutexResolve(void) {
    if (msFutexFnState == 2) return;
    if (InterlockedCompareExchange(&msFutexFnState, 1, 0) == 0) {
      HMODULE k32 = GetModuleHandleA("kernel32.dll");
      HMODULE syn = GetModuleHandleA("api-ms-win-core-synch-l1-2-0.dll");
      if (k32 != NULL) {
        msWaitOnAddressP   = (msWaitOnAddressFn)(void*)GetProcAddress(k32, "WaitOnAddress");
        msWakeByAddressAllP = (msWakeByAddressFn)(void*)GetProcAddress(k32, "WakeByAddressAll");
      }
      if (msWaitOnAddressP == NULL && syn != NULL) {
        msWaitOnAddressP   = (msWaitOnAddressFn)(void*)GetProcAddress(syn, "WaitOnAddress");
        msWakeByAddressAllP = (msWakeByAddressFn)(void*)GetProcAddress(syn, "WakeByAddressAll");
      }
      InterlockedExchange(&msFutexFnState, 2);
    } else {
      while (msFutexFnState == 1) msCpuRelax();
    }
  }
  static inline void msFutexWait(int* addr, int expected) {
    msFutexResolve();
    if (msWaitOnAddressP != NULL) {
      int cmp = expected;
      msWaitOnAddressP((volatile void*)addr, &cmp, sizeof(int), INFINITE);
    } else {
      /* No WaitOnAddress on this OS: keep polling like the pre-Tier-1 spin
       * path. The acquire load pairs with the release store in
       * msTicketLockRelease, so we never sleep past our turn. */
      while (msAtomicLoad(addr) == expected) msCpuRelax();
    }
  }
  static inline void msFutexWakeAll(int* addr) {
    if (msWakeByAddressAllP != NULL) msWakeByAddressAllP((void*)addr);
  }
#else
  static inline void msFutexWait(int* addr, int expected) { (void)addr; (void)expected; msCpuRelax(); }
  static inline void msFutexWakeAll(int* addr) { (void)addr; }
#endif

/* ===== Ticket lock =====
 * Fair spinlock — threads served in FIFO order, then parked on nowServing.
 * No init/deinit needed: zero-initialized is a valid unlocked lock, which is
 * what the cell's zero-filled allocation gives us for free. The two ints ARE
 * the first two fields the compiler lays out in the cell struct. */

typedef struct {
	int nextTicket;
	int nowServing;
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

/* ===== Locked<T> cell surface ===== */

static inline void msLockedAcquire(void* cell) {
	msTicketLockAcquire((msTicketLock*)cell);
}

static inline void msLockedRelease(void* cell) {
	msTicketLockRelease((msTicketLock*)cell);
}

#endif /* MS_LOCKED_H */
