#include <unistd.h>
#include <stdint.h>
#include <stdatomic.h>
static _Atomic int32_t pinRunning = 0;
static _Atomic int32_t pinRelease = 0;
static _Atomic int32_t pinWaiters = 0;
static _Atomic int32_t pinSelf = 0;
static _Thread_local int32_t pinInWait = 0;
static inline int32_t pinHold(void) {
	if (pinInWait) atomic_fetch_add(&pinSelf, 1);
	atomic_fetch_add(&pinRunning, 1);
	while (!atomic_load(&pinRelease)) usleep(1000);
	return 1;
}
static inline void pinWaitAll(int32_t n) { while (atomic_load(&pinRunning) < n) usleep(1000); }
static inline void pinReleaseAll(void) { atomic_store(&pinRelease, 1); }
static inline void pinReset(void) { atomic_store(&pinRunning, 0); atomic_store(&pinRelease, 0); atomic_store(&pinWaiters, 0); atomic_store(&pinSelf, 0); }
static inline int32_t pinRunningCount(void) { return atomic_load(&pinRunning); }
static inline void pinEnterWait(void) { pinInWait = 1; atomic_fetch_add(&pinWaiters, 1); }
static inline void pinLeaveWait(void) { pinInWait = 0; }
/* Threads taken: each waiter's own, plus each holder not run on its waiter's stack. */
static inline int32_t pinOccupied(void) { return atomic_load(&pinWaiters) + atomic_load(&pinRunning) - atomic_load(&pinSelf); }
