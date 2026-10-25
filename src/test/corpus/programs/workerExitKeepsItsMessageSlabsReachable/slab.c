#include <sched.h>
#include <time.h>
#include "runtime/core/system.h"
#include "runtime/actor/mailbox.h"
#include "slab.h"

static _Thread_local bool grownHere[MS_MSG_POOL_CLASSES];
static _Atomic(int32_t) grownOnWorkers[MS_MSG_POOL_CLASSES];

static void waitForAWorker(uint8_t cls) {
	time_t deadline = time(NULL) + 2;
	while (atomic_load_explicit(&grownOnWorkers[cls], memory_order_acquire) == 0 && time(NULL) < deadline) sched_yield();
}

int32_t msTestGrowMessageSlabOnWorker(int32_t argCount) {
	uint8_t cls = msMsgSizeClass(argCount);
	if (!msIsPoolWorker) {
		waitForAWorker(cls);
		return 0;
	}
	if (grownHere[cls]) return 0;
	grownHere[cls] = true;
	msMsgPool* pool = &msMsgPools[cls];
	msMessage* earlier = pool->free_list;
	pool->free_list = NULL;
	msMessage* taken[MS_MSG_POOL_SLAB];
	for (int i = 0; i < MS_MSG_POOL_SLAB; i++) taken[i] = msMsgAllocSized(0, NULL, argCount);
	for (int i = 0; i < MS_MSG_POOL_SLAB; i++) msMsgFree(taken[i]);
	atomic_store_explicit(&taken[0]->next, earlier, memory_order_relaxed);
	atomic_fetch_add_explicit(&grownOnWorkers[cls], 1, memory_order_release);
	return 1;
}
