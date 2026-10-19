#include "runtime/drc.h"
#include "orcCollections.h"

int32_t msTestOrcCollections(void) {
#if defined(MSGC_ORC) && defined(MSGC_ORC_STATS)
	return msOrcCollections;
#else
	return -1;
#endif
}

int32_t msTestOrcFreed(void) {
#if defined(MSGC_ORC) && defined(MSGC_ORC_STATS)
	return msFreedCyclicObjects;
#else
	return -1;
#endif
}
