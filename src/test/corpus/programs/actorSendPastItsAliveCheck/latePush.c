#include <pthread.h>
#include <sched.h>
#include <time.h>
#include "runtime/core/system.h"
#include "runtime/actor/actor.h"
#include "latePush.h"

static _Atomic(int32_t) made;
static _Atomic(int64_t) targetPid;
static _Atomic(int32_t) step;

void probeMade(void) { atomic_store_explicit(&made, 1, memory_order_release); }

int32_t probeWaitMade(void) {
	time_t deadline = time(NULL) + 10;
	while (!atomic_load_explicit(&made, memory_order_acquire) && time(NULL) < deadline) sched_yield();
	return atomic_load_explicit(&made, memory_order_acquire);
}

/* A sender that saw the actor alive under its pin, then lost the CPU until the owner destroyed it. */
static void* lateSender(void* unused) {
	(void)unused;
	msActor* a = msActorFromPid(atomic_load_explicit(&targetPid, memory_order_acquire));
	bool sawAlive = a != NULL && atomic_load_explicit(&a->alive, memory_order_acquire);
	atomic_store_explicit(&step, sawAlive ? 1 : -1, memory_order_release);
	if (!sawAlive) {
		msHazardClear(a);
		return NULL;
	}
	while (atomic_load_explicit(&step, memory_order_acquire) != 2) sched_yield();
	msActorPush(a, msMsgAllocSized(0, NULL, 1));
	return NULL;
}

static int32_t pidLive(int64_t pid) {
	msActor* a = msActorFromPid(pid);
	if (a == NULL) return 0;
	msHazardClear(a);
	return 1;
}

int32_t probeSendAfterStop(int64_t pid) {
	atomic_store_explicit(&targetPid, pid, memory_order_release);
	pthread_t sender;
	if (pthread_create(&sender, NULL, lateSender, NULL) != 0) return 0;
	while (atomic_load_explicit(&step, memory_order_acquire) == 0) sched_yield();
	int32_t ok = atomic_load_explicit(&step, memory_order_acquire) == 1;
	if (ok) {
		msActorStop(pid, MS_EXIT_SHUTDOWN);
		time_t deadline = time(NULL) + 10;
		while (pidLive(pid) && time(NULL) < deadline) sched_yield();
		ok = !pidLive(pid);
		struct timespec teardownTime = { 0, 100 * 1000 * 1000 };
		nanosleep(&teardownTime, NULL);
	}
	atomic_store_explicit(&step, 2, memory_order_release);
	pthread_join(sender, NULL);
	return ok;
}
