#include <sched.h>
#include <stdatomic.h>
#include <time.h>
#include "offSender.h"

static _Thread_local int32_t senderHere;
static _Atomic(int64_t) taken, onSender;
static _Atomic(int32_t) made;

void probeMarkSender(void) { senderHere = 1; }

void probeTake(void) {
	if (senderHere) atomic_fetch_add_explicit(&onSender, 1, memory_order_relaxed);
	atomic_fetch_add_explicit(&taken, 1, memory_order_release);
}

void probeMade(void) { atomic_store_explicit(&made, 1, memory_order_release); }

int32_t probeWaitMade(void) {
	time_t deadline = time(NULL) + 10;
	while (!atomic_load_explicit(&made, memory_order_acquire) && time(NULL) < deadline) sched_yield();
	return atomic_load_explicit(&made, memory_order_acquire);
}

int32_t probeWaitTaken(int64_t n) {
	time_t deadline = time(NULL) + 10;
	while (atomic_load_explicit(&taken, memory_order_acquire) < n && time(NULL) < deadline) sched_yield();
	return atomic_load_explicit(&taken, memory_order_acquire) >= n;
}

int64_t probeOnSender(void) { return atomic_load_explicit(&onSender, memory_order_relaxed); }
