#include "runtime/core/system.h"
#include "runtime/promise/pool.h"
#include "poolEdgeRuns.h"

int32_t msTestPoolEdgeRuns(void) {
#ifdef MSPOOL_STATS
	return msPoolEdgeRuns();
#else
	return -1;
#endif
}
