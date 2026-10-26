#include <stdlib.h>
#include "runtime/drc.h"
#include "orcMaybeCycleFlag.h"

static void* flaggedCell(intptr_t count) {
	msRefHeader* h = (msRefHeader*)calloc(1, sizeof(msRefHeader) + 16);
	h->rootIdx = -1;
	h->rc = count * MS_RC_INCREMENT;
	void* p = h + 1;
	msMarkMaybeCycle(p);
	return p;
}

int32_t msTestMaybeCycleSoleOwner(void) {
	void* p = flaggedCell(0);
	bool last = msOrcDecRefIsLast(p);
	intptr_t rc = msHeader(p)->rc;
	free(msHeader(p));
	if (!last) return 1;
	if (rc != MS_MAYBE_CYCLE) return 2;
	return 0;
}

int32_t msTestMaybeCycleShared(void) {
	void* p = flaggedCell(1);
	bool last = msOrcDecRefIsLast(p);
	intptr_t rc = msHeader(p)->rc;
	free(msHeader(p));
	if (last) return 1;
	if (rc != MS_MAYBE_CYCLE) return 2;
	return 0;
}
