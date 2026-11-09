#include <pthread.h>
#include <sched.h>
#include <time.h>
#include "runtime/core/system.h"
#include "runtime/actor/actor.h"
#include "pinnedStop.h"

static _Atomic(int32_t) made;
static _Atomic(int64_t) pinnedPid;
static _Atomic(int32_t) step;

void probeMade(void) { atomic_store_explicit(&made, 1, memory_order_release); }

int32_t probeWaitMade(void) {
	time_t deadline = time(NULL) + 10;
	while (!atomic_load_explicit(&made, memory_order_acquire) && time(NULL) < deadline) sched_yield();
	return atomic_load_explicit(&made, memory_order_acquire);
}

static void* holdPin(void* unused) {
	(void)unused;
	msActor* a = msActorFromPid(atomic_load_explicit(&pinnedPid, memory_order_acquire));
	atomic_store_explicit(&step, a != NULL ? 1 : -1, memory_order_release);
	while (atomic_load_explicit(&step, memory_order_acquire) != 2) sched_yield();
	msHazardClear(a);
	return NULL;
}

static int32_t pidLive(int64_t pid) {
	msActor* a = msActorFromPid(pid);
	if (a == NULL) return 0;
	msHazardClear(a);
	return 1;
}

/* Another thread holds a pid pin on the actor while it is stopped, and keeps it until the owner
 * has finished that visit and parked, so the owner must come back for the state once it clears. */
int32_t probeStopWhilePinned(int64_t pid) {
	atomic_store_explicit(&pinnedPid, pid, memory_order_release);
	pthread_t holder;
	if (pthread_create(&holder, NULL, holdPin, NULL) != 0) return 0;
	while (atomic_load_explicit(&step, memory_order_acquire) == 0) sched_yield();
	int32_t ok = atomic_load_explicit(&step, memory_order_acquire) == 1;
	if (ok) {
		msActorStop(pid, MS_EXIT_SHUTDOWN);
		time_t deadline = time(NULL) + 10;
		while (pidLive(pid) && time(NULL) < deadline) sched_yield();
		ok = !pidLive(pid);
		struct timespec parkTime = { 0, 100 * 1000 * 1000 };
		nanosleep(&parkTime, NULL);
	}
	atomic_store_explicit(&step, 2, memory_order_release);
	pthread_join(holder, NULL);
	return ok;
}
